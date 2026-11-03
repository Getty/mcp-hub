package MCP::Hub::Upstream::Docker;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Hub::Upstream', -signatures;

use Crypt::PRNG  qw(random_bytes_hex);
use MCP::Hub::Docker;
use MCP::Hub::Manifest;
use MCP::Hub::Upstream::Docker::Http;
use MCP::Hub::Upstream::Docker::Stdio;
use Mojo::IOLoop;
use Mojo::Promise;
use Mojo::UserAgent;
use Scalar::Util qw(refaddr weaken);

# ABSTRACT: An MCP server in a Docker container, started from its image name

# The quick docker commands (inspect, ps, port, stop, rm) get this long: a
# daemon that hangs must not hang a start, or a shutdown, with it.
use constant CLI_TIMEOUT => 60;

# How often a container that is not listening yet is asked again.
use constant RETRY_INTERVAL => 0.5;

# The crash-loop rule of MCP::Hub::Upstream::Stdio: three failed starts or
# unexpected exits within fail_window seconds mark the upstream `failed`.
use constant FAIL_THRESHOLD => 3;

# How long a start waits at most for the previous container of the same server
# to be gone.
use constant SETTLE_WAIT => 30;

has cache_dir    => sub ($self) { $self->hub ? $self->hub->hub_config->cache_dir : '.' };
has docker       => sub ($self) {
  MCP::Hub::Docker->new(command => $self->config->{docker_command} // 'docker', log => $self->log);
};
has fail_window  => 5;
has idle_timeout => 300;
has owner_id     => sub ($self) { $self->docker->owner_id($self->cache_dir) };

# The containers still being stopped, per server. A start waits until the
# previous container of its server is gone, whichever upstream object started
# it: across a reload the old object and the new one share the name, and the
# old one's late cleanup must never meet the new one's container.
my %SETTLING;

sub new ($class, %args) {
  my $self = $class->SUPER::new(%args);
  my $c    = $self->config;

  $self->{manifest}        = MCP::Hub::Manifest->new(cache_dir => $self->cache_dir);
  $self->{idle_timeout}    = $c->{idle_timeout}    if defined $c->{idle_timeout};
  $self->{request_timeout} = $c->{request_timeout} if defined $c->{request_timeout};
  $self->{failures}        = [];

  $self->_build_server;
  return $self;
}

# How the hub talks to the container on its current start: `stdio` or `http`,
# or undef before the first start. It is decided anew on every start.
sub mode ($self) { return $self->{plan} ? $self->{plan}{mode} : undef }

# --- public lifecycle ------------------------------------------------------

sub start_p ($self) {
  return Mojo::Promise->resolve($self) if $self->state eq 'ready' && $self->{engine};
  return $self->{start_promise} if $self->{start_promise};

  # A crash loop is left only by an explicit refresh, as for a stdio child.
  return Mojo::Promise->reject("upstream @{[$self->name]}: "
      . ($self->error // 'failed')
      . ", run 'mcp-hub refresh @{[$self->name]}' to try again")
    if $self->state eq 'failed';

  # A connection that went away on its own may have left its engine behind.
  $self->_drop_engine;
  delete $self->{stop_requested};
  $self->state('starting');

  my $done = $self->{start_promise} = Mojo::Promise->new;
  my ($engine, $handshake);

  $self->_settled_p->then(sub {
    $self->_check_stop;
    $self->owner_id;    # no id of its own, no docker command at all
    return $self->_plan_p;
  })->then(sub ($plan) {
    $self->_check_stop;
    $self->{plan} = $plan;
    # A leftover of this hub -- an orphan of a crash -- would block the name.
    return $self->docker->remove_orphans_p($self->name, $self->owner_id, timeout => CLI_TIMEOUT);
  })->then(sub {
    $self->_check_stop;
    return $self->_prepare_p($self->{plan});
  })->then(sub {
    $self->_check_stop;
    $engine = $self->{engine} = $self->_new_engine($self->{plan});
    return $self->{plan}{mode} eq 'http' ? $self->_launch_http_p($engine, $self->{plan}) : undef;
  })->then(sub {
    $self->_check_stop;
    $handshake = 1;
    return $engine->start_p;
  })->then(sub {
    # A stop that came during the handshake: the container goes, unused.
    $self->_check_stop;
    delete $self->{failed};    # a running container is never failed
    $self->error(undef);
    $self->state('ready');
    delete $self->{start_promise};
    $self->touch;
    $done->resolve($self);
  })->catch(sub ($err) {
    $err = $self->_bare_error($err);
    my $stopped = delete $self->{stop_requested};
    $err = $self->_with_output($engine, $err) if $engine && !$stopped;
    $self->_drop_engine;
    delete $self->{start_promise};

    if ($stopped) {
      $self->state('stopped');
      $done->reject("upstream @{[$self->name]}: stopped while starting");
      return;
    }

    # The engine logs a failed handshake itself; everything before it is ours.
    $self->log->error("[@{[$self->name]}] cannot start: $err") unless $handshake;
    $self->_record_failure($err);
    $self->state($self->{failed} ? 'failed' : 'stopped');
    $done->reject("upstream @{[$self->name]}: $err");
    return;    # never hand the rejected promise back into the chain
  });

  return $done;
}

sub stop ($self) {
  $self->_clear_idle_timer;

  # A start in progress is told to give up; a handshake that is already
  # running is cut short, and a container that is still being created is
  # removed by the start itself once its docker command returns.
  if ($self->{start_promise}) {
    $self->{stop_requested} = 1;
    $self->{engine}->stop if $self->{engine};
    return $self;
  }

  $self->_drop_engine;
  $self->state('stopped') unless $self->state eq 'failed';
  return $self;
}

# Resolves once every container this server had is gone -- what a shutdown
# waits for after stop.
sub stopped_p ($self) { return $self->_settled_p }

sub refresh_p ($self) {
  if ($self->state eq 'ready' && $self->{engine}) {
    return $self->{engine}->refresh_p->then(sub { $self });
  }
  $self->_clear_failure if $self->state eq 'failed';
  return $self->start_p;
}

sub touch ($self) {
  $self->last_used(time);
  $self->_arm_idle_timer if $self->state eq 'ready';
  return $self;
}

sub apply_timeouts ($self, $timeouts) {
  $self->SUPER::apply_timeouts($timeouts);
  $self->{engine}->apply_timeouts({request_timeout => $timeouts->{request_timeout}})
    if $self->{engine} && defined $timeouts->{request_timeout};

  return $self unless defined(my $idle = $timeouts->{idle_timeout});
  $self->idle_timeout($idle);
  return $self unless $self->state eq 'ready';
  $self->_clear_idle_timer;
  $self->_arm_idle_timer;
  return $self;
}

sub status_row ($self) {
  my $row = $self->SUPER::status_row;
  $row->{container} = $self->docker->container_name($self->name);
  $row->{mode}      = $self->mode if defined $self->mode;
  return $row;
}

# --- what the base class forwards ------------------------------------------

sub _hash ($self) { return $self->{manifest}->hash($self->docker->hash_input($self->config)) }

sub _request_p ($self, $method, $params = {}) {
  my $engine = $self->{engine}
    or return Mojo::Promise->reject("upstream @{[$self->name]}: not running");
  return $engine->_request_p($method, $params);
}

sub _notify ($self, $method, $params = {}) {
  my $engine = $self->{engine} or return undef;
  return $engine->_notify($method, $params);
}

# --- deciding stdio or HTTP ------------------------------------------------

# Pull the image if it is missing, then decide how to talk to it: a `port`
# means HTTP on it, an image that EXPOSEs exactly one port means HTTP on that
# one, no EXPOSE means stdio -- and `"stdio": true` means stdio whatever the
# image declares.
sub _plan_p ($self) {
  my $c     = $self->config;
  my $image = $c->{image};

  return $self->docker->image_ports_p($image, timeout => CLI_TIMEOUT)->then(sub ($ports) {
    return {mode => 'stdio'} if $c->{stdio};
    return {mode => 'http', port => $c->{port}, from => 'port'} if defined $c->{port};
    return {mode => 'http', port => $ports->[0], from => 'expose'} if @$ports == 1;
    die "image $image exposes " . _ports($ports) . ' -- set "port" to the one the MCP server listens on' . "\n"
      if @$ports > 1;
    $self->_check_stdio("image $image exposes no port");
    return {mode => 'stdio'};
  });
}

# path, type and headers are allowed without a port, for an image whose EXPOSE
# turns out to make it HTTP. When it turns out to be stdio, they cannot apply.
sub _check_stdio ($self, $why) {
  my $c     = $self->config;
  my @given = (
    (defined $c->{path}             ? 'path'    : ()),
    (defined $c->{transport}        ? 'type'    : ()),
    (%{$c->{headers} // {}}         ? 'headers' : ()),
  );
  return unless @given;
  die "$why, so the hub talks to it over stdio -- "
    . join(', ', map {qq{"$_"}} @given)
    . ' only appl' . (@given > 1 ? 'y' : 'ies')
    . ' to an HTTP server: set "port", or remove '
    . (@given > 1 ? 'them' : 'it') . "\n";
}

sub _ports ($ports) {
  my @p = map {"$_/tcp"} @$ports;
  return @p > 1 ? join(', ', @p[0 .. $#p - 1]) . " and $p[-1]" : $p[0];
}

# Whatever must happen before the container starts and may take long -- for a
# docker entry the pull, which _plan_p has done already -- so that the
# handshake's request_timeout never includes it.
sub _prepare_p ($self, $plan) { return Mojo::Promise->resolve }

# --- the container, by kind ------------------------------------------------

sub _new_engine ($self, $plan) {
  my $run    = random_bytes_hex(6);
  my %common = (
    name            => $self->name,
    server          => $self->server,
    hash            => $self->_hash,
    log             => $self->log,
    cache_dir       => $self->cache_dir,
    request_timeout => $self->request_timeout,
    run             => $run,
  );

  my $engine;
  if ($plan->{mode} eq 'stdio') {
    $engine = MCP::Hub::Upstream::Docker::Stdio->new(
      %common,
      idle_timeout => 0,    # the upstream keeps the idle timer, not its engine
      config       => {type => 'stdio', %{$self->_stdio_spec($run)}},
      teardown     => $self->_stdio_teardown($run),
    );
  }
  else {
    my $c = $self->config;
    $engine = MCP::Hub::Upstream::Docker::Http->new(
      %common,
      config   => {type => $c->{transport} // 'http', url => undef, headers => $c->{headers} // {}},
      teardown => $self->_http_teardown,
    );
  }

  $engine->{owner} = $self;
  weaken $engine->{owner};
  $self->_track($engine);
  return $engine;
}

# `docker run -i --rm ...`, spawned as an ordinary stdio child.
sub _stdio_spec ($self, $run) {
  my $c      = $self->config;
  my $docker = $self->docker;
  return {
    command => $docker->command,
    args    => [$docker->run_args($self->name, $c, owner => $self->owner_id, run => $run)],
    env     => $c->{env} // {},
  };
}

# After a stdio container's CLI is gone: remove the container, in case the CLI
# was killed before it could. Only this run's container -- by its labels.
sub _stdio_teardown ($self, $run) {
  my ($docker, $name, $owner) = ($self->docker, $self->name, $self->owner_id);
  return sub ($engine) {
    return $docker->remove_orphans_p($name, $owner, run => $run, timeout => CLI_TIMEOUT);
  };
}

# `docker run -d` with the port published on the loopback -- or, with
# hub.docker_network, on that network, addressed by the container's name --
# then ask Docker where it put the port, and wait until the server answers.
sub _launch_http_p ($self, $engine, $plan) {
  my $c       = $self->config;
  my $docker  = $self->docker;
  my $name    = $self->name;
  my $network = $c->{docker_network};
  my @publish = defined $network ? ('--network', $network) : ('-p', "127.0.0.1::$plan->{port}");
  my @args    = $docker->run_args($name, $c,
    owner => $self->owner_id, run => $engine->run, detach => 1, publish => \@publish);

  return $docker->run_p(\@args, env => $c->{env} // {}, timeout => CLI_TIMEOUT)->then(sub ($res) {
    die 'cannot start the container: ' . $docker->explain($docker->stderr_tail($res)) . "\n"
      if $res->{code} // 1;
    my ($id) = reverse grep {/\S/} split /\r?\n/, $res->{out};
    $engine->{container} = defined $id ? $id =~ s/^\s+|\s+$//gr : $docker->container_name($name);
    $self->_watch($engine);

    return $self->_container_url($plan) if defined $network;
    return $docker->run_p(['port', $engine->{container}, "$plan->{port}/tcp"], timeout => CLI_TIMEOUT)
      ->then(sub ($port) {
        my $addr = $port->{code} ? undef : $docker->host_address($port->{out});
        die "cannot find where Docker published port $plan->{port}: " . $docker->stderr_tail($port) . "\n"
          unless defined $addr;
        return "http://$addr" . ($c->{path} // '/mcp');
      });
  })->then(sub ($url) {
    $engine->url($url);
    return $self->_ready_p($engine, $plan);
  });
}

# On hub.docker_network the container is reached by its name, on its own port.
sub _container_url ($self, $plan) {
  return 'http://' . $self->docker->container_name($self->name) . ":$plan->{port}" . ($self->config->{path} // '/mcp');
}

# An HTTP container is stopped and removed by its id: the hub created it, so it
# is the hub's to remove. Without an id -- a `docker run -d` that timed out, or
# that created the container and then failed to start it -- whatever this run
# created is removed by its labels; a container the daemon creates only after
# that is the next start's leftover.
sub _http_teardown ($self) {
  my ($docker, $name, $owner) = ($self->docker, $self->name, $self->owner_id);
  return sub ($engine) {
    my $id = $engine->{container}
      or return $docker->remove_orphans_p($name, $owner, run => $engine->run, timeout => CLI_TIMEOUT);
    return $docker->run_p(['stop', '-t', 5, $id], timeout => CLI_TIMEOUT)->then(sub ($res) {
      return $docker->run_p(['rm', '-f', $id], timeout => CLI_TIMEOUT);
    })->then(sub ($res) {
      $docker->log->debug("[$name] rm -f $id: " . $docker->stderr_tail($res)) if $res->{code};
      return 1;
    });
  };
}

# --- watching and waiting --------------------------------------------------

# `docker wait` returns when the container exits. During a start that ends the
# wait for readiness; once it is serving, it is a crash.
#
# The wait can outlive this object by hours, so it holds the upstream weakly --
# and the engine's teardown ends it: a container the hub leaves running (a
# compose service it found running) would otherwise keep one more `docker wait`
# alive for every start.
sub _watch ($self, $engine) {
  my $id = $engine->{container} or return;
  my ($docker, $name) = ($self->docker, $self->name);
  weaken(my $weak = $self);
  weaken(my $watched = $engine);

  $docker->run_p(['wait', $id], on_spawn => sub ($kill) { $watched->{unwatch} = $kill if $watched })->then(sub ($res) {
    return if !$watched || $watched->{torn_down};    # given up on
    return $docker->log->debug("[$name] cannot watch container $id: " . $docker->stderr_tail($res))
      if $res->{code} // 1;
    my ($code) = $res->{out} =~ /(-?\d+)\s*\z/;
    $watched->{exited} = {code => $code};
    return unless $weak && $weak->{engine} && refaddr($weak->{engine}) == refaddr($watched);
    return if $weak->{start_promise};    # the start in progress reports it
    my $why = 'container exited' . (defined $code ? " (code $code)" : '');
    $docker->log->warn("[$name] $why");
    $weak->_engine_down($watched, $why);
  })->catch(sub ($err) { $docker->log->debug("[$name] cannot watch container $id: $err") });
  return;
}

# A published port accepts connections before the server inside listens, so
# an open port proves nothing: ask until something answers HTTP at all -- any
# status will do -- then leave the handshake to the transport. Gives up when
# the container exits, or after request_timeout.
sub _ready_p ($self, $engine, $plan) {
  my $timeout  = $self->request_timeout || 60;
  my $deadline = time + $timeout;
  my $url      = $engine->url;
  my $ua       = Mojo::UserAgent->new(connect_timeout => 2, inactivity_timeout => 2, request_timeout => 2);
  my $done     = Mojo::Promise->new;
  my $headers  = {Accept => 'application/json, text/event-stream'};

  my $try;
  $try = sub {
    if ($self->{stop_requested}) {
      undef $try;
      return $done->reject("stopped\n");
    }

    if (my $exit = $engine->{exited}) {
      undef $try;
      my $why = 'the container exited' . (defined $exit->{code} ? " (code $exit->{code})" : '') . ' while starting';
      return $self->_logs_p($engine)->then(sub ($tail) {
        $done->reject($why . (length $tail ? ": $tail" : '') . $self->_stdio_hint($plan) . "\n");
        return;
      });
    }

    if (time >= $deadline) {
      undef $try;
      return $done->reject("no MCP answer from $url within ${timeout}s" . $self->_stdio_hint($plan) . "\n");
    }

    $ua->post_p($url => $headers => json => {})->then(
      sub ($tx) {
        return Mojo::IOLoop->timer(RETRY_INTERVAL, $try) unless defined $tx->res->code;
        undef $try;
        $done->resolve;
      },
      sub ($err) { Mojo::IOLoop->timer(RETRY_INTERVAL, $try) if $try },
    );
  };
  $try->();

  return $done;
}

# A port the hub found itself, rather than one it was told, may just be wrong:
# an image can EXPOSE a port and still speak stdio.
sub _stdio_hint ($self, $plan) {
  my %from = (expose => "the image's EXPOSE", published => "the service's ports:");
  my $from = $from{$plan->{from} // ''} or return '';
  return " -- the port comes from $from; if this server speaks stdio, set \"stdio\": true";
}

sub _logs_p ($self, $engine) {
  my $id = $engine->{container} or return Mojo::Promise->resolve('');
  my $docker = $self->docker;
  return $docker->run_p(['logs', '--tail', MCP::Hub::Docker->TAIL_LINES, $id], timeout => CLI_TIMEOUT)
    ->then(sub ($res) { return $res->{code} ? '' : $docker->tail(join "\n", $res->{out}, $res->{err}) })
    ->catch(sub { return '' });
}

# --- engines and their cleanup ---------------------------------------------

# Called by the engine that carries this upstream's requests when its
# connection or its process went away on its own -- a crash, not a stop.
sub _engine_down ($self, $engine, $why) {
  return unless $self->{engine} && refaddr($self->{engine}) == refaddr($engine);
  return if $self->{start_promise};    # the start that runs it reports it
  $self->_record_failure($why);
  $self->_drop_engine;
  $self->_clear_idle_timer;
  $self->state($self->{failed} ? 'failed' : 'stopped');
  return $self;
}

sub _drop_engine ($self) {
  my $engine = delete $self->{engine} or return $self;
  $engine->retire;
  return $self;
}

sub _key ($self) { return join "\0", $self->cache_dir, $self->name }

sub _track ($self, $engine) {
  my ($key, $id) = ($self->_key, refaddr $engine);
  $SETTLING{$key}{$id} = $engine->down_p;
  $engine->down_p->then(sub {
    delete $SETTLING{$key}{$id};
    delete $SETTLING{$key} unless %{$SETTLING{$key}};
  });
  return $self;
}

sub _settled_p ($self) {
  my @down = values %{$SETTLING{$self->_key} // {}};
  return Mojo::Promise->resolve unless @down;
  return Mojo::Promise->race(Mojo::Promise->all_settled(@down), Mojo::Promise->timer(SETTLE_WAIT));
}

sub _check_stop ($self) {
  die "stopped\n" if $self->{stop_requested};
  return $self;
}

# --- failures --------------------------------------------------------------

sub _record_failure ($self, $why) {
  my $now    = time;
  my $window = $self->fail_window;
  push @{$self->{failures}}, $now;
  @{$self->{failures}} = grep { $_ >= $now - $window } @{$self->{failures}};
  return $self unless @{$self->{failures}} >= FAIL_THRESHOLD;
  $self->{failed} = 1;
  $self->error(scalar(@{$self->{failures}}) . " failed starts or crashes within ${window}s, the last: $why");
  return $self;
}

sub _clear_failure ($self) {
  delete $self->{failed};
  @{$self->{failures}} = ();
  $self->error(undef);
  $self->state('stopped');
  return $self;
}

# One error, without the "upstream NAME: " the engines already put in front --
# the upstream adds it once, to everything.
sub _bare_error ($self, $err) {
  my $name = $self->name;
  ($err = "$err") =~ s/\n\z//;
  $err =~ s/^upstream \Q$name\E: //;
  return $err;
}

# A stdio container that died while starting said why on its stderr.
sub _with_output ($self, $engine, $err) {
  return $err unless $engine->can('stderr_tail');
  my $tail = $engine->stderr_tail;
  return length $tail ? $self->docker->explain("$err: $tail") : $err;
}

# --- idle timer ------------------------------------------------------------

sub _arm_idle_timer ($self) {
  return if $self->always_on;
  my $timeout = $self->idle_timeout;
  return unless $timeout > 0;
  $self->_clear_idle_timer;
  $self->{idle_timer} = Mojo::IOLoop->timer($timeout => sub {
    $self->log->info("[@{[$self->name]}] idle for ${timeout}s, stopping");
    $self->stop;
  });
  return $self;
}

sub _clear_idle_timer ($self) {
  Mojo::IOLoop->remove($self->{idle_timer}) if $self->{idle_timer};
  delete $self->{idle_timer};
  return $self;
}

1;

=encoding utf8

=head1 SYNOPSIS

  "mcpServers": {
    "fetch": { "docker": "mcp/fetch" },
    "github": {
      "docker": "ghcr.io/github/github-mcp-server",
      "args":   ["stdio"],
      "env":    { "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}" }
    },
    "crawl4ai": { "docker": "unclecode/crawl4ai", "port": 11235, "path": "/mcp/sse", "type": "sse" }
  }

=head1 DESCRIPTION

L<MCP::Hub::Upstream::Docker> mounts an MCP server that ships as a Docker image.
The image name is enough: on the first call the hub pulls the image if it is
missing, starts a container and talks to it; after C<idle_timeout> without a
call it stops the container again. Like a stdio upstream it is lazy -- a cached
manifest answers C<tools/list> with no container running -- and like one it is
marked C<failed> after three failed starts or crashes within C<fail_window>
seconds, until a C<refresh>.

=head2 stdio or HTTP

Decided on every start, after the image is present:

=over 4

=item * C<"port": N> -- HTTP on container port C<N>.

=item * no C<port>, and the image C<EXPOSE>s exactly one TCP port -- HTTP on that
port.

=item * no C<port> and no C<EXPOSE> -- stdio: C<docker run -i --rm ...> is spawned
as an ordinary stdio child (see L<MCP::Hub::Upstream::Docker::Stdio>).

=item * C<"stdio": true> -- stdio, whatever the image declares.

=back

An image that exposes several ports without a C<port> is a start error naming
them. An HTTP container runs detached (C<docker run -d>) with its port published
on C<127.0.0.1> at a port Docker picks -- or, with C<hub.docker_network>, on that
network, reached by the container's name -- and is spoken to like a C<url>
upstream (see L<MCP::Hub::Upstream::Docker::Http>) once something answers HTTP
on it. A container that exits while starting fails the start with the last
lines of its output.

=head2 Containers

The container is named C<< mcp-hub-<name> >> and labelled with the server, the
owner id of this hub (see L<MCP::Hub::Docker/owner_id>) and the start it belongs
to. A hub that cannot keep an owner id in its cache directory starts no
container at all. Before a start the hub removes its own leftovers for that
server -- an orphan of a crash -- and nothing else: a container of that name it
did not start makes the start fail with Docker's "already in use". C<env> values
reach the container as bare C<-e KEY>, through the environment of the C<docker>
process, never on a command line.

A stop closes a stdio container's stdin and stops its CLI, then removes the
container in case the CLI was killed first; an HTTP container is stopped
(C<docker stop -t 5>) and removed -- by its labels, when C<docker run -d> never
said its id. L</stopped_p> resolves once that is done -- the daemon waits for it
on shutdown. A stop that arrives while the container starts, even during the
MCP handshake, ends the start and removes the container.

=head1 ATTRIBUTES

L<MCP::Hub::Upstream::Docker> inherits all attributes from
L<MCP::Hub::Upstream> and implements the following new ones.

=attr cache_dir

Where the manifest and the owner id are kept. Defaults to the hub's cache
directory.

=attr docker

The L<MCP::Hub::Docker> that runs the CLI, for C<hub.docker_command>.

=attr fail_window

The crash-loop window in seconds. Defaults to C<5>.

=attr idle_timeout

Seconds without a call after which the container is stopped; C<0> never stops
it. Defaults to C<300>.

=attr owner_id

This hub's owner id, from L<MCP::Hub::Docker/owner_id>.

=head1 METHODS

L<MCP::Hub::Upstream::Docker> inherits all methods from L<MCP::Hub::Upstream>
and implements the following new ones.

=method mode

  my $mode = $upstream->mode;    # stdio, http or undef

How the current (or last) start talks to the container; C<undef> before the
first start.

=method refresh_p

  $upstream->refresh_p->then(sub { ... });

Fetch the manifest again from the running container, or start it -- leaving the
C<failed> state -- when it is not running.

=method start_p

  $upstream->start_p->then(sub ($upstream) { ... });

Pull if needed, decide stdio or HTTP, start the container and run the MCP
handshake.

=method status_row

Adds C<container> (its name) and C<mode> to the base row. C<pid> and C<rss_kb>
stay C<undef>: they would describe the C<docker> CLI, not the server.

=method stop

  $upstream->stop;

Stop the container. A start in progress is abandoned.

=method stopped_p

  $upstream->stopped_p->then(sub { ... });

Resolves when every container of this server is gone.

=method touch

Record a call and re-arm the idle timer.

=head1 SEE ALSO

L<MCP::Hub::Docker>, L<MCP::Hub::Upstream::Compose>,
L<MCP::Hub::Upstream::Docker::Stdio>, L<MCP::Hub::Upstream::Docker::Http>.

=cut
