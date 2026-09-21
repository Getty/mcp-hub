package MCP::Hub;
our $VERSION = '0.001';
use Mojo::Base 'Mojolicious', -signatures;

use MCP::Hub::Aggregate;
use MCP::Hub::Auth;
use MCP::Hub::Config;
use MCP::Hub::Facade::Server;
use MCP::Hub::Help;
use MCP::Hub::Upstream;
use MCP::Hub::Upstream::Perl;
use MCP::Hub::Upstream::Stdio;
use MCP::Hub::Upstream::Http;
use Mojo::Promise;
use Scalar::Util qw(blessed);

# ABSTRACT: One HTTP MCP server that embeds many, for a lot of MCP on little RAM

has 'hub_config_input';
has 'hub_config';
has 'auth';
has 'aggregate';
has upstreams         => sub { [] };
has upstreams_by_name => sub { {} };

sub startup ($self) {
  # Prepend, not append: our daemon command must win over the built-in
  # Mojolicious::Command::daemon (which ignores the config listen address).
  unshift @{$self->commands->namespaces}, 'MCP::Hub::Command';

  my $config = $self->_resolve_config;
  $self->hub_config($config);
  $self->log->warn("no configuration file at $config->{_missing}") if $config->{_missing};

  $self->_build_upstreams;
  $self->auth(MCP::Hub::Auth->new(config => $config));
  $self->_build_aggregate;
  $self->_setup_routes;

  # Note: no upstream is started here. Background manifest fetches and
  # always_on servers are kicked off by the daemon command (see
  # start_background_fetches), so that config/status/token/refresh never spawn
  # a child just by loading the application.
  return $self;
}

# --- introspection / actions (used by routes and the Status native) --------

sub status_report ($self) {
  my $seen = $self->auth ? $self->auth->last_seen : {};
  return {
    mode      => $self->hub_config->mode,
    upstreams => [map { $_->status_row } @{$self->upstreams}],
    clients   => [
      map { {name => $_->{name}, profile => $_->{profile}, last_seen => $seen->{$_->{name}}} }
        sort { $a->{name} cmp $b->{name} } values %{$self->hub_config->clients}
    ],
  };
}

sub refresh_p ($self, $name = undef) {
  my @targets = defined $name ? grep { $_->name eq $name } @{$self->upstreams} : @{$self->upstreams};
  return Mojo::Promise->reject("unknown server '$name'") if defined $name && !@targets;

  my @promises = map {
    my $up = $_;
    $up->refresh_p->then(sub { +{name => $up->name, count => scalar @{$up->server->tools}} })
      ->catch(sub { +{name => $up->name, count => scalar @{$up->server->tools}} });
  } @targets;

  return Mojo::Promise->all(@promises)->then(sub (@results) {
    $self->rebuild_aggregate;
    return {map { $_->[0]{name} => $_->[0]{count} } @results};
  });
}

sub rebuild_aggregate ($self) {
  $self->aggregate->rebuild($self->upstreams) if $self->aggregate;
  return $self;
}

sub export_config ($self, %opts) {
  my $config = $self->hub_config;
  my $base   = $opts{url} // _base_url($config->listen);

  my ($profile, $headers);
  if ($config->mode eq 'clients') {
    my $name   = $opts{client} // die "a client name is required in clients mode (use --client NAME)\n";
    my $client = $config->clients->{$name} // die "unknown client '$name'\n";
    $profile = $config->profiles->{$client->{profile}};
    $headers = {Authorization => "Bearer $client->{token}"};
  }
  else {
    warn "--client is ignored in open mode\n" if $opts{client};
    $profile = $self->auth->open_profile;
  }

  if ($opts{all}) {
    my $entry = {type => 'http', url => "$base/all"};
    $entry->{headers} = $headers if $headers;
    return {mcpServers => {hub => $entry}};
  }

  my %servers;
  for my $up (@{$self->upstreams}) {
    next unless $self->auth->allows_server($profile, $up->name);
    my $entry = {type => 'http', url => "$base/@{[$up->name]}"};
    $entry->{headers} = $headers if $headers;
    $servers{$up->name} = $entry;
  }
  return {mcpServers => \%servers};
}

# --- build phases ----------------------------------------------------------

sub _resolve_config ($self) {
  my $input = $self->hub_config_input;
  return $input if blessed($input) && $input->isa('MCP::Hub::Config');
  return MCP::Hub::Config->from_data($input) if ref $input eq 'HASH';

  my $path = $input // $ENV{MCP_HUB_CONFIG} // _default_config_path();
  unless (-f $path) {
    my $empty = MCP::Hub::Config->from_data({mcpServers => {}});
    $empty->{_missing} = $path;
    return $empty;
  }
  return MCP::Hub::Config->from_file($path);
}

sub _build_upstreams ($self) {
  my $config = $self->hub_config;
  my (@ups, %by);

  for my $entry (@{$config->servers}) {
    my %opts = (hub => $self, log => $self->log);
    if ($entry->{type} ne 'perl') {
      $opts{cache_dir}       = $config->cache_dir;
      $opts{request_timeout} = $config->request_timeout;
      $opts{idle_timeout}    = $config->idle_timeout if $entry->{type} eq 'stdio';
    }

    my $up = eval { MCP::Hub::Upstream->build($entry, %opts) };
    if (my $err = $@) {
      chomp $err;
      $self->log->error("failed to build upstream $entry->{name}: $err");
      $up = $self->_broken_upstream($entry, $err);
    }

    push @ups, $up;
    $by{$up->name} = $up;
    $self->_attach_tool_filter($up);
  }

  $self->upstreams(\@ups);
  $self->upstreams_by_name(\%by);
  return $self;
}

sub _broken_upstream ($self, $entry, $error) {
  # A misconfigured entry keeps its place as a failed upstream: it shows up in
  # the status report and answers 503 with the reason, instead of vanishing into
  # an indistinguishable 404. The daemon still starts.
  my $up = MCP::Hub::Upstream->new(
    name   => $entry->{name},
    config => $entry,
    hub    => $self,
    log    => $self->log,
    error  => $error,
    state  => 'failed',
  );
  $up->server(MCP::Hub::Facade::Server->new(name => $entry->{name}, version => '0.0.0'));
  return $up;
}

sub _attach_tool_filter ($self, $up) {
  my $name = $up->name;
  $up->server->on(tools => sub ($srv, $tools, $ctx) {
    my $c       = $ctx->controller  or return;
    my $profile = $c->stash('mcp.profile') or return;
    $self->auth->filter_tools($profile, $name, $tools);
  });
  return $self;
}

sub _build_aggregate ($self) {
  my $agg = MCP::Hub::Aggregate->new;
  $agg->rebuild($self->upstreams);
  $agg->on(tools => sub ($srv, $tools, $ctx) {
    my $c       = $ctx->controller  or return;
    my $profile = $c->stash('mcp.profile') or return;
    $self->auth->filter_aggregate($profile, $tools);
  });
  $self->aggregate($agg);
  return $self;
}

sub _setup_routes ($self) {
  my $r = $self->routes;

  # Public help / landing page, outside the auth bridge. In clients mode it
  # shows only a login form until a valid Authorization header is supplied, so
  # it never leaks which servers exist.
  $r->get('/' => sub ($c) { $self->_route_help($c) });

  my $under = $r->under('/' => sub ($c) { $self->auth->authenticate($c) });

  $under->get('/_hub/status'   => sub ($c) { $self->_route_status($c) });
  $under->post('/_hub/refresh' => sub ($c) { $self->_route_refresh($c) });

  my $aggregate_action = $self->aggregate->to_action({streaming => 1});
  $under->post('/all' => sub ($c) {
    my $profile = $c->stash('mcp.profile');
    return $c->render(json => {error => 'Not found'}, status => 404)
      unless grep { $self->auth->allows_server($profile, $_->name) } @{$self->upstreams};
    return $aggregate_action->($c);
  });

  for my $up (@{$self->upstreams}) {
    my $action = $up->server->to_action({streaming => 1});
    $under->post('/' . $up->name => sub ($c) { $self->_route_server($c, $up, $action) });
  }

  return $self;
}

sub start_background_fetches ($self) {
  for my $up (@{$self->upstreams}) {
    next if $up->type eq 'perl';    # perl upstreams need no warming
    if ($up->always_on) {
      $up->start_p->catch(sub ($err) { $self->log->error("$err") });
    }
    elsif (!$up->manifest_fetched_at) {
      # No cached manifest yet: fetch it once in the background, do not wait.
      # A stdio child is stopped again afterwards (lazy); an http upstream holds
      # no process, so it just stays ready.
      $up->start_p->then(sub ($u) { $u->stop if $u->type eq 'stdio' && !$u->always_on })
        ->catch(sub ($err) { $self->log->error("$err") });
    }
  }
  return $self;
}

# --- route handlers --------------------------------------------------------

sub _route_server ($self, $c, $up, $action) {
  my $profile = $c->stash('mcp.profile');
  return $c->render(json => {error => 'Not found'}, status => 404)
    unless $self->auth->allows_server($profile, $up->name);

  return $c->render(json => {error => "upstream '@{[$up->name]}' failed" . ($up->error ? ': ' . $up->error : '')},
    status => 503)
    if $up->state eq 'failed';

  return $c->render(json => {error => "upstream '@{[$up->name]}' is not ready yet"}, status => 503)
    if $up->type ne 'perl' && !@{$up->server->tools} && !$up->manifest_fetched_at;

  return $action->($c);
}

sub _route_help ($self, $c) {
  return $c->render(text => MCP::Hub::Help->page($self, $c), format => 'html');
}

sub _route_status ($self, $c) {
  return $c->render(json => {error => 'Forbidden'}, status => 403)
    unless ($c->stash('mcp.profile') // {})->{admin};
  return $c->render(json => $self->status_report);
}

sub _route_refresh ($self, $c) {
  return $c->render(json => {error => 'Forbidden'}, status => 403)
    unless ($c->stash('mcp.profile') // {})->{admin};

  my $name = ($c->req->json // {})->{name};
  return $self->refresh_p($name)
    ->then(sub ($counts) { $c->render(json => $counts) })
    ->catch(sub ($err) { $c->render(json => {error => "$err"}, status => 500) });
}

# --- helpers ---------------------------------------------------------------

sub _base_url ($listen) {
  # A wildcard or any-address listen address is not an address a client can
  # call: rewrite it to the matching loopback address.
  (my $base = $listen) =~ s{//(?:\*|0\.0\.0\.0)(?=[:/?]|$)}{//127.0.0.1};
  $base =~ s{//\[::\](?=[:/?]|$)}{//[::1]};
  $base =~ s{/+$}{};
  return $base;
}

sub _default_config_path {
  my $home = $ENV{XDG_CONFIG_HOME} || ($ENV{HOME} ? "$ENV{HOME}/.config" : '.config');
  return "$home/mcp-hub/config.json";
}

1;

=encoding utf8

=head1 SYNOPSIS

  # command line
  mcp-hub daemon
  mcp-hub config --client main
  mcp-hub token

  # embedding
  use MCP::Hub;
  my $hub = MCP::Hub->new(hub_config_input => '/path/to/config.json');

=head1 DESCRIPTION

L<MCP::Hub> is a single L<Mojolicious> HTTP server that embeds any number of
stdio MCP servers, in-process Perl MCP servers and remote HTTP MCP servers
(Streamable HTTP or HTTP+SSE), exposes each of them to many agents on the
machine as its own endpoint, decides per client which of them it may use, and
prints ready-to-paste client configuration. The goal in one line: a lot of MCP
for very little RAM.

Each embedded server keeps its own tool names, so C<mcp__context7__resolve>
stays C<mcp__context7__resolve>, existing permission rules keep working, and the
C</mcp> menu still lists servers separately. Servers start lazily on the first
tool call and stop again when idle, so a browser's ~110 MB only exist while
someone is using it.

Because everything is served over HTTP, the hub also serves a setup page at
C<GET /> (see L<MCP::Hub::Help>) that shows a user exactly what to paste into
their client -- token-gated in clients mode, so it never reveals which servers
exist to someone without a key. The token is only ever read from an
C<Authorization: Bearer> header, never from the URL.

See L<mcp-hub> for the command line and F<README.md> for the full story.

=head1 EXAMPLES

Run against a config file, from the command line:

  mcp-hub daemon                       # http://127.0.0.1:3080
  mcp-hub config --client worker-1     # the mcpServers JSON that client needs

Embed the hub in your own L<Mojolicious>-based tests or tooling:

  my $hub = MCP::Hub->new(hub_config_input => {
    mcpServers => {
      context7 => {command => 'npx', args => ['-y', '@upstash/context7-mcp']},
      run      => {class => 'MCP::Run', args => {allowed_commands => ['ls']}},
    },
  });

  # what a given client may see, as ready-to-paste client config
  my $data = $hub->export_config(url => 'http://127.0.0.1:3080');

  # refresh one upstream's manifest and get the new tool count
  $hub->refresh_p('context7')->then(sub ($counts) { say $counts->{context7} });

A bare C<mcpServers> block is a valid open-mode config, so an existing
F<.mcp.json> can be handed to the hub unchanged.

=head2 Process model

The daemon must run as a single L<Mojo::Server::Daemon> process, never under
hypnotoad or a pre-forking server: every worker would spawn its own children and
hold its own state. Everything -- child processes, idle timers, manifests,
in-process servers -- lives in one event loop, and tool calls are non-blocking
promises, so one slow upstream does not block the others.

=head1 ATTRIBUTES

L<MCP::Hub> inherits all attributes from L<Mojolicious> and adds:

=head2 aggregate

The L<MCP::Hub::Aggregate> mounted at C</all>.

=head2 auth

The L<MCP::Hub::Auth>.

=head2 hub_config

The resolved L<MCP::Hub::Config>. (Named C<hub_config> because L<Mojolicious>
already owns C<config>.)

=head2 hub_config_input

What to load the configuration from: a file path, a decoded hash reference, or a
ready L<MCP::Hub::Config>. When unset, C<$MCP_HUB_CONFIG> or the default path is
used.

=head2 upstreams

Array reference of L<MCP::Hub::Upstream> objects, in server-name order (the
order L<MCP::Hub::Config/servers> normalizes to). An entry that could not be
built at all keeps its place as a C<failed> upstream carrying the reason in
L<MCP::Hub::Upstream/error>, so one broken entry is visible in the status report
and on its own endpoint instead of taking the daemon down or disappearing.

=head2 upstreams_by_name

The same, keyed by name.

=head1 METHODS

L<MCP::Hub> inherits all methods from L<Mojolicious> and adds:

=head2 export_config

  my $data = $hub->export_config(client => 'main', all => 0, url => $base);

The C<< {mcpServers => {...}} >> structure an agent needs, one HTTP entry per
server the profile allows. Behind C<mcp-hub config>.

=head2 refresh_p

  $hub->refresh_p->then(sub ($counts) { ... });
  $hub->refresh_p('context7')->then(...);

Re-fetch upstream manifests (all, or one by name) and resolve to a
C<< { name => tool_count } >> hash reference.

=head2 rebuild_aggregate

Rebuild the C</all> server from the current upstreams.

=head2 start_background_fetches

  $hub->start_background_fetches;

Start any C<always_on> upstreams and kick off a one-off background manifest
fetch for every stdio and HTTP upstream without a cached manifest (a stdio child
is stopped again right afterwards). Called by the C<daemon> command, so that
C<config>, C<status>, C<token> and C<refresh> never spawn a child just by loading
the application.

=head2 startup

The L<Mojolicious> startup hook: load the configuration, build the upstreams and
the aggregate, and mount the routes. It starts no upstream itself.

=head2 status_report

The structure behind C<GET /_hub/status> and the C<hub_status> tool: the mode, a
row per upstream (L<MCP::Hub::Upstream/status_row>) and a row per client with
its C<profile> and the C<last_seen> epoch of its last authenticated request.

=head1 SEE ALSO

L<mcp-hub>, L<MCP::Hub::Config>, L<MCP::Hub::Auth>, L<MCP::Hub::Upstream::Stdio>,
L<MCP::Hub::Upstream::Http>, L<MCP::Hub::Help>, L<MCP>.

=cut
