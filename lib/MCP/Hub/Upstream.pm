package MCP::Hub::Upstream;
our $VERSION = '0.001';
use Mojo::Base 'Mojo::EventEmitter', -signatures;

use MCP::Hub::Facade;
use MCP::Hub::Facade::Server;
use Mojo::Log;
use Mojo::Promise;

# ABSTRACT: Base class for an upstream MCP server mounted in the hub

has 'name';
# The Mojolicious action this upstream is served by, built once and kept: the
# router holds one dynamic route and looks the upstream up per request, so the
# action must live with the object it serves, not with the route. Building it
# twice would replace the MCP::Server transport and drop its subscriptions.
has action    => sub ($self) { $self->server->to_action({streaming => 1}) };
has 'config';
has 'error';
has 'hub';
has log       => sub { Mojo::Log->new };
has placeholder => 0;
has 'server';
has state     => 'stopped';
has 'last_used';
has stats     => sub { {calls => 0, errors => 0, started_at => undef, pid => undef} };
has protocol_version => '2025-06-18';
has request_timeout  => 60;

my %IMPL = (perl => 'MCP::Hub::Upstream::Perl', stdio => 'MCP::Hub::Upstream::Stdio',
  http => 'MCP::Hub::Upstream::Http', sse => 'MCP::Hub::Upstream::Http');

sub build ($class, $entry, %opts) {
  my $impl = $IMPL{$entry->{type}} // 'MCP::Hub::Upstream::Stdio';
  return $impl->new(name => $entry->{name}, config => $entry, %opts);
}

sub type ($self) { return $self->config->{type} }

sub manifest_fetched_at ($self) { return $self->{manifest_fetched_at} }

sub always_on ($self) { return $self->config->{always_on} ? 1 : 0 }

# Default lifecycle -- subclasses override what they need.
sub start_p ($self) {
  return Mojo::Promise->reject("upstream @{[$self->name]}: " . ($self->error // 'failed'))
    if $self->state eq 'failed';
  return Mojo::Promise->resolve($self);
}

sub stop      ($self) { return $self }
sub refresh_p ($self) { return Mojo::Promise->resolve($self) }
sub touch     ($self) { $self->last_used(time); return $self }

# A configuration reload that only moved the timeouts must not restart anything:
# the new values are applied to the live object instead of rebuilding it.
sub apply_timeouts ($self, $timeouts) {
  $self->request_timeout($timeouts->{request_timeout}) if defined $timeouts->{request_timeout};
  return $self;
}

# --- transport-agnostic MCP client (shared by stdio and http) --------------
# Subclasses provide the transport: _request_p, _notify and _hash.

sub call_tool ($self, $name, $args) {
  $self->stats->{calls}++;
  return $self->start_p->then(sub {
    $self->touch;
    return $self->_request_p('tools/call', {name => $name, arguments => $args});
  })->catch(sub ($err) {
    $self->stats->{errors}++;
    return {content => [{type => 'text', text => "$err"}], isError => \1};
  });
}

sub get_prompt ($self, $name, $args) {
  return $self->start_p->then(sub {
    $self->touch;
    return $self->_request_p('prompts/get', {name => $name, arguments => $args});
  })->catch(sub ($err) {
    return {description => "$err", messages => [{role => 'user', content => {type => 'text', text => "$err"}}]};
  });
}

sub read_resource ($self, $uri) {
  return $self->start_p->then(sub {
    $self->touch;
    return $self->_request_p('resources/read', {uri => $uri});
  })->catch(sub ($err) {
    return {contents => [{uri => $uri, mimeType => 'text/plain', text => "$err"}]};
  });
}

sub _build_server ($self) {
  my $server = MCP::Hub::Facade::Server->new(name => $self->name, version => '0.0.0');
  $self->server($server);
  if (my $manifest = $self->{manifest}->load($self->name, $self->_hash)) {
    MCP::Hub::Facade->apply($server, $self, $manifest);
    $self->{manifest_fetched_at} = $manifest->{fetched_at};
    $self->{server_protocol}     = $manifest->{protocol_version};
    $self->{server_info}         = $manifest->{server_info};
    $self->{capabilities}        = $manifest->{capabilities};
    $self->{instructions}        = $manifest->{instructions};
  }
  return $server;
}

sub _manifest_from ($self, $lists) {
  return {
    name             => $self->name,
    hash             => $self->_hash,
    fetched_at       => _now_iso(),
    protocol_version => $self->{server_protocol},
    server_info      => $self->{server_info},
    capabilities     => $self->{capabilities},
    instructions     => $self->{instructions},
    tools            => $lists->{tools},
    prompts          => $lists->{prompts},
    resources        => $lists->{resources},
  };
}

sub _apply_manifest ($self, $manifest) {
  $self->{manifest}->store($manifest);
  $self->{manifest_fetched_at} = $manifest->{fetched_at};
  MCP::Hub::Facade->apply($self->server, $self, $manifest);
  $self->server->notify_list_changed('tools');
  $self->hub->rebuild_aggregate if $self->hub && $self->hub->can('rebuild_aggregate');
  return $self;
}

sub _handshake_p ($self) {
  return $self->_request_p('initialize', {
    protocolVersion => $self->protocol_version,
    capabilities    => {},
    clientInfo      => {name => 'mcp-hub', version => $VERSION},
  })->then(sub ($result) {
    $self->{server_protocol} = $result->{protocolVersion} // $self->protocol_version;
    $self->{capabilities}    = $result->{capabilities}    // {};
    $self->{server_info}     = $result->{serverInfo}      // {name => $self->name, version => '0.0.0'};
    $self->{instructions}    = $result->{instructions};
    $self->_notify('notifications/initialized');
    return $self->_list_all_p;
  })->then(sub ($lists) {
    return $self->_manifest_from($lists);
  });
}

sub _list_all_p ($self) {
  my $caps = $self->{capabilities} // {};
  my %out;
  return $self->_paginate_p('tools/list', 'tools')->then(sub ($tools) {
    $out{tools} = $tools;
    return exists $caps->{prompts} ? $self->_paginate_p('prompts/list', 'prompts')->catch(sub {[]}) : [];
  })->then(sub ($prompts) {
    $out{prompts} = $prompts;
    return exists $caps->{resources} ? $self->_paginate_p('resources/list', 'resources')->catch(sub {[]}) : [];
  })->then(sub ($resources) {
    $out{resources} = $resources;
    return \%out;
  });
}

sub _paginate_p ($self, $method, $key, $cursor = undef, $acc = undef) {
  $acc //= [];
  my $params = defined $cursor ? {cursor => $cursor} : {};
  return $self->_request_p($method, $params)->then(sub ($result) {
    push @$acc, @{$result->{$key} // []};
    my $next = $result->{nextCursor};
    return (defined $next && length $next) ? $self->_paginate_p($method, $key, $next, $acc) : $acc;
  });
}

# Subclasses must provide these.
sub _request_p ($self, @) { return Mojo::Promise->reject('_request_p not implemented') }
sub _notify    ($self, @) { return undef }
sub _hash      ($self)    { return $self->name }

sub _now_iso {
  my @t = gmtime;
  return sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0];
}

sub rss_kb ($self) {
  my $pid = $self->stats->{pid} or return undef;
  return _rss($pid);
}

sub status_row ($self) {
  return {
    name                => $self->name,
    type                => $self->type,
    state               => $self->state,
    (defined $self->error ? (error => $self->error) : ()),
    pid                 => $self->stats->{pid},
    rss_kb              => $self->rss_kb,
    manifest_fetched_at => $self->{manifest_fetched_at},
    last_used           => $self->last_used,
    calls               => $self->stats->{calls},
    errors              => $self->stats->{errors},
  };
}

sub _rss ($pid) {
  open my $fh, '<', "/proc/$pid/status" or return undef;
  while (my $line = <$fh>) { return $1 + 0 if $line =~ /^VmRSS:\s+(\d+)/ }
  return undef;
}

1;

=encoding utf8

=head1 SYNOPSIS

  use MCP::Hub::Upstream;

  my $upstream = MCP::Hub::Upstream->build($config_entry, hub => $hub);
  $upstream->start_p->then(sub { ... });

=head1 DESCRIPTION

L<MCP::Hub::Upstream> is the common interface for the three kinds of upstream the
hub mounts: a stdio child process (L<MCP::Hub::Upstream::Stdio>), a remote HTTP
server (L<MCP::Hub::Upstream::Http>) and an in-process Perl server
(L<MCP::Hub::Upstream::Perl>). Each presents its tools, prompts and resources
through an L<MCP::Server> stored in L</server>, which the hub mounts at
C</< name >>.

The base class also holds the transport-agnostic MCP client -- the handshake,
the paginated primitive lists, the manifest and the C<tools/call>,
C<prompts/get> and C<resources/read> forwarding -- so a subclass only provides
the transport.

=head1 ATTRIBUTES

=attr action

The L<Mojolicious> action serving this upstream's L</server>, built on first use
and then kept. The hub mounts one dynamic route for all upstreams and resolves
the name per request, so the action belongs to the upstream rather than to a
route; keeping it also keeps the L<MCP::Server> transport, and with it any open
streaming subscription.

=attr config

The normalized configuration entry from L<MCP::Hub::Config>.

=attr error

Why the upstream is C<failed>, as a string, or C<undef>. Set when an entry
cannot be built at all (an unloadable C<class>, say), when a stdio child
crash-loops, and when a remote HTTP upstream repeatedly fails to connect;
reported in L</status_row> and in the C<503> body of its endpoint.

=attr hub

The L<MCP::Hub> instance, when mounted in one.

=attr last_used

Epoch seconds of the last request, updated by L</touch>.

=attr log

A L<Mojo::Log>.

=attr name

The server name, and the path it is mounted at.

=attr placeholder

True when this upstream is the stand-in the hub puts in place of an entry that
could not be built at all (see L<MCP::Hub/upstreams>). It holds no process and
no connection, so a configuration reload always tries to build it again, even
when its entry did not change -- "I installed the missing module, now reload"
works. A genuine upstream that failed later, a crash-looping child say, is left
alone by a reload; L</refresh_p> is the way back from that.

=attr protocol_version

The protocol version the handshake opens with. Defaults to C<2025-06-18>; the
version the upstream answers with is what the hub then uses.

=attr request_timeout

Seconds to wait for an upstream response. Defaults to C<60>.

=attr server

The L<MCP::Server> agents talk to.

=attr state

One of C<stopped>, C<starting>, C<ready> or C<failed>.

=attr stats

Hash reference with C<calls>, C<errors>, C<started_at> and C<pid>.

=head1 METHODS

=method always_on

Whether the upstream is started at daemon start and never idle-stopped, from the
entry's C<hub.always_on>.

=method apply_timeouts

  $up->apply_timeouts({idle_timeout => 120, request_timeout => 30});

Apply new timeouts to the running upstream. Used by L<MCP::Hub/reload> when a
reload changed nothing about an entry except its timeouts, so that a global
C<hub.idle_timeout> edit does not restart every child. The stdio subclass also
re-arms a running idle timer with the new value.

=method build

  my $upstream = MCP::Hub::Upstream->build($entry, hub => $hub);

Construct the right subclass for a configuration entry.

=method call_tool

  my $promise = $up->call_tool($name, $args);

Forward a C<tools/call>, starting the upstream if needed. Always resolves to a
result hash: the upstream's own result unchanged, or an error result on a
JSON-RPC error, timeout, crash or failed start.

=method get_prompt

  my $promise = $up->get_prompt($name, $args);

Forward a C<prompts/get>, starting the upstream if needed.

=method manifest_fetched_at

When the manifest currently in L</server> was fetched, as an ISO timestamp, or
C<undef> when none has been fetched yet.

=method read_resource

  my $promise = $up->read_resource($uri);

Forward a C<resources/read>, starting the upstream if needed.

=method refresh_p

Re-fetch the manifest and rebuild L</server>. A promise. For a C<failed>
upstream this is the explicit "try again": it clears the failure first. A no-op
for Perl upstreams.

=method rss_kb

Resident set size of the child in kilobytes from C</proc>, or C<undef>.

=method start_p

Start the upstream if needed and resolve when it is C<ready>. Idempotent. A
C<failed> upstream is not started: the promise is rejected with L</error>, so a
tool call reports the failure instead of restarting a crash loop. Only
L</refresh_p> leaves the C<failed> state.

=method status_row

The per-upstream row of C<GET /_hub/status>: C<name>, C<type>, C<state>, C<pid>,
C<rss_kb>, C<manifest_fetched_at>, C<last_used>, C<calls>, C<errors>, and
C<error> when one is set.

=method stop

Terminate the upstream. A no-op for Perl upstreams.

=method touch

Reset L</last_used> and the idle timer.

=method type

C<stdio>, C<http>, C<sse> or C<perl>.

=head1 SEE ALSO

L<MCP::Hub::Upstream::Stdio>, L<MCP::Hub::Upstream::Http>,
L<MCP::Hub::Upstream::Perl>, L<MCP::Hub>.

=cut
