package MCP::Hub::Upstream::Compose;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Hub::Upstream::Docker', -signatures;

use MCP::Hub::Upstream::Http;
use Mojo::JSON qw(decode_json);
use Mojo::Promise;
use Mojo::Util qw(steady_time);

# ABSTRACT: One service of a Docker Compose project as an MCP server

use constant CLI_TIMEOUT => MCP::Hub::Upstream::Docker::CLI_TIMEOUT;

# A start that waits on what its service depends on has no bound, so it says
# so: at warn once it has waited depends_warn_after seconds, then every
# depends_warn_interval seconds. Attributes, not config, so a test can shorten
# them.
has depends_warn_after    => 30;
has depends_warn_interval => 60;

# A `url` is in the entry from the start, as a url entry's is -- only the engine
# of a start gets it. An https one needs TLS, which a running perl never gains,
# so the entry is refused here, with the reason a url entry gives, instead of a
# start bringing the service up only to wait out request_timeout on an address
# it can never reach. The hub keeps it as a failed upstream that says so.
sub new ($class, %args) {
  my $self = $class->SUPER::new(%args);
  if (my $reason = MCP::Hub::Upstream::Http->_tls_missing($self->config->{url})) { die "$reason\n" }
  return $self;
}

sub status_row ($self) {
  my $row = $self->SUPER::status_row;
  delete $row->{container};
  $row->{compose}     = $self->config->{compose};
  $row->{service}     = $self->config->{service};
  $row->{waiting_for} = $self->{waiting_for} if defined $self->{waiting_for};
  return $row;
}

sub _hash ($self) {
  my $c = $self->config;
  return $self->{manifest}->hash("compose:$c->{compose}",
    [$c->{service}, $c->{url}, $c->{port}, $c->{path}, $c->{transport}, $c->{stdio} ? 1 : 0], undef);
}

# Every compose command runs in the project directory, with the entry's env in
# its environment -- that is what ${VAR} in the compose file sees.
sub _compose_p ($self, $args, %opt) {
  my $c = $self->config;
  return $self->docker->run_p(['compose', @$args],
    cwd => $c->{compose}, env => $c->{env} // {}, timeout => exists $opt{timeout} ? $opt{timeout} : CLI_TIMEOUT);
}

# --- deciding stdio or HTTP ------------------------------------------------

# Read the project the way compose itself reads it -- the hub never parses the
# YAML -- and decide how to talk to the service: an explicit `url`, a `port`
# the service publishes, the one port it publishes, or stdio when it publishes
# none. `"stdio": true` means stdio regardless.
sub _plan_p ($self) {
  my $c       = $self->config;
  my $service = $c->{service};
  my $dir     = $c->{compose};

  return $self->_compose_p(['config', '--format', 'json'])->then(sub ($res) {
    die "docker compose config failed in $dir: " . $self->_why($res) . "\n" if $res->{code} // 1;
    my $project = eval { decode_json($res->{out}) };
    die "docker compose config in $dir did not answer with a project\n"
      unless ref $project eq 'HASH' && ref $project->{services} eq 'HASH';

    my $def = $project->{services}{$service};
    die "service '$service' is not in the compose project in $dir (its services: "
      . (join(', ', sort keys %{$project->{services}}) || 'none') . ")\n"
      unless ref $def eq 'HASH';

    # A stdio service is run with what compose knows of it at hand.
    my %stdio = (mode => 'stdio', def => $def, project => $project->{name}, services => $project->{services});
    return \%stdio if $c->{stdio};
    return {mode => 'http', from => 'url'} if defined $c->{url};

    my @published = _published($def);
    if (defined $c->{port}) {
      die "service '$service' does not publish port $c->{port} -- add it under ports: in the compose file, or give \"url\"\n"
        unless grep { $_ == $c->{port} } @published;
      return {mode => 'http', port => $c->{port}, from => 'port'};
    }
    return {mode => 'http', port => $published[0], from => 'published'} if @published == 1;
    die "service '$service' publishes ports " . join(', ', @published)
      . ' -- set "port" to the one the MCP server listens on' . "\n"
      if @published > 1;

    $self->_check_stdio("service '$service' publishes no port");
    return \%stdio;
  });
}

# The container ports a service publishes, from the normalized config: there
# every `ports:` entry is the long form, with the container port as `target`.
sub _published ($def) {
  my %ports;
  for my $p (@{ref $def->{ports} eq 'ARRAY' ? $def->{ports} : []}) {
    next unless ref $p eq 'HASH' && defined $p->{target} && $p->{target} =~ /^\d+$/;
    next if lc($p->{protocol} // 'tcp') ne 'tcp';
    $ports{$p->{target}} = 1;
  }
  return sort { $a <=> $b } keys %ports;
}

# --- the service, by mode --------------------------------------------------

# What `docker compose run` would otherwise do inside the handshake's
# request_timeout -- pull or build a missing image, start what the service
# depends on and wait for it -- done first and without a timeout, as a docker
# entry's pull is; `run` itself then gets --no-deps.
#
# `up -d --no-recreate`: a dependency that does not run is started, one that
# exists is never recreated -- compose's default would recreate a running one
# whose configuration differs from what this hub's environment makes of the
# file, the user's database say. The dependencies are left running afterwards,
# as `compose run` leaves them.
sub _prepare_p ($self, $plan) {
  return Mojo::Promise->resolve unless $plan->{mode} eq 'stdio';
  my ($docker, $service) = ($self->docker, $self->config->{service});
  my $def   = $plan->{def} // {};
  my $build = defined $def->{build};
  my $image = $def->{image} // ($build ? "$plan->{project}-$service" : undef);    # compose's name for it
  my %deps  = _depends_on($def, $plan->{services});
  my @deps  = sort keys %deps;

  my $have = defined $image ? $docker->image_exists_p($image, timeout => CLI_TIMEOUT) : Mojo::Promise->resolve(1);
  return $have->then(sub ($exists) {
    return if $exists;
    my $how = $build ? 'build' : 'pull';
    $self->log->info("[@{[$self->name]}] docker compose $how $service");
    return $self->_compose_p([$how, $service], timeout => undef)->then(sub ($res) {
      die "docker compose $how $service failed: " . $self->_why($res) . "\n" if $res->{code} // 1;
    });
  })->then(sub {
    $self->_check_stop;
    return unless @deps;
    return $self->_compose_p(['up', '-d', '--no-recreate', @deps], timeout => undef)->then(sub ($res) {
      die "docker compose up @deps (what $service depends on) failed: " . $self->_why($res) . "\n"
        if $res->{code} // 1;
    });
  })->then(sub {
    $self->_check_stop;
    my %wait = map { $_ => $deps{$_} } grep { $deps{$_} ne 'service_started' } @deps;
    return %wait ? $self->_conditions_p(\%wait) : undef;
  });
}

# What the service depends on, with the condition it waits for: every
# required dependency, and an optional one that is in the project.
sub _depends_on ($def, $services) {
  my $deps = $def->{depends_on};
  return map { ($_ => 'service_started') } @$deps if ref $deps eq 'ARRAY';
  return () unless ref $deps eq 'HASH';
  my %cond;
  for my $dep (keys %$deps) {
    my $d = ref $deps->{$dep} eq 'HASH' ? $deps->{$dep} : {};
    next unless ($d->{required} // 1) || (ref $services eq 'HASH' && $services->{$dep});
    $cond{$dep} = $d->{condition} // 'service_started';
  }
  return %cond;
}

# Wait as depends_on says, as `compose run` would: a service_healthy
# dependency until its container is healthy, a service_completed_successfully
# one until it has exited -- with 0, or the start fails. `compose ps -a` is
# asked every half second, so a stop is heeded at once; there is no timeout,
# as compose has none. (`compose wait` cannot tell: it knows only containers
# that still run.) What it still waits for is in the status row from the first
# answer on, and in the log once the wait is long (depends_warn_after).
sub _conditions_p ($self, $wait) {
  my $service = $self->config->{service};
  my %left    = %$wait;
  my $done    = Mojo::Promise->new;
  my $since   = steady_time;
  my $warn_at = $since + $self->depends_warn_after;
  my $round;
  $round = sub {
    Mojo::Promise->resolve->then(sub {
      $self->_check_stop;
      return $self->_compose_p(['ps', '-a', '--format', 'json', sort keys %left]);
    })->then(sub ($res) {
      die "docker compose ps failed: " . $self->_why($res) . "\n" if $res->{code} // 1;
      $self->_check_stop;    # no word of waiting from a start that is called off
      my %found;
      push @{$found{$_->{Service} // ''}}, $_ for _ps_json($res->{out});
      for my $dep (sort keys %left) {
        my @c = @{$found{$dep} // []} or next;
        delete $left{$dep} if _condition_met($service, $dep, $left{$dep}, @c);
      }
      unless (%left) {
        $done->resolve;
        return;
      }

      $self->{waiting_for} = _waiting_for(\%left, \%found);
      if ((my $now = steady_time) >= $warn_at) {
        $warn_at = $now + $self->depends_warn_interval;
        $self->log->warn("[@{[$self->name]}] still waiting after @{[int($now - $since)]}s"
            . " for what $service depends on: $self->{waiting_for}");
      }
      Mojo::IOLoop->timer(0.5 => $round);
      return;
    })->catch(sub ($err) {
      $done->reject($err);
      return;    # not $done, which this chain would then follow into an unhandled rejection
    });
  };
  $round->();
  return $done->finally(sub {
    undef $round;
    delete $self->{waiting_for};
  });
}

# What a start still waits for, each dependency with the state -- and health --
# compose last gave for its containers: "db to be healthy (running, health
# starting), migrate to complete (running)".
sub _waiting_for ($left, $found) {
  return join ', ', map {
    my $dep   = $_;
    my $need  = $left->{$dep} eq 'service_completed_successfully' ? 'to complete' : 'to be healthy';
    my @state = map {
      lc($_->{State} // 'unknown') . (length($_->{Health} // '') ? ', health ' . lc $_->{Health} : '')
    } @{$found->{$dep} // []};
    "$dep $need (" . (join('; ', @state) || 'no container') . ')';
  } sort keys %$left;
}

# Whether the containers of one dependency meet its condition yet; dies when
# they never will.
sub _condition_met ($service, $dep, $condition, @c) {
  my @gone = grep { lc($_->{State} // '') =~ /^(?:exited|dead)$/ } @c;
  if ($condition eq 'service_completed_successfully') {
    my ($failed) = grep { $_->{ExitCode} } @gone;
    die "$dep, which $service needs to complete, exited with code $failed->{ExitCode}\n" if $failed;
    return @gone == @c;
  }
  die "$dep, which $service needs to be healthy, has exited\n" if @gone;
  my @health = map { lc($_->{Health} // '') } @c;
  die "$dep, which $service needs to be healthy, is unhealthy\n" if grep { $_ eq 'unhealthy' } @health;
  die "$dep has no healthcheck, but $service needs it to be healthy\n" if grep { $_ eq '' } @health;
  return !grep { $_ ne 'healthy' } @health;
}

# `compose ps --format json`: one object per line -- or, before Compose 2.21,
# one array of them.
sub _ps_json ($text) {
  $text //= '';
  if ($text =~ /^\s*\[/) {
    my $all = eval { decode_json($text) };
    return ref $all eq 'ARRAY' ? grep { ref eq 'HASH' } @$all : ();
  }
  return grep { ref eq 'HASH' } map { scalar eval { decode_json($_) } } grep {/\S/} split /\r?\n/, $text;
}

# `docker compose run --rm -T --no-deps SERVICE` as the stdio child, named and
# labelled like a docker entry's container, so the orphan cleanup finds it.
# Its dependencies are _prepare_p's: left to `run`, they would be recreated
# with compose's default policy.
sub _stdio_spec ($self, $run) {
  my $c      = $self->config;
  my $docker = $self->docker;
  return {
    command => $docker->command,
    args    => [
      'compose', 'run', '--rm', '-T', '--no-deps',
      '--name', $docker->container_name($self->name),
      $docker->labels($self->name, $self->owner_id, $run),
      $c->{service},
    ],
    env => $c->{env} // {},
    cwd => $c->{compose},
  };
}

# `docker compose up -d --no-recreate SERVICE` -- that service, with what it
# depends on, each waited for as depends_on says -- then the address: the
# `url` given, or where compose published the port. --no-recreate: compose
# starts what does not run and never recreates a container that exists; by
# default it would recreate a running dependency whose configuration differs
# from what this hub's environment makes of the file.
#
# A service that already runs was started by someone else: the hub uses it as
# it is -- no `up`, which could recreate it -- and never stops it. When compose
# cannot say whether it runs, the hub does not start it either: it only ever
# stops a service it saw not running and started itself. (What starts it in
# the moment between that look and the `up` is beyond telling.)
sub _launch_http_p ($self, $engine, $plan) {
  my $c       = $self->config;
  my $docker  = $self->docker;
  my $service = $c->{service};
  my $dir     = $c->{compose};
  my @status  = map { ('--status', $_) } qw(running restarting paused);

  return $self->_compose_p(['ps', @status, '-q', $service])->then(sub ($ps) {
    die "cannot tell whether service $service already runs in $dir -- docker compose ps: "
      . $self->_why($ps)
      . "; the hub starts, and later stops, only a service it saw not running\n"
      if $ps->{code} // 1;

    if (my ($id) = _ids($ps->{out})) {
      $engine->{adopted}   = 1;
      $engine->{container} = $id;
      $self->log->info("[@{[$self->name]}] service $service already runs in $dir; using it, never stopping it");
      return;
    }

    $engine->{up} = 1;
    return $self->_compose_p(['up', '-d', '--no-recreate', $service], timeout => undef)->then(sub ($up) {    # may pull or build
      die "docker compose up $service failed: " . $self->_why($up) . "\n" if $up->{code} // 1;
      return $self->_compose_p(['ps', '-q', $service]);
    })->then(sub ($ps) {
      ($engine->{container}) = $ps->{code} ? () : _ids($ps->{out});
      return;
    });
  })->then(sub {
    $self->_watch($engine);
    return $c->{url} if defined $c->{url};
    return $self->_compose_p(['port', $service, $plan->{port}])->then(sub ($port) {
      my $addr = $port->{code} ? undef : $docker->host_address($port->{out});
      die "cannot find where compose published port $plan->{port} of $service: " . $docker->stderr_tail($port) . "\n"
        unless defined $addr;
      return "http://$addr" . ($c->{path} // '/mcp');
    });
  })->then(sub ($url) {
    $engine->url($url);
    return $self->_ready_p($engine, $plan);
  });
}

sub _ids ($text) { return map { s/^\s+|\s+$//gr } grep {/\S/} split /\r?\n/, $text // '' }

# What a failed compose command said, explained -- and, when it did not know a
# flag or command the hub uses, which compose the hub needs.
sub _why ($self, $res) {
  my $docker = $self->docker;
  my $why    = $docker->explain($docker->stderr_tail($res));
  return $why unless $why =~ /unknown (?:shorthand )?flag|unrecognized arguments?|unknown command/i;
  return "$why -- the hub needs Docker Compose 2 or later (docker compose version); podman-compose is not supported";
}

# `docker compose stop SERVICE` -- only the service, never what it depends on
# or the rest of the stack, and never a service the hub found running.
sub _http_teardown ($self) {
  my ($docker, $c, $name) = ($self->docker, $self->config, $self->name);
  my %run = (cwd => $c->{compose}, env => $c->{env} // {}, timeout => CLI_TIMEOUT);
  return sub ($engine) {
    return Mojo::Promise->resolve if !$engine->{up} || $engine->{adopted};
    return $docker->run_p(['compose', 'stop', $c->{service}], %run)->then(sub ($res) {
      $docker->log->warn("[$name] docker compose stop $c->{service}: " . $docker->stderr_tail($res)) if $res->{code};
      return 1;
    });
  };
}

1;

=encoding utf8

=head1 SYNOPSIS

  "mcpServers": {
    "stack": { "compose": "~/mcp/stack", "service": "mcp" }
  }

=head1 DESCRIPTION

L<MCP::Hub::Upstream::Compose> mounts one service of a Docker Compose project as
an MCP server. C<compose> names the directory that holds the compose file,
C<service> the one service that is the MCP server. The hub starts the service,
plus any dependencies that are not running yet; it stops only that service; it
never stops, recreates or restarts anything that already exists.

It is an L<MCP::Hub::Upstream::Docker> in everything but the commands: lazy
start, idle stop, the crash loop and the readiness wait are the same. The
project is read with C<docker compose config --format json> in the directory
(the hub never parses YAML itself), and how the hub talks to the service is
decided on every start, in this order:

=over 4

=item * C<url> given -- HTTP to exactly that URL. An C<https> one needs TLS in the
perl the hub runs on, as a C<url> entry's does (L<MCP::Hub::Upstream::Http>):
without it the entry is refused when it is built, and the hub keeps it as a
C<failed> upstream with the same reason, before any compose command runs.

=item * C<"stdio": true> -- stdio.

=item * C<port> given -- HTTP; the host address comes from
C<docker compose port SERVICE PORT>. A port the service does not publish is an
error.

=item * the service publishes exactly one port -- HTTP on it; several are an error
naming them.

=item * no published port -- stdio: C<docker compose run --rm -T --no-deps
SERVICE> is spawned as an ordinary stdio child, named and labelled like a C<docker> entry's
container.

=back

For HTTP, the hub first asks C<docker compose ps> whether the service runs
already. If it does, the hub uses it as it is -- no C<up> -- and leaves it
running; if C<ps> fails, so does the start, and nothing is started or stopped.
Otherwise C<docker compose up -d --no-recreate SERVICE> starts it, with what it
declares in C<depends_on> that does not run, and C<docker compose stop SERVICE>
stops it again. C<--no-recreate> is what keeps compose from recreating a
running dependency whose configuration has diverged (its default). For stdio,
the hub does first what C<run> would otherwise do inside the handshake: it pulls
or builds a missing image, runs C<docker compose up -d --no-recreate> for the
services in C<depends_on>, and polls C<docker compose ps> until each
C<service_healthy> one is healthy and each C<service_completed_successfully> one
has exited 0 -- without a timeout, so that the handshake's C<request_timeout>
covers only the server. While it waits, it says what for: the status row
carries it as C<waiting_for> (see L</status_row>), and once the wait has lasted
L</depends_warn_after> seconds the log says it at C<warn>, again every
L</depends_warn_interval> seconds, naming each dependency it still waits for
with the state and health compose gives for its containers:

  [stack] still waiting after 30s for what mcp depends on: db to be healthy (running, health starting)

C<run --no-deps> then starts the server alone; its container goes away with
the stdio stop. A stop during these waits ends them.
Dependencies are never stopped. Every compose command runs in the project
directory with the entry's C<env> in its environment, so C<${VAR}> in the
compose file sees it. Docker Compose 2 or later is needed; podman-compose lacks
C<config --format json> and is not supported, and a compose that rejects one of
the flags fails the start with a message that says so.

=head1 ATTRIBUTES

L<MCP::Hub::Upstream::Compose> inherits all attributes from
L<MCP::Hub::Upstream::Docker> and implements the following new ones.

=attr depends_warn_after

Seconds a start waits on what its service depends on before it says so in the
log, at C<warn>. Defaults to C<30>.

=attr depends_warn_interval

Seconds between the warnings after the first, for as long as the wait lasts.
Defaults to C<60>.

=head1 METHODS

L<MCP::Hub::Upstream::Compose> inherits all methods from
L<MCP::Hub::Upstream::Docker> and implements the following new ones.

=method status_row

Names the C<compose> directory and the C<service> instead of a container. While
a stdio start waits on what the service depends on, C<waiting_for> says what
for, as the log does: each dependency it still waits for, with what it waits
for and the state and health compose last gave for its containers --
C<db to be healthy (running, health starting), migrate to complete (running)>.

=head1 SEE ALSO

L<MCP::Hub::Upstream::Docker>, L<MCP::Hub::Docker>.

=cut
