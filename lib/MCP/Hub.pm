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
use JSON::PP     ();
use Mojo::IOLoop;
use Mojo::Promise;
use Scalar::Util qw(blessed);
use Time::HiRes  qw(stat);

# ABSTRACT: One HTTP MCP server that embeds many, for a lot of MCP on little RAM

has 'hub_config_input';
has 'hub_config';
has 'hub_config_path';
has 'config_error';
has cli => 0;
has 'active_cache_dir';
has auto_reload_interval => 2;
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

  # Pinned for the life of the process: a reload may report that hub.cache_dir
  # changed, but it never moves a running hub's manifest cache out from under
  # the upstreams that are already using it.
  $self->active_cache_dir($config->cache_dir);

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
    my $up   = $_;
    my $done = sub { +{name => $up->name, result => _refresh_result($up)} };
    $up->refresh_p->then($done)->catch($done);
  } @targets;

  return Mojo::Promise->all(@promises)->then(sub (@results) {
    $self->rebuild_aggregate;
    return {map { $_->[0]{name} => $_->[0]{result} } @results};
  });
}

# What a refresh reports for one upstream: the new tool count, its state, and --
# when it is failed (an unbuildable placeholder, or a crash-looping child a
# refresh could not revive) -- the reason, so `mcp-hub refresh` and hub_refresh
# show it as failed instead of "0 tools".
sub _refresh_result ($up) {
  return {
    count => scalar @{$up->server->tools},
    state => $up->state,
    (defined $up->error ? (error => $up->error) : ()),
  };
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

# --- live configuration reload ---------------------------------------------

sub reload ($self) {
  my $path = $self->hub_config_path;
  return $self->_refuse_reload('the configuration was not loaded from a file, so there is nothing to reload')
    unless defined $path;

  # Take the file's signature before reading it, never after: a file that
  # changes while we read it then still looks new to the watcher, instead of
  # being recorded as applied when it was not.
  my $signature = $self->_config_signature;

  my $new = eval { MCP::Hub::Config->from_file($path) };
  return $self->_refuse_reload($@ || 'unknown error') unless $new;

  $self->{config_signature} = $signature;
  return $self->_apply_config($new);
}

sub _refuse_reload ($self, $error) {
  # Carp appends its caller's location whatever the message ends in, and the
  # JSON decoder puts one of its own inside: neither tells anyone anything about
  # the file they are looking at. The same stripper folds the startup and CLI
  # errors, so a refused reload reads exactly like a rejected start-up.
  $error = MCP::Hub::Config::_strip_location($error);
  $self->log->error("configuration reload refused, keeping the running one: $error");
  return {ok => 0, error => $error};
}

sub _apply_config ($self, $new) {
  my $old = $self->hub_config;

  my @warnings;
  push @warnings, 'hub.listen changed from ' . $old->listen . ' to ' . $new->listen
    . ', restart the daemon to apply' if $old->listen ne $new->listen;
  push @warnings, 'hub.cache_dir changed from ' . $old->cache_dir . ' to ' . $new->cache_dir
    . ', restart the daemon to apply' if $old->cache_dir ne $new->cache_dir;

  my $auth_changed = !_same(
    [$old->profiles, $old->clients, $old->public_profile],
    [$new->profiles, $new->clients, $new->public_profile],
  );

  # Swap the configuration in one step, before anything is built or stopped.
  # Every live reader -- the tool filters, the setup page, export_config,
  # hub_status -- goes through these two, so from a request's point of view the
  # new profiles, clients and mode take effect all at once.
  $self->hub_config($new);
  $self->auth->config($new);

  my $previous = $self->upstreams_by_name;
  my %summary  = (added => [], removed => [], changed => [], unchanged => []);
  my (@ups, %by);

  for my $entry (@{$new->servers}) {
    my $name = $entry->{name};
    my $up   = $previous->{$name};

    if (!$up) {
      push @{$summary{added}}, $name;
      $up = $self->_build_upstream($entry, $new);
      $self->_warm_upstream($up);
    }
    else {
      my ($same, $timeouts_only) = _compare_entry($old, $old->server($name), $new, $entry);

      # A placeholder holds no process and no connection: it is always given
      # another try, even when its entry did not change.
      if ($same && !$up->placeholder) {
        push @{$summary{unchanged}}, $name;
      }
      elsif ($timeouts_only && !$up->placeholder) {
        push @{$summary{changed}}, $name;
        $up->config($entry);
        $up->apply_timeouts(_effective_timeouts($new, $entry));
      }
      else {
        push @{$summary{changed}}, $name;
        $up->stop;
        $up = $self->_build_upstream($entry, $new);
        $self->_warm_upstream($up);
      }
    }

    push @ups, $up;
    $by{$name} = $up;
  }

  for my $name (sort keys %$previous) {
    next if $by{$name};
    push @{$summary{removed}}, $name;
    $previous->{$name}->stop;
  }

  $self->upstreams(\@ups);
  $self->upstreams_by_name(\%by);
  $self->rebuild_aggregate;

  # Tell connected agents to list again. A server whose own tools are unchanged
  # is only notified when the access rules moved, because that is the only way
  # what it shows can have changed without it being rebuilt.
  if ($auth_changed) { $_->server->notify_list_changed('tools') for @ups }
  $self->aggregate->notify_list_changed('tools')
    if $auth_changed || grep { @{$summary{$_}} } qw(added removed changed);

  $self->_sync_config_watch;

  my $summary = {ok => 1, %summary, auth => ($auth_changed ? 1 : 0), warnings => \@warnings};
  $self->log->info('configuration reloaded -- ' . _summary_line($summary));
  $self->log->warn($_) for @warnings;
  return $summary;
}

sub schedule_reload ($self, $reason = 'a request') {
  # Triggers coalesce rather than race: a second signal, file event or request
  # arriving before the loop gets round to it joins the reload already queued.
  return $self if $self->{reload_scheduled};
  $self->{reload_scheduled} = 1;
  Mojo::IOLoop->next_tick(sub {
    delete $self->{reload_scheduled};
    $self->log->info("reloading the configuration ($reason)");
    $self->reload;
  });
  return $self;
}

sub watch_sighup ($self) {
  # Under EV a plain %SIG handler is only dispatched when the loop happens to
  # wake up for something else, so use EV's own signal watcher when EV is the
  # reactor -- it is part of the loop and fires straight away. Everywhere else
  # (Mojo::Reactor::Poll) %SIG is dispatched at the next tick of the poll. EV
  # is never loaded by us: this only uses it when Mojolicious already has.
  if ($INC{'EV.pm'} && Mojo::IOLoop->singleton->reactor->isa('Mojo::Reactor::EV')) {
    $self->{sighup} = EV::signal('HUP', sub { $self->schedule_reload('SIGHUP') });
  }
  else {
    $SIG{HUP} = sub { $self->schedule_reload('SIGHUP') };
  }
  return $self;
}

sub start_config_watch ($self) {
  $self->{watch_enabled}    = 1;
  $self->{config_signature} = $self->_config_signature;
  return $self->_sync_config_watch;
}

sub stop_config_watch ($self) {
  Mojo::IOLoop->remove(delete $self->{config_watch}) if $self->{config_watch};
  return $self;
}

sub watching_config ($self) { return $self->{config_watch} ? 1 : 0 }

# Called at the end of every reload, so that switching hub.auto_reload on or off
# in the file starts or stops the watcher.
sub _sync_config_watch ($self) {
  return $self unless $self->{watch_enabled};
  return $self->stop_config_watch unless $self->hub_config->auto_reload && defined $self->hub_config_path;
  return $self if $self->{config_watch};

  my $interval = $self->auto_reload_interval;
  $self->log->info('auto_reload: watching ' . $self->hub_config_path . " every ${interval}s");
  $self->{config_watch} = Mojo::IOLoop->recurring($interval => sub { $self->_poll_config_file });
  return $self;
}

sub _poll_config_file ($self) {
  my $signature = $self->_config_signature;
  return $self if $signature eq ($self->{config_signature} // '');

  # Recorded before the reload is even attempted, so a file that does not
  # validate is complained about once per change and not once per tick; the
  # next write is a new signature and is tried again.
  $self->{config_signature} = $signature;

  # No file right now: an editor is part way through replacing it. Say nothing
  # and pick up whatever turns up next.
  return $self unless length $signature;

  return $self->schedule_reload('auto_reload');
}

# Polled by path, never by handle: an editor that replaces the file by rename
# is seen, and in a container it means bind-mounting the directory works (a
# single bind-mounted file pins the inode and would never appear to change).
sub _config_signature ($self) {
  my $path = $self->hub_config_path // return '';
  my @stat = stat $path              or return '';
  return join ':', @stat[0, 1, 7, 9];
}

# --- build phases ----------------------------------------------------------

sub _resolve_config ($self) {
  my $input = $self->hub_config_input;
  return $input if blessed($input) && $input->isa('MCP::Hub::Config');
  return MCP::Hub::Config->from_data($input) if ref $input eq 'HASH';

  my $path = $input // $ENV{MCP_HUB_CONFIG} // _default_config_path();

  # Remembered for the life of the process, including when the file is not
  # there yet: a reload re-reads exactly this path and never runs the
  # config.json -> .yml -> .yaml lookup again, so a second file dropped next to
  # the active one can never take it over silently.
  $self->hub_config_path($path);

  unless (-f $path) {
    my $empty = MCP::Hub::Config->from_data({mcpServers => {}});
    $empty->{_missing} = $path;
    return $empty;
  }

  my $config = eval { MCP::Hub::Config->from_file($path) };
  return $config if $config;

  # A broken configuration file. Strip Carp's caller location, which points at
  # the hub's own internals rather than the file to fix (the JSON path is in the
  # message). On the command line a client command told exactly where the daemon
  # is (--url plus a token) must still run, so the error is remembered rather
  # than thrown and surfaces only if the command turns out to need the config
  # (see assert_config). Everywhere else -- an embedder, or a command that does
  # need it -- it is fatal now, the way it always was.
  my $error = MCP::Hub::Config::_strip_location($@);
  die "$error\n" unless $self->cli;
  $self->config_error($error);
  return MCP::Hub::Config->from_data({mcpServers => {}});
}

# The command layer calls this before it reaches for anything out of the
# configuration: if the file was broken and we deferred the error (see cli), now
# is when it becomes fatal, with the same clean message. A no-op when the
# configuration loaded.
sub assert_config ($self) {
  die $self->config_error . "\n" if defined $self->config_error;
  return $self;
}

sub _build_upstreams ($self) {
  my $config = $self->hub_config;
  my (@ups, %by);

  for my $entry (@{$config->servers}) {
    my $up = $self->_build_upstream($entry, $config);
    push @ups, $up;
    $by{$up->name} = $up;
  }

  $self->upstreams(\@ups);
  $self->upstreams_by_name(\%by);
  return $self;
}

sub _build_upstream ($self, $entry, $config) {
  my %opts = (hub => $self, log => $self->log);
  if ($entry->{type} ne 'perl') {
    %opts = (%opts, cache_dir => $self->active_cache_dir, %{_effective_timeouts($config, $entry)});
  }

  my $up = eval { MCP::Hub::Upstream->build($entry, %opts) };
  if (my $err = $@) {
    chomp $err;
    $self->log->error("failed to build upstream $entry->{name}: $err");
    $up = $self->_broken_upstream($entry, $err);
  }

  $self->_attach_tool_filter($up);
  return $up;
}

# What an entry ends up running with: its own hub block wins over the global
# defaults, exactly as MCP::Hub::Upstream's constructors resolve it. A perl
# upstream has neither.
sub _effective_timeouts ($config, $entry) {
  return {} if $entry->{type} eq 'perl';
  my %timeouts = (request_timeout => $entry->{request_timeout} // $config->request_timeout);
  $timeouts{idle_timeout} = $entry->{idle_timeout} // $config->idle_timeout if $entry->{type} eq 'stdio';
  return \%timeouts;
}

sub _broken_upstream ($self, $entry, $error) {
  # A misconfigured entry keeps its place as a failed upstream: it shows up in
  # the status report and answers 503 with the reason, instead of vanishing into
  # an indistinguishable 404. The daemon still starts.
  my $up = MCP::Hub::Upstream->new(
    name   => $entry->{name},
    config => $entry,
    hub         => $self,
    log         => $self->log,
    error       => $error,
    state       => 'failed',
    placeholder => 1,
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
  $under->post('/_hub/reload'  => sub ($c) { $self->_route_reload($c) });

  my $aggregate_action = $self->aggregate->to_action({streaming => 1});
  $under->post('/all' => sub ($c) {
    my $profile = $c->stash('mcp.profile');
    return $c->render(json => {error => 'Not found'}, status => 404)
      unless grep { $self->auth->allows_server($profile, $_->name) } @{$self->upstreams};
    return $aggregate_action->($c);
  });

  # One route for every upstream, resolved by name per request. Routes fixed at
  # start-up could not follow a reload; this one needs no touching when a server
  # is added, dropped or replaced. It is registered last, so /all and /_hub/*
  # keep their precedence, and a relaxed placeholder is used so that every
  # single-segment path lands here and is answered alike.
  $under->post('/#name' => sub ($c) { $self->_route_server($c, $c->stash('name')) });

  return $self;
}

sub start_background_fetches ($self) {
  $self->_warm_upstream($_) for @{$self->upstreams};
  return $self;
}

sub _warm_upstream ($self, $up) {
  return $self if $up->type eq 'perl';    # perl upstreams need no warming
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
  return $self;
}

# --- route handlers --------------------------------------------------------

sub _route_server ($self, $c, $name) {
  my $profile = $c->stash('mcp.profile');
  my $up      = $self->upstreams_by_name->{$name};

  # A name that does not exist and a name this profile may not see answer with
  # the same 404: a client must not be able to tell the two apart, and after a
  # reload dropped a server its path is simply unknown again.
  return $c->render(json => {error => 'Not found'}, status => 404)
    unless $up && $self->auth->allows_server($profile, $name);

  return $c->render(json => {error => "upstream '$name' failed" . ($up->error ? ': ' . $up->error : '')},
    status => 503)
    if $up->state eq 'failed';

  return $c->render(json => {error => "upstream '$name' is not ready yet"}, status => 503)
    if $up->type ne 'perl' && !@{$up->server->tools} && !$up->manifest_fetched_at;

  return $up->action->($c);
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

sub _route_reload ($self, $c) {
  return $c->render(json => {error => 'Forbidden'}, status => 403)
    unless ($c->stash('mcp.profile') // {})->{admin};

  # A configuration that does not validate is the server's problem, not the
  # caller's, so it is a 500 -- and the body says exactly what is wrong with it.
  my $summary = $self->reload;
  return $c->render(json => $summary, status => ($summary->{ok} ? 200 : 500));
}

# --- helpers ---------------------------------------------------------------

# Deep comparison of the normalized entries -- after ${VAR} expansion, so a
# changed environment variable counts as a change. Canonical JSON rather than a
# hand-written walk, because it also gets the booleans a class entry's args may
# carry right; anything that will not encode is reported as different, which
# rebuilds one upstream instead of quietly keeping a stale one.
my $CANONICAL = JSON::PP->new->canonical->allow_nonref->convert_blessed;

sub _same ($left, $right) {
  my $a = eval { $CANONICAL->encode($left) };
  my $b = eval { $CANONICAL->encode($right) };
  return defined $a && defined $b && $a eq $b;
}

# Returns (unchanged, only-the-timeouts-changed). The second is what lets a
# global hub.idle_timeout edit reach every stdio upstream without restarting a
# single child.
sub _compare_entry ($old_config, $old_entry, $new_config, $new_entry) {
  return (0, 0) unless $old_entry;
  my $same_entry = _same(_without_timeouts($old_entry), _without_timeouts($new_entry));
  return (0, 0) unless $same_entry;
  return (1, 0)
    if _same(_effective_timeouts($old_config, $old_entry), _effective_timeouts($new_config, $new_entry));
  return (0, 1);
}

sub _without_timeouts ($entry) {
  my %rest = %$entry;
  delete @rest{qw(idle_timeout request_timeout)};
  return \%rest;
}

sub _summary_line ($summary) {
  my @parts;
  for my $key (qw(added removed changed)) {
    push @parts, "$key " . join(', ', @{$summary->{$key}}) if @{$summary->{$key}};
  }
  push @parts, scalar(@{$summary->{unchanged}}) . ' unchanged';
  push @parts, 'access rules updated' if $summary->{auth};
  return join '; ', @parts;
}

sub _base_url ($listen) {
  # A wildcard or any-address listen address is not an address a client can
  # call: rewrite it to the matching loopback address.
  (my $base = $listen) =~ s{//(?:\*|0\.0\.0\.0)(?=[:/?]|$)}{//127.0.0.1};
  $base =~ s{//\[::\](?=[:/?]|$)}{//[::1]};
  $base =~ s{/+$}{};
  return $base;
}

# Config file extensions tried in a directory, first that exists wins. JSON
# leads, so a directory that has always held a .json config keeps using it even
# if a .yml turns up beside it -- and the extension still picks the parser.
my @CONFIG_EXTS = qw(json yml yaml);

# Where the config file is looked up when no path is pinned. $MCP_HUB_CONFIG_DIR
# names a config-mount directory (the file is `mcp.<ext>` there, the convention
# the Docker image mounts at /config); otherwise the XDG config directory is
# searched for `config.<ext>`. Either way it is file-name resolution, not a
# tunable knob: $MCP_HUB_CONFIG still pins an exact file and skips this.
sub _default_config_path {
  my $dir = $ENV{MCP_HUB_CONFIG_DIR};
  return _stem_config_path($dir, 'mcp') if defined $dir && length $dir;

  my $home = $ENV{XDG_CONFIG_HOME} || ($ENV{HOME} ? "$ENV{HOME}/.config" : '.config');
  return _stem_config_path("$home/mcp-hub", 'config');
}

# First existing <dir>/<stem>.<ext>, JSON leading. When none is there, name the
# canonical .json one, so the warning points at the file a user should create.
sub _stem_config_path ($dir, $stem) {
  for my $ext (@CONFIG_EXTS) {
    return "$dir/$stem.$ext" if -f "$dir/$stem.$ext";
  }
  return "$dir/$stem.$CONFIG_EXTS[0]";
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
  $hub->refresh_p('context7')->then(sub ($counts) { say $counts->{context7}{count} });

A bare C<mcpServers> block is a valid open-mode config, so an existing
F<.mcp.json> can be handed to the hub unchanged.

=head2 Reloading

A running hub re-reads its configuration file on C<SIGHUP>, on
C<POST /_hub/reload> (behind C<mcp-hub reload>), and by itself when
C<hub.auto_reload> is set. All three go through L</reload>, which touches only
what actually changed in the file: a server whose entry is untouched keeps its
object, its process, its statistics and its idle timer, while a server that was
removed is stopped and unmounted and a new one is mounted lazily. A
configuration that does not validate changes nothing at all -- the running one
stays fully in effect and the error, with its JSON path, is logged and returned.

=head2 Process model

The daemon must run as a single L<Mojo::Server::Daemon> process, never under
hypnotoad or a pre-forking server: every worker would spawn its own children and
hold its own state. Everything -- child processes, idle timers, manifests,
in-process servers -- lives in one event loop, and tool calls are non-blocking
promises, so one slow upstream does not block the others.

=head1 ATTRIBUTES

L<MCP::Hub> inherits all attributes from L<Mojolicious> and adds:

=head2 active_cache_dir

The manifest cache directory the hub actually uses, fixed when it started. A
reload reports that C<hub.cache_dir> changed and keeps this one, so the
upstreams never disagree about where their manifests live.

=head2 aggregate

The L<MCP::Hub::Aggregate> mounted at C</all>.

=head2 auth

The L<MCP::Hub::Auth>.

=head2 auto_reload_interval

How often the C<hub.auto_reload> watcher stats the configuration file, in
seconds. Defaults to C<2>. It is an attribute rather than a configuration key
because there is nothing to tune in a deployment; tests set it lower.

=head2 cli

Whether the hub is running as the C<mcp-hub> command-line tool, set by
F<bin/mcp-hub> and false when embedded. When true, a broken configuration
B<file> is remembered in L</config_error> rather than thrown at start-up, so a
client command told exactly where the daemon is (C<--url> plus a token) can
still reach it while the file is invalid. See L</assert_config>.

=head2 config_error

The reason the configuration file could not be loaded, folded onto one line
with Carp's location stripped, or C<undef> when it loaded. Only ever set under
L</cli>; L</assert_config> turns it back into a fatal error where the
configuration is actually needed.

=head2 hub_config

The resolved L<MCP::Hub::Config>. (Named C<hub_config> because L<Mojolicious>
already owns C<config>.)

=head2 hub_config_input

What to load the configuration from: a file path, a decoded hash reference, or a
ready L<MCP::Hub::Config>. A path is read by L<MCP::Hub::Config/from_file>, so
its extension picks the syntax -- C<.yml> and C<.yaml> are YAML, anything else
is JSON -- and an explicitly given path is used exactly as given.

When unset, C<$MCP_HUB_CONFIG> is used, and failing that a directory is searched
for the first file that exists, JSON leading: C<$MCP_HUB_CONFIG_DIR> when set --
a config-mount directory holding F<mcp.json>, F<mcp.yml> or F<mcp.yaml>, the
convention the Docker image mounts at F</config> -- otherwise the XDG config
directory (C<$XDG_CONFIG_HOME/mcp-hub>, or C<~/.config/mcp-hub>) holding
F<config.json>, F<config.yml> or F<config.yaml>. If none exists, the hub starts
with no servers and logs a warning naming the F<.json> one.

=head2 hub_config_path

The file L</hub_config> was read from, resolved once at start-up and then fixed,
or C<undef> when the configuration was handed over as data. L</reload> re-reads
exactly this path: the default lookup is never run a second time, so a
F<config.yml> dropped next to an active F<config.json> cannot take over
silently. It is set even when the file was not there at start-up, so creating it
and reloading works.

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

=head2 assert_config

  $hub->assert_config;

Die with the deferred L</config_error> when there is one, otherwise do nothing.
The command layer calls it before reaching for anything out of the
configuration, so a broken file is fatal exactly where the configuration is
needed and silent where it is not (see L</cli>).

=head2 export_config

  my $data = $hub->export_config(client => 'main', all => 0, url => $base);

The C<< {mcpServers => {...}} >> structure an agent needs, one HTTP entry per
server the profile allows. Behind C<mcp-hub config>.

=head2 refresh_p

  $hub->refresh_p->then(sub ($counts) { ... });
  $hub->refresh_p('context7')->then(...);

Re-fetch upstream manifests (all, or one by name) and resolve to a
C<< { name => { count, state, error } } >> hash reference: the new tool count
and state of each refreshed upstream, plus C<error> with the reason when it is
C<failed> -- so a failed upstream reports its failure rather than C<0> tools.

=head2 rebuild_aggregate

Rebuild the C</all> server from the current upstreams.

=head2 reload

  my $summary = $hub->reload;

Re-read L</hub_config_path> and apply only what changed in it. Returns a summary
hash reference and never dies:

  {
    ok => 1, added => ['serper'], removed => ['playwright'], changed => [],
    unchanged => ['context7', 'history'], auth => 0, warnings => [],
  }

A configuration that does not parse or does not validate is B<refused whole>:
nothing is swapped, the running configuration stays in effect, and the reason --
with its JSON path -- is logged at error level and returned as
C<< {ok => 0, error => ...} >>. The same goes for a hub that was handed its
configuration as data rather than a file: there is nothing to re-read.

What a reload does per server, comparing the normalized entries (so C<${VAR}>
expansion counts, and a changed environment variable is a changed entry):

=over 2

=item B<unchanged> -- nothing at all. Same object, same process, same statistics,
same idle timer. This is the property the whole thing exists for.

=item B<only the timeouts changed> -- applied to the live object
(L<MCP::Hub::Upstream/apply_timeouts>), so editing the global
C<hub.idle_timeout> does not restart a single child.

=item B<changed> -- that one upstream is stopped and built again. Nothing else
is touched.

=item B<removed> -- stopped and unmounted. Its path answers C<404> again and it
leaves C</all> and the status report.

=item B<added> -- built and mounted, and warmed exactly as at daemon start: an
C<always_on> server starts, one without a cached manifest fetches it once in the
background, and B<anything else spawns nothing> -- lazy start is a promise a
reload keeps too.

=item B<a broken placeholder> -- always built again, even when its entry did not
change, because it holds no process (L<MCP::Hub::Upstream/placeholder>). A
genuinely failed upstream, a crash-looping child say, is left alone; L</refresh_p>
is the way back from that.

=back

C<profiles>, C<clients> and C<public_profile> are swapped in one step before any
of that, so from a request's point of view the new access rules -- including a
flip between open and clients mode -- take effect all at once, without a single
upstream being restarted. L<MCP::Hub::Auth/last_seen> survives, and every
affected server is sent a C<tools/list_changed> notification.

C<hub.listen> and C<hub.cache_dir> cannot be applied to a running daemon.
Everything else is applied and the summary's C<warnings> say what needs a
restart.

=head2 schedule_reload

  $hub->schedule_reload('SIGHUP');

Queue a L</reload> on the event loop instead of running it here and now.
Triggers coalesce: anything arriving before the loop gets round to it joins the
reload already queued, so signals and file events can never race.

=head2 start_background_fetches

  $hub->start_background_fetches;

Start any C<always_on> upstreams and kick off a one-off background manifest
fetch for every stdio and HTTP upstream without a cached manifest (a stdio child
is stopped again right afterwards). Called by the C<daemon> command, so that
C<config>, C<status>, C<token> and C<refresh> never spawn a child just by loading
the application.

=head2 start_config_watch

  $hub->start_config_watch;

Start watching L</hub_config_path> when C<hub.auto_reload> is set, and allow
later reloads to start or stop that watcher as the file turns the setting on and
off. Called by the C<daemon> command; the short-lived commands never watch
anything. The file is polled by path every L</auto_reload_interval> seconds --
device, inode, size and modification time -- so a rename-in-place by an editor
is seen, and in a container the configuration B<directory> should be mounted
rather than the single file, whose inode a bind mount would pin. A write that
does not validate is complained about once and keeps the running configuration;
the next write is picked up as usual.

=head2 startup

The L<Mojolicious> startup hook: load the configuration, build the upstreams and
the aggregate, and mount the routes. It starts no upstream itself.

=head2 status_report

The structure behind C<GET /_hub/status> and the C<hub_status> tool: the mode, a
row per upstream (L<MCP::Hub::Upstream/status_row>) and a row per client with
its C<profile> and the C<last_seen> epoch of its last authenticated request.

=head2 stop_config_watch

Stop the C<hub.auto_reload> watcher.

=head2 watch_sighup

  $hub->watch_sighup;

Make C<SIGHUP> trigger a L</schedule_reload>. Called by the C<daemon> command
and by no other, so a C<SIGHUP> to C<mcp-hub status> still just kills it. Under
the L<EV> reactor an L<EV> signal watcher is installed rather than a C<%SIG>
handler, because a C<%SIG> handler is only dispatched when the loop happens to
wake up for something else; L<EV> is only used when it is already loaded.

=head2 watching_config

Whether the C<hub.auto_reload> watcher is currently running.

=head1 SEE ALSO

L<mcp-hub>, L<MCP::Hub::Config>, L<MCP::Hub::Auth>, L<MCP::Hub::Upstream::Stdio>,
L<MCP::Hub::Upstream::Http>, L<MCP::Hub::Help>, L<MCP>.

=cut
