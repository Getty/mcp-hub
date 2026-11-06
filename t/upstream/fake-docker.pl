#!/usr/bin/env perl
# A fake docker CLI for the hub's test suite, selected with hub.docker_command
# (through a small wrapper script, see t/docker.t). It never talks to a Docker
# daemon or the network: its "containers" are t/upstream/echo.pl processes --
# over stdio for `run -i`, over HTTP on the loopback for `run -d` -- and its
# state lives in the directory named by $FAKE_DOCKER_STATE:
#
#   images.json     the local images:   {"IMAGE": {"ports": ["8080/tcp"], "kind": "http"}}
#   registry.json   what `pull` can get, in the same shape
#   containers/     one JSON record per container
#   calls.jsonl     every invocation: argv, working directory, pid, and the
#                   values of the MCPHUB_TEST_* variables it was given
#   down            when present, the "daemon" cannot be reached
#   signals.jsonl   every TERM the attached `run -i` process (the CLI the hub
#                   signals) received: {"signal": "TERM", "pid": N, "time": EPOCH}
#   fail.json       failures to inject: [{"match": REGEX, "code": N, "out": ..., "err": ...}],
#                   the first rule whose regex matches the joined argv answers instead
#
# An image's kind says what its container does: `stdio` runs echo.pl over
# stdio (and, detached, exits at once on its empty stdin; `echo_args` are
# options handed to echo.pl, `--ignore-eof` for a container that stays on after
# its stdin is closed), `http` serves
# echo.pl over HTTP (`delay` seconds late, if set), `crash` complains on stderr
# and exits 3, `idle` just sleeps, `oneshot` exits after `runtime` seconds with
# `exit`, and `nostart` is created but fails to start, as a container whose
# port is taken does. A compose project is the file fake-compose.json in the
# working directory:
# {"name": ..., "services": {"mcp": {"ports": [...], "x-kind": "http"}}}, where a
# service may also have `image` (pulled from registry.json when missing,
# `x-pull-delay` seconds slow), `build` (built as PROJECT-SERVICE when missing),
# `x-exit` and `x-runtime` (for `oneshot`), `healthcheck` (healthy
# `x-healthy-after` seconds after the start, or never with "x-health":
# "unhealthy") and `depends_on`, waited for by condition as compose does.
#
# Compose's recreate policy is the real one: `up` -- and `run` without
# --no-deps, for what the service depends on -- recreates a container whose
# configuration (its service in the file) has changed since it was created,
# even a running one, unless --no-recreate is given; the recreated container
# has a new id.
#
# It is deliberately no more forgiving than it has to be: an unknown compose
# flag is an error; `ps --filter label=K=V` matches on the label's key alone,
# looser than Docker, so that only the hub's own check of the labels keeps it
# off containers that are not its own; `inspect` answers with exactly the
# --format it is given; and an attached `run -i` relays stdin and stdout like
# the real CLI, so a killed CLI leaves its "container" behind.
use strict;
use warnings;

use Cwd         qw(getcwd);
use Digest::MD5 qw(md5_hex);
use Fcntl       qw(:flock);
use FindBin     qw($Bin);
use IO::Select;
use IO::Socket::INET;
use JSON::PP    ();
use POSIX       ();
use Time::HiRes qw(sleep time);

my $JSON  = JSON::PP->new->canonical;
my $STATE = $ENV{FAKE_DOCKER_STATE} or die "fake-docker: FAKE_DOCKER_STATE is not set\n";
my $ECHO  = "$Bin/echo.pl";
my $LIB   = Cwd::abs_path("$Bin/../../lib") // "$Bin/../../lib";
mkdir "$STATE/containers";

_log_call();
_fail(1, 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?')
  if -e "$STATE/down";
_injected_failure();

my $cmd = shift @ARGV // '';
my %DISPATCH = (
  image => \&cmd_image, pull => \&cmd_pull, ps => \&cmd_ps, inspect => \&cmd_inspect, rm => \&cmd_rm,
  run => \&cmd_run, port => \&cmd_port, wait => \&cmd_wait, stop => \&cmd_stop, logs => \&cmd_logs,
  compose => \&cmd_compose,
);
my $handler = $DISPATCH{$cmd} or _fail(1, "fake-docker: unknown command '$cmd'");
exit($handler->(@ARGV) // 0);

# --- images ----------------------------------------------------------------

sub cmd_image {
  my ($sub, @args) = @_;
  _fail(1, "fake-docker: image $sub") unless $sub eq 'inspect';
  my ($format, $image) = _format(@args);
  my $def = _read('images.json')->{$image} or _fail(1, "Error response from daemon: No such image: $image");
  if ($format =~ /ExposedPorts/) {
    my @ports = @{$def->{ports} // []};
    print @ports ? $JSON->encode({map { $_ => {} } @ports}) . "\n" : "null\n";
  }
  else { print "sha256:" . unpack('H*', $image) . "\n" }
  return 0;
}

sub cmd_pull {
  my ($image) = @_;
  my $def = _read('registry.json')->{$image}
    or _fail(1, "Error response from daemon: pull access denied for $image, repository does not exist");
  my $images = _read('images.json');
  $images->{$image} = $def;
  _write('images.json', $images);
  print "Status: Downloaded newer image for $image\n";
  return 0;
}

# --- containers ------------------------------------------------------------

sub cmd_ps {
  my @args = @_;
  my %want;
  while (defined(my $arg = shift @args)) {
    next unless $arg eq '--filter';
    my $filter = shift @args;
    $want{$1} = $2 if $filter =~ /^label=([^=]+)=(.*)$/;
  }
  # The key alone: see the top of this file.
  for my $c (_containers()) {
    next if grep { !exists $c->{labels}{$_} } keys %want;
    print "$c->{id}\n";
  }
  return 0;
}

# With --format, each container is printed through the template -- the few
# fields the hub may ask for, `<no value>` for any other. Without it, a JSON
# array, as Docker prints it.
sub cmd_inspect {
  my ($format, @ids) = _format(@_);
  my ($status, @found) = (0);
  for my $id (@ids) {
    my $c = _container($id) or do { print STDERR "Error: No such object: $id\n"; $status = 1; next };
    push @found, $c;
  }
  if (!length $format) {
    print $JSON->encode([map {
      +{Id => $_->{id}, Name => '/' . ($_->{name} // ''), Config => {Labels => $_->{labels}}, State => {Status => $_->{state}}}
    } @found]) . "\n";
    return $status;
  }
  for my $c (@found) {
    my %field = (
      '.Id'                 => $c->{id},
      '.Name'               => '/' . ($c->{name} // ''),
      '.State.Status'       => $c->{state},
      'json .Config.Labels' => $JSON->encode($c->{labels} // {}),
    );
    (my $line = $format) =~ s{\{\{\s*(.*?)\s*\}\}}{$field{$1} // '<no value>'}ge;
    print "$line\n";
  }
  return $status;
}

sub cmd_rm {
  my @ids    = grep { !/^-/ } @_;
  my $status = 0;
  for my $id (@ids) {
    my $c = _container($id) or do { print STDERR "Error: No such container: $id\n"; $status = 1; next };
    kill 'KILL', $c->{pid} if $c->{pid} && $c->{state} eq 'running';
    _remove($c->{id});
    print "$id\n";
  }
  return $status;
}

sub cmd_run {
  my @args = @_;
  my %c = (labels => {}, env => [], ports => {}, volumes => [], extra => []);
  while (@args && $args[0] =~ /^-/) {
    my $flag = shift @args;
    if    ($flag eq '-i' || $flag eq '--rm' || $flag eq '-d' || $flag eq '-T') { $c{flags}{$flag} = 1 }
    elsif ($flag eq '--name')    { $c{name} = shift @args }
    elsif ($flag eq '--label')   { my ($k, $v) = split /=/, shift(@args), 2; $c{labels}{$k} = $v }
    elsif ($flag eq '-e')        { push @{$c{env}}, shift @args }
    elsif ($flag eq '-p')        { my $spec = shift @args; $c{ports}{"$1/tcp"} = _free_port() if $spec =~ /:(\d+)$/ }
    elsif ($flag eq '--network') { $c{network} = shift @args }
    elsif ($flag eq '-v')        { push @{$c{volumes}}, shift @args }
    else                         { push @{$c{extra}}, $flag }    # docker_args: single tokens only
  }
  my $image = shift @args // _fail(125, 'docker: "run" requires at least 1 argument');
  my $def   = _read('images.json')->{$image} or _fail(125, "Unable to find image '$image' locally");
  return _start(\%c, $def, $image, \@args);
}

sub cmd_port {
  my ($id, $port) = @_;
  my $c = _container($id) or _fail(1, "Error: No such container: $id");
  my $host = $c->{ports}{$port} or _fail(1, "Error: No public port '$port' published for $id");
  print "127.0.0.1:$host\n";
  return 0;
}

sub cmd_wait {
  my ($id) = @_;
  while (1) {
    my $c = _container($id) or _fail(1, "Error response from daemon: No such container: $id");
    if ($c->{state} eq 'exited') { print(($c->{exit_code} // 0) . "\n"); return 0 }
    sleep 0.05;
  }
}

sub cmd_stop {
  my @args = @_;
  my $grace = 10;
  my @ids;
  while (defined(my $arg = shift @args)) {
    if ($arg eq '-t') { $grace = shift @args; next }
    push @ids, $arg;
  }
  _stop_container($_, $grace) for @ids;
  print "$_\n" for @ids;
  return 0;
}

sub cmd_logs {
  my @args = @_;
  my $lines = 1_000_000;
  my $id;
  while (defined(my $arg = shift @args)) {
    if ($arg eq '--tail') { $lines = shift @args; next }
    $id = $arg;
  }
  my $c = _container($id) or _fail(1, "Error: No such container: $id");
  open my $fh, '<', $c->{log} or return 0;
  my @all = <$fh>;
  splice @all, 0, @all - $lines if @all > $lines;
  print STDERR @all;    # a container's stderr comes back on stderr
  return 0;
}

# --- compose ---------------------------------------------------------------

sub cmd_compose {
  my @args = @_;
  my $project;
  while (@args && $args[0] =~ /^-/) {
    my $flag = shift @args;
    $project = shift @args if $flag eq '-p';
  }
  my $file = getcwd() . '/fake-compose.json';
  _fail(14, 'no configuration file provided: not found') unless -f $file;
  my $def = $JSON->decode(do { local (@ARGV, $/) = $file; <> });
  $project //= $def->{name} // (split m{/}, getcwd())[-1];

  my $sub = shift @args // '';
  if ($sub eq 'config') {
    my %services = map {
      my $s = {%{$def->{services}{$_}}};
      delete @{$s}{grep {/^x-/} keys %$s};
      ($_ => $s);
    } keys %{$def->{services}};
    print $JSON->encode({name => $project, services => \%services}) . "\n";
    return 0;
  }

  # The flags the hub and the tests use, and no others: compose refuses a flag
  # it does not know, and so does this.
  my %value = map { $_ => 1 } qw(--name --format);
  my %plain = map { $_ => 1 } qw(-a -d -q -T --rm --no-deps --no-recreate --force-recreate);
  my %opt;
  while (@args && $args[0] =~ /^-/) {
    my $flag = shift @args;
    if    ($flag eq '--status') { push @{$opt{status}}, shift @args }
    elsif ($flag eq '--label')  { my ($k, $v) = split /=/, shift(@args), 2; $opt{labels}{$k} = $v }
    elsif ($value{$flag})       { $opt{$flag} = shift @args }
    elsif ($plain{$flag})       { $opt{$flag} = 1 }
    else                        { _fail(1, "unknown flag: $flag") }
  }
  my @services = $sub =~ /^(?:up|ps|stop)$/ ? @args : (shift @args // ());
  _fail(1, "fake-docker: compose $sub needs a service") unless @services;
  for my $service (@services) { $def->{services}{$service} or _fail(1, "no such service: $service") }
  my $service = $services[0];
  my $sdef    = $def->{services}{$service};

  if ($sub eq 'ps') {
    my $json = ($opt{'--format'} // '') eq 'json' or $opt{'-q'} or _fail(1, 'fake-docker: compose ps needs -q or --format json');
    for my $s (@services) {
      for my $c (_service_containers($project, $s)) {
        next if $opt{status} ? !grep { $_ eq $c->{state} } @{$opt{status}} : !$opt{'-a'} && $c->{state} ne 'running';
        print $json
          ? $JSON->encode({ID => $c->{id}, Service => $s, State => $c->{state}, ExitCode => $c->{exit_code} // 0,
            Health => _health($c, $def->{services}{$s})}) . "\n"
          : "$c->{id}\n";
      }
    }
    return 0;
  }
  if ($sub eq 'up') {
    _fail(1, 'fake-docker: compose up runs detached only') unless $opt{'-d'};
    my $policy = $opt{'--no-recreate'} ? 'never' : $opt{'--force-recreate'} ? 'force' : 'diverged';
    my %done;
    for my $name (@services) {
      my $code = _converge($project, $def, $name, $policy, $opt{'--no-recreate'} ? 'never' : 'diverged',
        \%done, !$opt{'--no-deps'});
      return $code if $code;
    }
    return 0;
  }
  if ($sub eq 'port') {
    my $port = shift @args;
    my ($c)  = grep { $_->{state} eq 'running' } _service_containers($project, $service);
    my $host = $c && $c->{ports}{"$port/tcp"} or _fail(1, "no port $port for service $service");
    print "0.0.0.0:$host\n";
    return 0;
  }
  if ($sub eq 'pull') { return _compose_image($project, $service, $sdef, 'pull') }
  if ($sub eq 'build') { return _compose_image($project, $service, $sdef, 'build') }
  if ($sub eq 'run') {
    # What compose does before it runs the service: the image, if it is
    # missing, then -- without --no-deps -- what the service depends on, with
    # compose's default policy, each waited for as depends_on says.
    my $code = _compose_image($project, $service, $sdef, 'missing');
    return $code if $code;
    unless ($opt{'--no-deps'}) {
      my %done = ($service => 1);
      my %deps = _depends($sdef);
      for my $dep (sort keys %deps) {
        $code = _converge($project, $def, $dep, 'diverged', 'diverged', \%done, 1)
          || _condition($project, $def, $dep, $deps{$dep});
        return $code if $code;
      }
    }
    my %c = (name => $opt{'--name'}, labels => $opt{labels} // {}, ports => {}, flags => {'-i' => 1, '--rm' => 1});
    return _start(\%c, _kind($sdef), $service, []);
  }
  if ($sub eq 'stop') {
    for my $s (@services) {
      _stop_container($_->{id}, 10) for grep { $_->{state} eq 'running' } _service_containers($project, $s);
    }
    return 0;
  }
  _fail(1, "fake-docker: compose $sub");
}

sub _service_containers {
  my ($project, $service) = @_;
  return grep {
    ($_->{labels}{'com.docker.compose.project'} // '') eq $project
      && ($_->{labels}{'com.docker.compose.service'} // '') eq $service
  } _containers();
}

# What compose does to bring one service up: first what it depends on (unless
# --no-deps), each waited for as depends_on says; then the service itself. A
# container that exists is recreated -- stopped, removed, made anew, with a new
# id -- when the policy is `force`, or `diverged` (compose's default) and its
# configuration is no longer the file's; never with --no-recreate. One that
# exists and does not run is started again, as it is.
sub _converge {
  my ($project, $def, $service, $policy, $deps_policy, $done, $with_deps) = @_;
  return 0 if $done->{$service}++;
  my $sdef = $def->{services}{$service} or _fail(1, "no such service: $service");
  if ($with_deps) {
    my %deps = _depends($sdef);
    for my $dep (sort keys %deps) {
      my $code = _converge($project, $def, $dep, $deps_policy, $deps_policy, $done, 1)
        || _condition($project, $def, $dep, $deps{$dep});
      return $code if $code;
    }
  }
  my $code = _compose_image($project, $service, $sdef, 'missing');
  return $code if $code;

  my $hash = md5_hex($JSON->encode($sdef));
  my @mine = _service_containers($project, $service);
  my %stale = map { $_->{id} => 1 }
    $policy eq 'force' ? @mine : $policy eq 'diverged' ? grep { ($_->{config_hash} // '') ne $hash } @mine : ();
  for my $id (sort keys %stale) {
    _stop_container($id, 10);
    _remove($id);
  }
  @mine = grep { !$stale{$_->{id}} } @mine;
  return 0 if grep { $_->{state} eq 'running' } @mine;

  my ($old) = @mine;
  my %c = (
    id          => $old ? $old->{id} : undef,
    name        => "$project-$service-1",
    labels      => {'com.docker.compose.project' => $project, 'com.docker.compose.service' => $service},
    ports       => $old ? $old->{ports} : {map { ("$_->{target}/tcp" => _free_port()) } @{$sdef->{ports} // []}},
    flags       => {'-d' => 1},
    quiet       => 1,    # up prints no container id
    config_hash => $old ? $old->{config_hash} : $hash,
  );
  return _start(\%c, _kind($sdef), $service, []);
}

# depends_on as {service => condition}, from either form.
sub _depends {
  my ($sdef) = @_;
  my $deps = $sdef->{depends_on} // {};
  return map { ($_ => 'service_started') } @$deps if ref $deps eq 'ARRAY';
  return map { ($_ => (ref $deps->{$_} eq 'HASH' && $deps->{$_}{condition}) || 'service_started') } keys %$deps;
}

# Wait as depends_on says: service_healthy until the dependency is healthy,
# service_completed_successfully until it has exited -- with 0, or it fails.
sub _condition {
  my ($project, $def, $dep, $condition) = @_;
  return 0 if $condition eq 'service_started';
  while (1) {
    my @c = _service_containers($project, $dep);
    if ($condition eq 'service_completed_successfully') {
      if (@c && !grep { $_->{state} eq 'running' } @c) {
        my ($bad) = grep { $_->{exit_code} } @c;
        return 0 unless $bad;
        _fail(1, qq{service "$dep" didn't complete successfully: exit $bad->{exit_code}});
      }
    }
    else {
      my @health = map { _health($_, $def->{services}{$dep}) } @c;
      _fail(1, "dependency failed to start: container $project-$dep-1 is unhealthy") if grep { $_ eq 'unhealthy' } @health;
      _fail(1, "dependency failed to start: container $project-$dep-1 has no healthcheck configured")
        if grep { $_ eq '' } @health;
      return 0 if @health && !grep { $_ ne 'healthy' } @health;
    }
    sleep 0.1;
  }
}

# A service with a `healthcheck` is healthy `x-healthy-after` seconds after its
# container started -- or never, with "x-health": "unhealthy".
sub _health {
  my ($c, $sdef) = @_;
  return '' unless $sdef && $sdef->{healthcheck};
  return 'unhealthy' if ($sdef->{'x-health'} // '') eq 'unhealthy';
  return 'starting' unless $c->{state} eq 'running';
  return time - ($c->{started_at} // 0) >= ($sdef->{'x-healthy-after'} // 0) ? 'healthy' : 'starting';
}

# A service's image: pulled (`image`) or built (`build`, as PROJECT-SERVICE),
# always for `pull` and `build`, only when it is missing for `missing`.
sub _compose_image {
  my ($project, $service, $sdef, $when) = @_;
  my $image = $sdef->{image} // "$project-$service";
  return 0 unless defined $sdef->{image} || defined $sdef->{build};
  my $images = _read('images.json');
  return 0 if $when eq 'missing' && $images->{$image};

  if (defined $sdef->{build} && $when ne 'pull') {
    print STDERR "Building $service\n";
    sleep $sdef->{'x-build-delay'} if $sdef->{'x-build-delay'};
    $images->{$image} = {kind => $sdef->{'x-kind'} // 'stdio'};
  }
  else {
    return 0 if defined $sdef->{build} && !defined $sdef->{image};    # nothing to pull
    my $got = _read('registry.json')->{$image} or _fail(18, "pull access denied for $image, repository does not exist");
    print STDERR "Pulling $service ($image)\n";
    sleep $sdef->{'x-pull-delay'} if $sdef->{'x-pull-delay'};
    $images->{$image} = $got;
  }
  _write('images.json', $images);
  return 0;
}

sub _kind {
  my ($sdef) = @_;
  return {kind => $sdef->{'x-kind'} // 'stdio', delay => $sdef->{'x-delay'}, exit => $sdef->{'x-exit'},
    runtime => $sdef->{'x-runtime'}};
}

# --- the "containers" ------------------------------------------------------

sub _start {
  my ($c, $def, $image, $args) = @_;
  my $id = $c->{id} // join '', map { sprintf '%04x', int rand 65536 } 1 .. 16;    # an id given: started again
  if (defined $c->{name} && (my ($taken) = grep { ($_->{name} // '') eq $c->{name} && $_->{id} ne $id } _containers())) {
    _fail(125, qq{docker: Error response from daemon: Conflict. The container name "/$c->{name}" is already in use }
        . qq{by container "$taken->{id}". You have to remove (or rename) that container to be able to reuse that name.});
  }

  my $record = {
    id          => $id,
    name        => $c->{name},
    labels      => $c->{labels},
    image       => $image,
    network     => $c->{network},
    ports       => $c->{ports},
    state       => 'running',
    started_at  => time,
    log         => "$STATE/containers/$id.log",
    args        => $args,
    config_hash => $c->{config_hash},
  };
  my ($host) = values %{$c->{ports}};
  my @server = _server_argv($def, $host);

  if ($c->{flags}{'-d'} && ($def->{kind} // '') eq 'nostart') {
    $record->{state} = 'created';
    _save($record);
    _fail(125, "docker: Error response from daemon: driver failed programming external connectivity on endpoint "
        . ($c->{name} // $id) . ": Bind for 127.0.0.1:" . ($host // 0) . " failed: port is already allocated.");
  }

  if ($c->{flags}{'-d'}) {
    _save($record);
    my $supervisor = fork // _fail(125, "fork: $!");
    if (!$supervisor) {
      POSIX::setsid();
      open STDIN,  '<', '/dev/null';
      open STDOUT, '>>', $record->{log};
      open STDERR, '>&', \*STDOUT;
      my $pid = fork // POSIX::_exit(1);
      if (!$pid) { exec @server or POSIX::_exit(127) }
      _update($id, sub { $_[0]{pid} = $pid });
      waitpid $pid, 0;
      my $code = $? & 127 ? 128 + ($? & 127) : $? >> 8;
      _update($id, sub { $_[0]{state} = 'exited'; $_[0]{exit_code} = $code; delete $_[0]{pid} });
      POSIX::_exit(0);
    }
    # Back only once the server process is known, so that a `stop` or `rm`
    # right after this always finds it.
    for (1 .. 200) { my $r = _container($id) or last; last if $r->{pid} || $r->{state} ne 'running'; sleep 0.01 }
    print "$id\n" unless $c->{quiet};
    return 0;
  }

  # Attached (-i --rm), as the real CLI is: this process stands between the
  # hub and the "container", relays its stdin, stdout and stderr, and passes a
  # TERM on; the record goes away once the server exits. Killed, this process
  # leaves the record behind -- a container whose CLI went away.
  pipe(my $in_r,  my $in_w)  or _fail(125, "pipe: $!");
  pipe(my $out_r, my $out_w) or _fail(125, "pipe: $!");
  pipe(my $err_r, my $err_w) or _fail(125, "pipe: $!");
  my $pid = fork // _fail(125, "fork: $!");
  if (!$pid) {
    POSIX::setsid();
    open STDIN,  '<&', $in_r  or POSIX::_exit(127);
    open STDOUT, '>&', $out_w or POSIX::_exit(127);
    open STDERR, '>&', $err_w or POSIX::_exit(127);
    exec @server or POSIX::_exit(127);
  }
  close $_ for $in_r, $out_w, $err_w;
  $record->{pid} = $pid;
  _save($record);
  local $SIG{TERM} = sub { _log_signal('TERM'); kill 'TERM', $pid };
  local $SIG{PIPE} = 'IGNORE';
  _relay($in_w, $out_r, $err_r);
  waitpid $pid, 0;
  my $code = $? & 127 ? 128 + ($? & 127) : $? >> 8;
  _remove($id) if $c->{flags}{'--rm'};
  return $code;
}

# Our stdin to the server's, the server's stdout and stderr to ours, until the
# server has closed both.
sub _relay {
  my ($in_w, $out_r, $err_r) = @_;
  my %sink = (fileno(STDIN) => $in_w, fileno($out_r) => \*STDOUT, fileno($err_r) => \*STDERR);
  my $select = IO::Select->new(\*STDIN, $out_r, $err_r);
  my $open   = 2;
  while ($open) {
    for my $fh ($select->can_read) {    # none when a TERM interrupts it
      my $n = sysread $fh, my $buf, 65536;
      next if !defined $n && $!{EINTR};
      my $from_stdin = fileno($fh) == fileno(STDIN);
      if (!$n) {
        $select->remove($fh);
        $from_stdin ? close $in_w : $open--;
        next;
      }
      my $sink = $sink{fileno $fh};
      while (length $buf) {
        my $wrote = syswrite $sink, $buf;
        next if !defined $wrote && $!{EINTR};
        last unless $wrote;    # the other side is gone
        substr $buf, 0, $wrote, '';
      }
    }
  }
  return;
}

sub _server_argv {
  my ($def, $host) = @_;
  my $kind = $def->{kind} // 'stdio';
  return ($^X, '-e', 'print STDERR "fatal: MCPHUB_TEST_TOKEN is not set\n"; exit 3') if $kind eq 'crash';
  return ($^X, '-e', '$SIG{TERM} = sub { exit 0 }; sleep 1 while 1') if $kind eq 'idle';
  return ($^X, '-e', sprintf('select undef, undef, undef, %s; exit %d', $def->{runtime} // 0, $def->{exit} // 0))
    if $kind eq 'oneshot';
  return ($^X, "-I$LIB", $ECHO, @{$def->{echo_args} // []}) if $kind eq 'stdio' || !$host;
  return ($^X, "-I$LIB", $ECHO, "--http=$host", ($def->{delay} ? "--http-delay=$def->{delay}" : ()));
}

sub _stop_container {
  my ($id, $grace) = @_;
  my $c = _container($id) or return;
  return unless $c->{state} eq 'running' && $c->{pid};
  kill 'TERM', $c->{pid};
  my $until = time + $grace;
  while (time < $until) {
    my $now = _container($id) or return;
    return if $now->{state} ne 'running';
    sleep 0.05;
  }
  kill 'KILL', $c->{pid};
  return;
}

sub _free_port {
  my $socket = IO::Socket::INET->new(Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1)
    or _fail(125, "no free port: $!");
  return $socket->sockport;
}

# --- state -----------------------------------------------------------------

sub _containers {
  opendir my $dh, "$STATE/containers" or return;
  return grep {defined} map { _read("containers/$_") } sort grep {/\.json$/} readdir $dh;
}

sub _container {
  my ($id) = @_;
  return undef unless defined $id;
  my ($c) = grep { $_->{id} eq $id || $_->{id} =~ /^\Q$id\E/ || ($_->{name} // '') eq $id } _containers();
  return $c;
}

sub _save { my ($c) = @_; _write("containers/$c->{id}.json", $c) }

# A container's record changes under a lock, so that a supervisor noting its
# server's exit can never bring back a record that `rm` just removed.
sub _update {
  my ($id, $change) = @_;
  _locked(sub {
    my $c = _read("containers/$id.json") or return;    # removed meanwhile
    $change->($c);
    _save($c);
  });
}

sub _remove {
  my ($id) = @_;
  _locked(sub { unlink "$STATE/containers/$id.json", "$STATE/containers/$id.log" });
}

sub _locked {
  my ($code) = @_;
  open my $lock, '>>', "$STATE/lock" or die "fake-docker: $STATE/lock: $!\n";
  flock $lock, LOCK_EX;
  $code->();
  close $lock;
}

sub _read {
  my ($file) = @_;
  open my $fh, '<', "$STATE/$file" or return $file =~ m{^containers/} ? undef : {};
  local $/;
  my $data = eval { $JSON->decode(<$fh>) };
  return $data // ($file =~ m{^containers/} ? undef : {});
}

sub _write {
  my ($file, $data) = @_;
  my $tmp = "$STATE/$file.$$.tmp";
  open my $fh, '>', $tmp or die "fake-docker: $tmp: $!\n";
  print $fh $JSON->encode($data);
  close $fh;
  rename $tmp, "$STATE/$file";
}

sub _format {
  my @args = @_;
  my $format = '';
  my @rest;
  while (defined(my $arg = shift @args)) {
    if ($arg eq '--format') { $format = shift @args; next }
    push @rest, $arg;
  }
  return ($format, @rest);
}

sub _log_call {
  my %env = map { $_ => $ENV{$_} } grep {/^MCPHUB_TEST_/} keys %ENV;
  open my $fh, '>>', "$STATE/calls.jsonl" or return;
  print $fh $JSON->encode({argv => [@ARGV], cwd => getcwd(), pid => $$, env => \%env}) . "\n";
  close $fh;
}

# A signal this process was sent, for the tests of a stop: what the hub did to
# the docker CLI, and when.
sub _log_signal {
  my ($signal) = @_;
  open my $fh, '>>', "$STATE/signals.jsonl" or return;
  print $fh $JSON->encode({signal => $signal, pid => $$, time => time}) . "\n";
  close $fh;
  return;
}

sub _injected_failure {
  my $rules = _read('fail.json');
  my $argv  = join ' ', @ARGV;
  for my $rule (ref $rules eq 'ARRAY' ? @$rules : ()) {
    next unless $argv =~ $rule->{match};
    print STDOUT $rule->{out} // '';
    print STDERR $rule->{err} // '';
    exit($rule->{code} // 1);
  }
  return;
}

sub _fail {
  my ($code, $message) = @_;
  print STDERR "$message\n";
  exit $code;
}
