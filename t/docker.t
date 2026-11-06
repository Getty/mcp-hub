#!/usr/bin/env perl
# Docker and compose upstreams, against t/upstream/fake-docker.pl selected with
# hub.docker_command: no Docker daemon, no image, no network. The fake runs
# t/upstream/echo.pl as its "containers" and records every docker command it
# was given, so the tests can say exactly what the hub asked Docker to do --
# and what it never asked.
use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojolicious;
use Mojo::File qw(curfile tempdir);
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Log;
use Mojo::Promise;
use Mojo::Server::Daemon;
use Scalar::Util qw(weaken);
use MCP::Client;
use MCP::Hub;
use MCP::Hub::Config;
use MCP::Hub::Docker;
use MCP::Hub::Upstream;
use MCP::Server;

my $FAKE = curfile->sibling('upstream', 'fake-docker.pl')->to_abs;
my (@FAKES, @KEEP, @LOG);

my $LOG = Mojo::Log->new(level => 'debug');
$LOG->unsubscribe('message');
$LOG->on(message => sub ($log, $level, @lines) { push @LOG, "$level: @lines" });

# A docker CLI that records the commands it is given and fails each of them.
package Test::StubDocker {
  use Mojo::Base 'MCP::Hub::Docker', -signatures;
  has seen => sub { [] };

  sub run_p ($self, $args, %opt) {
    push @{$self->seen}, [@$args];
    return Mojo::Promise->resolve({code => 1, out => '', err => 'stubbed'});
  }
}

# --- the fake daemon -------------------------------------------------------

# A fake Docker of its own: an image store, a registry to pull from, and a
# `docker` command to put into hub.docker_command.
sub fake_docker (%opt) {
  my $dir   = tempdir;
  my $state = $dir->child('state')->make_path;
  $state->child('images.json')->spew(encode_json($opt{images} // {}));
  $state->child('registry.json')->spew(encode_json($opt{registry} // {}));
  my $cmd = $dir->child('docker');
  $cmd->spew(qq{#!/bin/sh\nFAKE_DOCKER_STATE='$state'\nexport FAKE_DOCKER_STATE\nexec '$^X' '$FAKE' "\$@"\n});
  chmod 0755, "$cmd";
  my $fake = {dir => $dir, state => $state, command => "$cmd"};
  push @FAKES, $fake;
  return $fake;
}

sub calls ($fake) {
  my $file = $fake->{state}->child('calls.jsonl');
  return [] unless -e $file;
  return [map { decode_json($_) } grep {/\S/} split /\n/, $file->slurp];
}

# The calls after the first $n.
sub calls_since ($fake, $n) {
  my @all = @{calls($fake)};
  return [@all[$n .. $#all]];
}

# Every command as one string, for matching.
sub commands ($fake, $calls = calls($fake)) { return [map { join ' ', @{$_->{argv}} } @$calls] }

# From now on the fake answers every command that matches $match with this
# result, instead of running it.
sub fail_with ($fake, $match, %res) {
  my $file  = $fake->{state}->child('fail.json');
  my $rules = -e $file ? decode_json($file->slurp) : [];
  push @$rules, {match => $match, code => 1, %res};
  $file->spew(encode_json($rules));
}

# The containers that exist. A record is written by rename, so it is always
# whole -- but `rm` unlinks it, and the hub removes containers while a test
# lists them. A record gone between the listing and the read is a container
# removed meanwhile: it is not in the snapshot, like one removed a moment
# earlier. $between runs after the listing, before the reads -- a hook for
# exactly that gap.
sub records ($fake, $between = undef) {
  my $dir = $fake->{state}->child('containers');
  return [] unless -d $dir;
  my @files = sort { "$a" cmp "$b" } $dir->list->grep(qr/\.json$/)->each;
  $between->(@files) if $between;
  my @records;
  for my $file (@files) {
    my $fh;
    unless (open $fh, '<', "$file") {
      next if $!{ENOENT};
      die "Can't open file $file: $!";
    }
    local $/;
    push @records, decode_json(scalar <$fh>);
  }
  return \@records;
}

sub running ($fake) { return [grep { $_->{state} eq 'running' } @{records($fake)}] }

sub put_record ($fake, $record) {
  $fake->{state}->child('containers')->make_path->child("$record->{id}.json")->spew(encode_json($record));
}

# Wait until $cond is true, running the event loop meanwhile.
sub wait_until ($cond, $seconds = 15) {
  my $deadline = time + $seconds;
  until ($cond->()) {
    return 0 if time > $deadline;
    Mojo::Promise->timer(0.1)->wait;
  }
  return 1;
}

# Settle a promise, or give up after $seconds: ($ok, $value_or_error).
sub await ($promise, $seconds = 30) {
  my @out = (0, 'timed out');
  Mojo::Promise->race(Mojo::Promise->timeout($seconds => 'test timed out'), $promise)
    ->then(sub (@v) { @out = (1, $v[0]) }, sub (@e) { @out = (0, $e[0] // 'rejected') })->wait;
  return @out;
}

# A docker or compose upstream, built the way the hub builds it: from a config
# block, normalized by MCP::Hub::Config.
sub upstream ($fake, $entry, %opt) {
  my $name  = delete $opt{name} // 'srv';
  my $cache = delete $opt{cache} // tempdir;
  push @KEEP, $cache;
  my $config = MCP::Hub::Config->from_data({
    mcpServers => {$name => $entry},
    hub        => {cache_dir => "$cache", docker_command => $fake->{command}, %{delete $opt{hub} // {}}},
  });
  return MCP::Hub::Upstream->build($config->server($name),
    cache_dir => "$cache", log => $LOG, idle_timeout => 300, request_timeout => 20, %opt);
}

sub text_of ($result) { return ref $result eq 'HASH' ? $result->{content}[0]{text} // '' : '' }

sub echo_ok ($up, $msg = 'hi') {
  my ($ok, $res) = await($up->call_tool('echo', {msg => $msg}));
  return $ok && text_of($res) eq $msg;
}

sub stop_and_settle ($up) {
  $up->stop;
  await($up->stopped_p);
}

# Nothing a test left behind keeps running: every server process the fake
# started is killed, whatever happened to the test.
END {
  for my $fake (@FAKES) {
    for my $r (@{records($fake)}) { kill 'KILL', $r->{pid} if $r->{pid} }
    $fake->{state}->child('containers')->remove_tree if -d $fake->{state}->child('containers');
  }
}

my %IMAGES = (
  't/stdio'        => {kind => 'stdio'},
  't/http'         => {kind => 'http'},
  't/expose1'      => {kind => 'http', ports => ['8080/tcp']},
  't/expose2'      => {kind => 'http', ports => ['8080/tcp', '9090/tcp']},
  't/expose-stdio' => {kind => 'stdio', ports => ['8080/tcp']},
  't/slow'         => {kind => 'http', ports => ['8080/tcp'], delay => 1.5},
  't/silent'       => {kind => 'http', ports => ['8080/tcp'], delay => 60},
  't/crash'        => {kind => 'crash'},
);

# --- docker: stdio ---------------------------------------------------------

subtest 'records() snapshots the containers that exist, whatever is removed while it reads' => sub {
  my $fake = fake_docker();
  put_record($fake, {id => $_, state => 'running'}) for qw(aaa bbb ccc);
  is_deeply [map { $_->{id} } @{records($fake)}], [qw(aaa bbb ccc)], 'control: all three are listed';

  my $snap = records($fake, sub (@files) { $fake->{state}->child('containers', 'bbb.json')->remove });
  is_deeply [map { $_->{id} } @$snap], [qw(aaa ccc)], 'a record removed between listing and reading is not in the snapshot';
  is_deeply [map { $_->{id} } @{records($fake)}], [qw(aaa ccc)], 'and it is gone for the next snapshot as well';
};

subtest 'a stdio container: the docker run, the secret, idle stop' => sub {
  my $fake = fake_docker(images => \%IMAGES);
  my $up   = upstream($fake, {
    docker      => 't/stdio',
    args        => ['--verbose'],
    env         => {MCPHUB_TEST_TOKEN => 'secret-value'},
    volumes     => ['/srv/data:/data:ro'],
    docker_args => ['--read-only'],
  }, idle_timeout => 1);

  is $up->type, 'docker', 'a docker upstream';
  is $up->state, 'stopped', 'stopped before the first call';
  is_deeply calls($fake), [], 'building it ran no docker command';

  my ($ok, $err) = await($up->start_p);
  ok $ok, 'started' or diag $err;
  is $up->state, 'ready', 'ready';
  is $up->mode, 'stdio', 'no port and no EXPOSE: stdio';
  ok echo_ok($up), 'a tool call goes through the container';

  my @calls = @{calls($fake)};
  is_deeply [map { $_->{argv}[0] } @calls], [qw(image ps run)], 'inspect, look for leftovers, run -- no pull';
  is_deeply $calls[0]{argv}, ['image', 'inspect', '--format', '{{json .Config.ExposedPorts}}', 't/stdio'],
    'the image is inspected for its EXPOSE';

  my $owner = $up->owner_id;
  like $owner, qr/^[0-9a-f]{12}$/, 'a random owner id';
  is_deeply $calls[1]{argv},
    ['ps', '-a', '-q', '--filter', "label=mcp-hub.owner=$owner", '--filter', 'label=mcp-hub.server=srv'],
    'leftovers are looked for by this hub\'s labels only';

  my @run = @{$calls[2]{argv}};
  my ($label) = grep {/^mcp-hub\.run=/} @run;
  is_deeply \@run, [
    'run', '-i', '--rm', '--name', 'mcp-hub-srv',
    '--label', 'mcp-hub.server=srv', '--label', "mcp-hub.owner=$owner", '--label', $label,
    '-e', 'MCPHUB_TEST_TOKEN', '-v', '/srv/data:/data:ro', '--read-only', 't/stdio', '--verbose',
  ], 'docker run -i --rm, named and labelled, env by name only';
  ok !(grep {/secret-value/} map { @{$_->{argv}} } @calls), 'the secret is on no command line';
  is $calls[2]{env}{MCPHUB_TEST_TOKEN}, 'secret-value', 'it reaches the docker CLI through its environment';

  my $row = $up->status_row;
  is $row->{type},      'docker',      'status: type docker';
  is $row->{container}, 'mcp-hub-srv', 'status: the container name';
  is $row->{mode},      'stdio',       'status: the mode';
  is $row->{pid},       undef,         'status: no pid of a process on this host';

  is scalar @{running($fake)}, 1, 'one container runs';
  ok wait_until(sub { $up->state eq 'stopped' }, 10), 'stopped after idle_timeout';
  ok wait_until(sub { !@{records($fake)} }), 'and the container is gone';
  ok !(grep { /^(?:stop|rm)\b/ } @{commands($fake)}), 'a stdio container goes with its CLI, no stop or rm needed';
};

subtest 'the image is pulled only when it is missing' => sub {
  my $fake = fake_docker(registry => {'t/pulled' => {kind => 'stdio'}});
  my $up   = upstream($fake, {docker => 't/pulled'});

  my ($ok, $err) = await($up->start_p);
  ok $ok, 'started' or diag $err;
  is_deeply [map { $_->{argv}[0] } @{calls($fake)}], [qw(image pull image ps run)], 'inspect, pull, inspect again';
  stop_and_settle($up);

  ($ok, $err) = await($up->start_p);
  ok $ok, 'started again' or diag $err;
  is scalar(grep {/^pull /} @{commands($fake)}), 1, 'pulled once, not on the second start';
  stop_and_settle($up);
  ok wait_until(sub { !@{records($fake)} }), 'nothing left';

  my $missing = upstream($fake, {docker => 't/nowhere'});
  ($ok, $err) = await($missing->start_p);
  ok !$ok, 'an image that cannot be pulled fails the start';
  like $err, qr/upstream srv: cannot pull t\/nowhere: .*pull access denied/, 'naming the image and why';
  is $missing->state, 'stopped', 'stopped, not failed, after one failure';
  ok !(grep {/^run .*t\/nowhere/} @{commands($fake)}), 'and no container was started';
};

# --- docker: stdio or HTTP -------------------------------------------------

subtest 'a port means HTTP on it, and an HTTP container is stopped and removed' => sub {
  my $fake = fake_docker(images => \%IMAGES);
  my $up   = upstream($fake, {docker => 't/http', port => 8080}, idle_timeout => 1);

  my ($ok, $err) = await($up->start_p);
  ok $ok, 'started' or diag $err;
  is $up->mode, 'http', 'mode http';
  ok echo_ok($up, 'over http'), 'a tool call goes through the container over HTTP';

  my ($run) = grep { $_->{argv}[0] eq 'run' } @{calls($fake)};
  my @run = @{$run->{argv}};
  is_deeply [@run[0 .. 1]], ['run', '-d'], 'run -d';
  ok !(grep { $_ eq '-i' || $_ eq '--rm' } @run), 'neither -i nor --rm';
  is_deeply [@run[-3 .. -1]], ['-p', '127.0.0.1::8080', 't/http'], 'the port published on the loopback only';

  my ($id) = map { $_->{id} } @{running($fake)};
  ok grep({ $_ eq "port $id 8080/tcp" } @{commands($fake)}), 'docker port tells where it went';
  ok grep({ $_ eq "wait $id" } @{commands($fake)}),          'and docker wait watches the container';

  ok wait_until(sub { $up->state eq 'stopped' }, 10), 'stopped after idle_timeout';
  ok wait_until(sub { !@{records($fake)} }), 'and the container is gone';
  my @teardown = grep {/^(?:stop|rm) /} @{commands($fake)};
  is_deeply \@teardown, ["stop -t 5 $id", "rm -f $id"], 'stopped and removed by its id, nothing else';
};

subtest 'without a port, the image decides' => sub {
  my $fake = fake_docker(images => \%IMAGES);

  my $one = upstream($fake, {docker => 't/expose1'}, name => 'one');
  my ($ok, $err) = await($one->start_p);
  ok $ok, 'one EXPOSE: started' or diag $err;
  is $one->mode, 'http', 'one EXPOSE: HTTP on it';
  ok grep({/^run -d .* -p 127\.0\.0\.1::8080 t\/expose1$/} @{commands($fake)}), 'that port is published';
  ok echo_ok($one), 'and answers';
  stop_and_settle($one);

  my $two = upstream($fake, {docker => 't/expose2'}, name => 'two');
  ($ok, $err) = await($two->start_p);
  ok !$ok, 'two EXPOSEs and no port: no start';
  like $err, qr{image t/expose2 exposes 8080/tcp and 9090/tcp -- set "port" to the one the MCP server listens on},
    'the error names the ports and the fix';
  ok !(grep {/^run .*t\/expose2/} @{commands($fake)}), 'no container was started';

  my $picked = upstream($fake, {docker => 't/expose2', port => 9090}, name => 'picked');
  ($ok, $err) = await($picked->start_p);
  ok $ok, 'two EXPOSEs and a port: started' or diag $err;
  ok grep({/^run -d .* -p 127\.0\.0\.1::9090 t\/expose2$/} @{commands($fake)}), 'on the port given';
  stop_and_settle($picked);

  my $forced = upstream($fake, {docker => 't/expose-stdio', stdio => \1}, name => 'forced');
  ($ok, $err) = await($forced->start_p);
  ok $ok, '"stdio": true over an EXPOSE: started' or diag $err;
  is $forced->mode, 'stdio', 'and spoken to over stdio';
  ok echo_ok($forced), 'it answers';
  stop_and_settle($forced);

  my $wrong = upstream($fake, {docker => 't/expose-stdio'}, name => 'wrong');
  ($ok, $err) = await($wrong->start_p);
  ok !$ok, 'a stdio server behind an EXPOSE fails the start';
  like $err, qr/the container exited \(code 0\) while starting/, 'it says the container exited';
  like $err, qr/the port comes from the image's EXPOSE; if this server speaks stdio, set "stdio": true/,
    'and suggests "stdio": true';

  my $path = upstream($fake, {docker => 't/stdio', path => '/sse', type => 'sse'}, name => 'path');
  ($ok, $err) = await($path->start_p);
  ok !$ok, 'path and type on an image that turns out stdio: no start';
  like $err, qr/image t\/stdio exposes no port, so the hub talks to it over stdio -- "path", "type" only apply to an HTTP server: set "port", or remove them/,
    'the error says they need a port';
  ok !(grep {/^run .*t\/stdio/} @{commands($fake)}), 'no container was started';

  ok wait_until(sub { !@{records($fake)} }), 'nothing left';
};

subtest 'readiness: a slow server is waited for, a silent one is given up on' => sub {
  my $fake = fake_docker(images => \%IMAGES);

  my $slow = upstream($fake, {docker => 't/slow'}, name => 'slow');
  my ($ok, $err) = await($slow->start_p);
  ok $ok, 'a server that listens late is waited for' or diag $err;
  ok echo_ok($slow), 'and answers';
  stop_and_settle($slow);

  my $silent = upstream($fake, {docker => 't/silent'}, name => 'silent', request_timeout => 2);
  ($ok, $err) = await($silent->start_p);
  ok !$ok, 'a server that never answers fails the start';
  like $err, qr{no MCP answer from http://127\.0\.0\.1:\d+/mcp within 2s}, 'after request_timeout';
  like $err, qr/set "stdio": true/, 'suggesting stdio, as the port came from EXPOSE';
  ok wait_until(sub { !@{records($fake)} }), 'and its container is removed';
};

subtest 'a container that crashes' => sub {
  my $fake = fake_docker(images => \%IMAGES);

  my $http = upstream($fake, {docker => 't/http', port => 8080}, name => 'web');
  my ($ok, $err) = await($http->start_p);
  ok $ok, 'started' or diag $err;
  my ($first) = map { $_->{id} } @{running($fake)};
  await($http->call_tool('exit', {}), 10);
  ok wait_until(sub { $http->state eq 'stopped' }), 'an exit while serving is noticed';
  ok grep({/container exited/} @LOG), 'and logged';
  ok echo_ok($http, 'again'), 'the next call starts a new container';
  my @ids = map { $_->{id} } @{running($fake)};
  ok @ids == 1 && $ids[0] ne $first, 'one container, a new one';
  stop_and_settle($http);

  my $boot = upstream($fake, {docker => 't/crash', port => 8080}, name => 'boot');
  ($ok, $err) = await($boot->start_p);
  ok !$ok, 'a container that dies while starting fails the start';
  like $err, qr/the container exited \(code 3\) while starting: fatal: MCPHUB_TEST_TOKEN is not set/,
    'with its exit code and the last of its output';
  unlike $err, qr/stdio/, 'no stdio hint for a port that was given';

  my $loop = upstream($fake, {docker => 't/crash'}, name => 'loop', fail_window => 60);
  for my $n (1 .. 3) {
    ($ok, $err) = await($loop->start_p);
    ok !$ok, "start $n fails";
    like $err, qr/fatal: MCPHUB_TEST_TOKEN is not set/, "start $n says why, from the container's stderr";
  }
  is $loop->state, 'failed', 'three failures in the window: failed';
  like $loop->error, qr/3 failed starts or crashes within 60s, the last: .*MCPHUB_TEST_TOKEN/, 'the error says so';
  my $before = @{calls($fake)};
  ($ok, $err) = await($loop->start_p);
  like $err, qr/run 'mcp-hub refresh loop' to try again/, 'a failed upstream asks for a refresh';
  is scalar @{calls($fake)}, $before, 'and runs no docker command';

  ok wait_until(sub { !@{records($fake)} }), 'nothing left';
};

subtest 'a stop while starting' => sub {
  my $fake = fake_docker(images => \%IMAGES);
  my $up   = upstream($fake, {docker => 't/slow'});
  my $start = $up->start_p;
  Mojo::Promise->timer(0.5)->wait;
  $up->stop;
  my ($ok, $err) = await($start);
  ok !$ok, 'the start gives up';
  like $err, qr/stopped while starting/, 'saying it was stopped';
  is $up->state, 'stopped', 'stopped';
  await($up->stopped_p);
  ok wait_until(sub { !@{records($fake)} }), 'and the container it had begun is gone';
};

subtest 'a stop during the MCP handshake' => sub {
  my $fake = fake_docker(images => \%IMAGES);
  my $up   = upstream($fake, {docker => 't/http', port => 8080});

  # The handshake is over in milliseconds: the stop is put right into it.
  my $handshake = MCP::Hub::Upstream::Docker::Http->can('start_p');
  no warnings qw(once redefine);
  local *MCP::Hub::Upstream::Docker::Http::start_p = sub ($engine) {
    my $p = $handshake->($engine);
    $up->stop;
    return $p;
  };
  use warnings;

  my ($ok, $err) = await($up->start_p);
  ok !$ok, 'the start gives up';
  like $err, qr/stopped while starting/, 'saying it was stopped';
  is $up->state, 'stopped', 'stopped, not ready';
  ok !$up->{engine}, 'with no connection left';
  ($ok) = await($up->stopped_p, 15);
  ok $ok, 'stopped_p resolves';
  ok wait_until(sub { !@{records($fake)} }), 'and the container is gone';
};

subtest 'a container created, then not started, is removed by its labels' => sub {
  my $fake = fake_docker(images => {%IMAGES, 't/taken' => {kind => 'nostart'}});
  my $up   = upstream($fake, {docker => 't/taken', port => 8080});
  my ($ok, $err) = await($up->start_p);
  ok !$ok, 'the start fails';
  like $err, qr/cannot start the container: .*port is already allocated/, 'with Docker\'s reason';
  await($up->stopped_p);
  is_deeply records($fake), [], 'and the container docker run left behind without naming it is gone';
  my @cmds = @{commands($fake)};
  ok grep({/^ps -a -q .*--filter label=mcp-hub\.run=[0-9a-f]+ /} @cmds), 'found by the labels of that start';
  is scalar(grep {/^rm -f [0-9a-f]{64}$/} @cmds), 1, 'and removed by its id';
};

# --- docker: what the hub may touch ----------------------------------------

subtest 'leftovers: only this hub\'s, by its labels' => sub {
  my $fake  = fake_docker(images => \%IMAGES);
  my $up    = upstream($fake, {docker => 't/stdio'});
  my $owner = $up->owner_id;
  my ($ours, $other, $foreign) = ('a' x 64, 'b' x 64, 'c' x 64);
  put_record($fake, {id => $ours,  name => 'old', state => 'exited',
    labels => {'mcp-hub.server' => 'srv', 'mcp-hub.owner' => $owner}});
  put_record($fake, {id => $other, name => 'other-hub', state => 'exited',
    labels => {'mcp-hub.server' => 'srv', 'mcp-hub.owner' => 'f00f00f00f00'}});
  put_record($fake, {id => $foreign, name => 'forgejo', state => 'running', labels => {}});

  my ($ok, $err) = await($up->start_p);
  ok $ok, 'started' or diag $err;
  my %left = map { $_->{id} => 1 } @{records($fake)};
  ok !$left{$ours},     'this hub\'s leftover was removed';
  ok $left{$other},     'another hub\'s container was left alone';
  ok $left{$foreign},   'a container without the labels was left alone';
  is_deeply [grep {/^rm /} @{commands($fake)}], ["rm -f $ours"], 'one rm, of exactly that leftover';
  # The fake's ps matches label keys only: the other hub's container was
  # listed, and only the check of its labels kept the hub off it.
  ok grep({ /^inspect .*\b$other\b/ } @{commands($fake)}), 'the label check saw the other hub\'s container';
  stop_and_settle($up);

  my $blocked = fake_docker(images => \%IMAGES);
  put_record($blocked, {id => $foreign, name => 'mcp-hub-srv', state => 'running', labels => {}});
  my $named = upstream($blocked, {docker => 't/stdio'});
  ($ok, $err) = await($named->start_p);
  ok !$ok, 'a foreign container holding the name blocks the start';
  like $err, qr/already in use.* -- a container of that name exists that this hub did not start; remove it if it is a leftover, or rename this server/,
    'and the error says what to do';
  ok grep({ $_->{id} eq $foreign } @{records($blocked)}), 'the foreign container is untouched';
  ok !(grep {/^(?:rm|stop) /} @{commands($blocked)}), 'no rm or stop was ever run';

  # The CLI's stdout and stderr end at once; under load the IOLoop may see the
  # end of stdout first. Its stderr is not read here until then.
  {
    no warnings qw(once redefine);
    local *MCP::Hub::Upstream::Docker::Stdio::_spawn = sub ($engine) {
      my $pid = MCP::Hub::Upstream::Stdio::_spawn($engine);
      my $pipe = $engine->{err_stream};
      $pipe->reactor->remove($pipe->handle);
      return $pid;
    };
    ($ok, $err) = await(upstream($blocked, {docker => 't/stdio'})->start_p);
  }
  like $err, qr/already in use.* -- a container of that name exists that this hub did not start/,
    'Docker\'s message is kept when the end of stdout is seen first';
};

subtest 'a stdio CLI that is killed: its container is removed by the start\'s labels' => sub {
  my $fake = fake_docker(images => \%IMAGES);
  my $up   = upstream($fake, {docker => 't/stdio'});
  my ($ok, $err) = await($up->start_p);
  ok $ok, 'started' or diag $err;
  my ($record) = @{running($fake)};
  my $run      = $record->{labels}{'mcp-hub.run'};
  my $owner    = $up->owner_id;

  kill 'KILL', $up->{engine}{pid};
  ok wait_until(sub { $up->state eq 'stopped' }), 'the end of the CLI is noticed';
  ok wait_until(sub { !@{records($fake)} }), 'and the container it left behind is removed';
  ok grep({ $_ eq "ps -a -q --filter label=mcp-hub.owner=$owner --filter label=mcp-hub.run=$run --filter label=mcp-hub.server=srv" }
    @{commands($fake)}), 'looked for by the labels of that start';
  is_deeply [grep {/^rm /} @{commands($fake)}], ["rm -f $record->{id}"], 'and removed by its id, nothing else';
};

subtest 'a line over 16MB: the container is dropped, and the next call starts a new one' => sub {
  my $fake = fake_docker(images => \%IMAGES);
  my $up   = upstream($fake, {docker => 't/stdio'}, request_timeout => 30);    # room for 17MB, under load
  ok echo_ok($up), 'it answers';
  my ($first) = map { $_->{id} } @{running($fake)};

  my ($ok, $res) = await($up->call_tool('echo', {msg => 'x' x (17 * 1024 * 1024)}), 60);
  ok !$ok || $res->{isError}, 'the call whose answer is too long fails';
  like $ok ? text_of($res) : $res, qr/exited/, 'as the container is gone';
  ok wait_until(sub { $up->state eq 'stopped' }), 'and the upstream is stopped, not left ready';
  ok !$up->{engine}, 'with its dead connection dropped';
  ok wait_until(sub { !grep { $_->{id} eq $first } @{records($fake)} }), 'its container is removed';

  my $t0 = time;
  ok echo_ok($up, 'after'), 'the next call answers';
  ok time - $t0 < 20, 'at once, from a new container -- not after request_timeout';
  my @ids = map { $_->{id} } @{running($fake)};
  ok @ids == 1 && $ids[0] ne $first, 'one container, a new one';
  stop_and_settle($up);
};

subtest 'a cache directory that cannot keep the owner id: no container' => sub {
  my $fake = fake_docker(images => \%IMAGES);
  my $tmp  = tempdir;
  my $file = $tmp->child('a-file')->spew('not a directory');
  my $up   = upstream($fake, {docker => 't/stdio'}, cache => $file->child('cache'));
  my ($ok, $err) = await($up->start_p);
  ok !$ok, 'the start fails';
  like $err, qr{cannot keep a docker owner id in \Q$file\E/cache/docker-owner \(.+\) -- docker and compose entries need a writable hub\.cache_dir},
    'saying where, and what to do';
  is_deeply calls($fake), [], 'without a single docker command: there is no guessing an id';
};

subtest 'hub.docker_network: on the network, addressed by name' => sub {
  my $fake = fake_docker(images => \%IMAGES);
  my $up   = upstream($fake, {docker => 't/http', port => 8080, path => '/rpc'}, hub => {docker_network => 'mcp-hub'});
  is $up->_container_url({port => 8080}), 'http://mcp-hub-srv:8080/rpc', 'the container name and its own port';

  # Only the argv is checked: the fake's containers have no name to resolve.
  my @seen;
  my $stub = Test::StubDocker->new(command => 'docker', log => $LOG, seen => \@seen);
  $up->docker($stub);
  my $engine = $up->_new_engine({mode => 'http', port => 8080});
  my ($ok, $err) = await($up->_launch_http_p($engine, {mode => 'http', port => 8080}));
  ok !$ok, 'the stubbed run fails';
  my ($run) = grep { $_->[0] eq 'run' } @seen;
  ok $run, 'docker run was called';
  my $argv = join ' ', @{$run // []};
  like $argv, qr/ --network mcp-hub t\/http$/, 'on the network';
  unlike $argv, qr/ -p /, 'with no port published on the host';
  $up->_drop_engine;
};

subtest 'the manifest hash: never env, never the docker command' => sub {
  my $fake  = fake_docker;
  my $other = fake_docker;
  my $base  = upstream($fake, {docker => 't/stdio', env => {A => 1}})->_hash;
  is upstream($fake, {docker => 't/stdio', env => {A => 2}})->_hash, $base, 'env is not hashed';
  is upstream($other, {docker => 't/stdio'})->_hash, $base, 'nor the docker command';
  isnt upstream($fake, {docker => 't/stdio:2'})->_hash,           $base, 'the image is';
  isnt upstream($fake, {docker => 't/stdio', port => 8080})->_hash, $base, 'the port is';
  isnt upstream($fake, {docker => 't/stdio', stdio => \1})->_hash,  $base, '"stdio" is';
  isnt upstream($fake, {docker => 't/stdio', args => ['x']})->_hash, $base, 'the args are';
  isnt upstream($fake, {docker => 't/stdio', volumes => ['/a:/b']})->_hash, $base, 'the volumes are';
  isnt upstream($fake, {docker => 't/stdio', path => '/rpc'})->_hash, $base, 'the path is';
  isnt upstream($fake, {docker => 't/stdio', type => 'sse'})->_hash, $base, 'the type is';
  isnt upstream($fake, {docker => 't/stdio', docker_args => ['--read-only']})->_hash, $base, 'the docker_args are';
};

subtest 'the docker CLI or its daemon missing' => sub {
  my $fake = fake_docker(images => \%IMAGES);
  my $none = upstream($fake, {docker => 't/stdio'}, hub => {docker_command => '/nonexistent/k21/docker'});
  my ($ok, $err) = await($none->start_p);
  ok !$ok, 'no CLI: no start';
  like $err, qr{'/nonexistent/k21/docker' not found \(.+\) -- install the Docker CLI or set hub\.docker_command},
    'the error names the command and the setting';

  $fake->{state}->child('down')->touch;
  my $down = upstream($fake, {docker => 't/stdio'});
  ($ok, $err) = await($down->start_p);
  ok !$ok, 'no daemon: no start';
  like $err, qr/Cannot connect to the Docker daemon.* -- is the Docker daemon running\? When the hub itself runs in a container, mount \/var\/run\/docker\.sock into it/,
    'the error points at the socket';
};

subtest 'run_p: exit code and output, and nothing kept once it is over' => sub {
  my @streams;
  my $new = Mojo::IOLoop::Stream->can('new');
  no warnings qw(once redefine);
  local *Mojo::IOLoop::Stream::new = sub { my $s = $new->(@_); weaken($streams[@streams] = $s); $s };
  use warnings;

  my $docker = MCP::Hub::Docker->new(command => $^X, log => $LOG);
  my @res;
  for (1 .. 5) {
    my ($ok, $res) = await($docker->run_p(['-e', 'print "out\n"; print STDERR "err\n"; exit 3']));
    push @res, $ok ? "$res->{code}|$res->{out}|$res->{err}" : "rejected: $res";
  }
  is_deeply \@res, [("3|out\n|err\n") x 5], 'every run reports its exit code, stdout and stderr';
  my ($ok, $err) = await($docker->run_p(['-e', 'sleep 10'], timeout => 0.3));
  like $err, qr/timed out after 0\.3s/, 'one that runs too long is given up on';
  Mojo::Promise->timer(0.2)->wait;
  is scalar @streams, 12, 'two streams per run';
  is scalar(grep {defined} @streams), 0, 'and not one of them outlives its run';

  my $kill;
  my $long = $docker->run_p(['-e', 'sleep 10'], on_spawn => sub ($k) { $kill = $k });
  ok $kill, 'on_spawn hands out a way to signal the command';
  $kill->() if $kill;
  ($ok, my $res) = await($long, 5);
  ok $ok && $res->{signal} == 15, 'which ends it with TERM';
};

# --- docker: inside the hub ------------------------------------------------

sub hub_config ($fake, $cache, %servers) {
  return {mcpServers => \%servers, hub => {cache_dir => "$cache", docker_command => $fake->{command}}};
}

sub client ($t, $path) {
  my $base = $t->ua->server->url->to_string =~ s{/$}{}r;
  return MCP::Client->new(ua => $t->ua, url => "$base$path");
}

subtest 'in the hub: warmed, then lazy, then shut down' => sub {
  my $fake  = fake_docker(images => \%IMAGES);
  my $cache = tempdir;
  my %servers = (box => {docker => 't/stdio'}, web => {docker => 't/expose1'});

  my $warm = MCP::Hub->new(hub_config_input => hub_config($fake, $cache, %servers));
  $warm->start_background_fetches;
  ok wait_until(sub { !grep { !$_->manifest_fetched_at } @{$warm->upstreams} }, 30), 'both manifests fetched';
  ok wait_until(sub { !@{records($fake)} && !grep { $_->state ne 'stopped' } @{$warm->upstreams} }),
    'and their containers stopped again';
  await($warm->shutdown_p);    # and the cleanup after them is over, too

  my $app    = MCP::Hub->new(hub_config_input => hub_config($fake, $cache, %servers));
  my $t      = Test::Mojo->new($app);
  my $before = scalar @{calls($fake)};
  $app->start_background_fetches;
  Mojo::Promise->timer(0.5)->wait;
  is scalar @{calls($fake)}, $before, 'with cached manifests, a daemon start runs no docker command';
  is_deeply [map { $_->state } @{$app->upstreams}], ['stopped', 'stopped'], 'and starts no container';

  my $tools  = client($t, '/box')->list_tools;
  ok((grep { $_->{name} eq 'echo' } @{$tools->{tools}}), 'tools/list answered from the cache');
  my $all = client($t, '/all')->list_tools;
  ok((grep { $_->{name} eq 'web__echo' } @{$all->{tools}}), 'the aggregate lists the HTTP one too');
  is scalar @{calls($fake)}, $before, 'without a single docker command';

  is text_of(client($t, '/box')->call_tool('echo', {msg => 'boxed'})), 'boxed', 'tools/call starts the container';
  is text_of(client($t, '/web')->call_tool('echo', {msg => 'webbed'})), 'webbed', 'the HTTP one as well';
  is scalar @{running($fake)}, 2, 'two containers run';

  $t->get_ok('/_hub/status')->status_is(200);
  my %type = map { $_->{name} => $_->{type} } @{$t->tx->res->json('/upstreams')};
  is_deeply \%type, {box => 'docker', web => 'docker'}, 'the status names the type';

  my ($ok, $err) = await($app->shutdown_p);
  ok $ok, 'shutdown_p resolves' or diag $err;
  is_deeply records($fake), [], 'and no container outlives it';
};

subtest 'a reload rebuilds a changed docker entry, and keeps a cached manifest' => sub {
  my $fake  = fake_docker(images => \%IMAGES);
  my $cache = tempdir;
  my $tmp   = tempdir;
  my $file  = $tmp->child('mcp-hub.json');
  push @KEEP, $tmp;
  my %keep = (keep => {docker => 't/expose1'});
  $file->spew(encode_json(hub_config($fake, $cache, %keep, box => {docker => 't/stdio', env => {MCPHUB_TEST_A => 1}})));

  my $app  = MCP::Hub->new(hub_config_input => "$file");
  my $box  = $app->upstreams_by_name->{box};
  my $kept = $app->upstreams_by_name->{keep};
  ok echo_ok($box, 'first'), 'the first container answers';
  my ($first) = map { $_->{id} } @{running($fake)};

  # env only: rebuilt, but the manifest it had is still valid -- no warming start
  my $runs = scalar grep {/^run /} @{commands($fake)};
  $file->spew(encode_json(hub_config($fake, $cache, %keep, box => {docker => 't/stdio', env => {MCPHUB_TEST_A => 2}})));
  my $summary = $app->reload;
  is_deeply $summary->{changed},   ['box'],  'an env change rebuilds the server';
  is_deeply $summary->{unchanged}, ['keep'], 'and leaves the unchanged one alone';
  is $app->upstreams_by_name->{keep}, $kept, 'the very same upstream';
  my $new = $app->upstreams_by_name->{box};
  ok $new->manifest_fetched_at, 'whose manifest is still cached';
  ok wait_until(sub { !@{records($fake)} }), 'the old container is gone';
  is scalar(grep {/^run /} @{commands($fake)}), $runs, 'and nothing was started to refetch it';

  ok echo_ok($new, 'second'), 'the new upstream starts its own container';
  my @calls = grep { $_->{argv}[0] eq 'run' } @{calls($fake)};
  is $calls[-1]{env}{MCPHUB_TEST_A}, 2, 'with the new env';
  my @ids = map { $_->{id} } @{running($fake)};
  ok @ids == 1 && $ids[0] ne $first, 'one container, a new one';

  # hub.docker_command: every docker entry is rebuilt, onto the new command
  my $other = fake_docker(images => \%IMAGES);
  my $data  = hub_config($other, $cache, %keep, box => {docker => 't/stdio', env => {MCPHUB_TEST_A => 2}});
  $file->spew(encode_json($data));
  $summary = $app->reload;
  is_deeply [sort @{$summary->{changed}}], ['box', 'keep'], 'a docker_command change rebuilds the docker servers';
  is $app->upstreams_by_name->{box}->docker->command, $other->{command}, 'onto the new command';
  ok wait_until(sub { !@{records($fake)} }), 'the old command removed its container';

  await($app->shutdown_p);
  is_deeply records($fake),  [], 'nothing left';
  is_deeply records($other), [], 'on either';
};

# --- compose ---------------------------------------------------------------

# A compose project for the fake: what `docker compose config --format json`
# answers in that directory, plus x-kind, what its containers do.
sub compose_project (%services) {
  my $dir = tempdir;
  push @KEEP, $dir;
  $dir->child('fake-compose.json')->spew(encode_json({name => 'k21proj', services => \%services}));
  return "$dir";
}

my %SERVICES = (
  mcp   => {'x-kind' => 'http', ports => [{target => 8080, published => '0', protocol => 'tcp'}]},
  multi => {'x-kind' => 'http', ports => [{target => 80, published => '0'}, {target => 8080, published => '0'}]},
  tool  => {'x-kind' => 'stdio'},
  db    => {'x-kind' => 'stdio'},
);

subtest 'compose: the service must be in the project' => sub {
  my $fake = fake_docker;
  my $dir  = compose_project(%SERVICES);
  my $up   = upstream($fake, {compose => $dir, service => 'nope'});
  my ($ok, $err) = await($up->start_p);
  ok !$ok, 'an unknown service: no start';
  like $err, qr/service 'nope' is not in the compose project in \Q$dir\E \(its services: db, mcp, multi, tool\)/,
    'the error lists the services there are';
  my ($config) = @{calls($fake)};
  is_deeply $config->{argv}, [qw(compose config --format json)], 'the project is read with compose config';
  is $config->{cwd}, $dir, 'in its directory';
  is scalar @{calls($fake)}, 1, 'and nothing else was run';
};

subtest 'in the hub: a warming fetch that fails is failed, with the reason, until a refresh' => sub {
  # One failed warming fetch used to leave the upstream `stopped` with no
  # error, its endpoint answering 503 "not ready yet" -- still fetching -- for
  # good, though nothing was fetching any more.
  my $fake  = fake_docker(images => \%IMAGES);
  my $dir   = compose_project(%SERVICES);
  my $cache = tempdir;
  push @KEEP, $cache;
  my $app = MCP::Hub->new(log => $LOG, hub_config_input => hub_config($fake, $cache,
    later => {docker  => 't/later'},
    svc   => {compose => $dir, service => 'nope'},
  ));
  my $t   = Test::Mojo->new($app);
  my %up  = %{$app->upstreams_by_name};
  my $rpc = {jsonrpc => '2.0', id => 1, method => 'tools/list', params => {}};

  $app->start_background_fetches;
  ok wait_until(sub { !grep { $_->state ne 'failed' } values %up }), 'both warming fetches end in failed'
    or diag explain {map { $_ => $up{$_}->state } keys %up};
  like $up{later}->error, qr/^cannot pull t\/later: .*pull access denied/, 'docker: with the reason';
  like $up{svc}->error, qr/^service 'nope' is not in the compose project/, 'compose: with the reason';
  for my $name (qw(later svc)) {
    $t->post_ok("/$name" => json => $rpc)->status_is(503, "$name: 503")
      ->json_like('/error', qr/^upstream '$name' failed: \Q@{[$up{$name}->error]}\E$/, "$name: the failed meaning")
      ->json_unlike('/error', qr/not ready yet/, "$name: not the still-fetching one");
  }

  my ($ok, $res) = await($app->refresh_p('svc'));
  is $res->{svc}{state}, 'failed', 'compose: a refresh that fails again leaves it failed';
  like $res->{svc}{error}, qr/^service 'nope'/, 'and says why';

  # The image can be pulled now: a refresh clears the failure and starts it.
  $fake->{state}->child('registry.json')->spew(encode_json({'t/later' => {kind => 'stdio'}}));
  ($ok, $res) = await($app->refresh_p('later'));
  is $res->{later}{state}, 'ready', 'docker: a refresh brings it back' or diag explain $res;
  is $up{later}->error, undef, 'with no reason left';
  $t->post_ok('/later' => json => $rpc)->status_is(200);

  await($app->shutdown_p);
  is_deeply records($fake), [], 'nothing left';
};

subtest 'compose: what compose config printed never goes into an error' => sub {
  my $fake = fake_docker;
  my $dir  = compose_project(%SERVICES);
  fail_with($fake, '^compose config', out => "services:\n  mcp:\n    environment:\n      TOKEN: hunter2-k21\n");
  my $up = upstream($fake, {compose => $dir, service => 'mcp'});
  my ($ok, $err) = await($up->start_p);
  ok !$ok, 'a failing compose config fails the start';
  like $err, qr/docker compose config failed in \Q$dir\E: exit 1/, 'saying so';
  unlike $err, qr/hunter2/, 'with nothing of the project it printed';
  ok !(grep {/hunter2/} @LOG), 'nor anything of it in the log';
};

subtest 'compose: a service that publishes no port runs over stdio' => sub {
  my $fake = fake_docker;
  my $dir  = compose_project(%SERVICES);
  my $up   = upstream($fake, {compose => $dir, service => 'tool', env => {MCPHUB_TEST_B => 'b'}}, idle_timeout => 1);
  my ($ok, $err) = await($up->start_p);
  ok $ok, 'started' or diag $err;
  is $up->mode, 'stdio', 'mode stdio';
  ok echo_ok($up), 'it answers';

  my ($run) = grep { $_->{argv}[0] eq 'compose' && $_->{argv}[1] eq 'run' } @{calls($fake)};
  my $owner = $up->owner_id;
  my @argv  = @{$run->{argv}};
  my ($label) = grep {/^mcp-hub\.run=/} @argv;
  is_deeply \@argv, ['compose', 'run', '--rm', '-T', '--no-deps', '--name', 'mcp-hub-srv',
    '--label', 'mcp-hub.server=srv', '--label', "mcp-hub.owner=$owner", '--label', $label, 'tool'],
    'compose run --rm -T --no-deps, named and labelled, of that service';
  is $run->{cwd}, $dir, 'in the project directory';
  is $run->{env}{MCPHUB_TEST_B}, 'b', 'with the entry\'s env';

  my $row = $up->status_row;
  is $row->{type},    'compose', 'status: type compose';
  is $row->{compose}, $dir,      'status: the project';
  is $row->{service}, 'tool',    'status: the service';

  ok wait_until(sub { $up->state eq 'stopped' }, 10), 'stopped after idle_timeout';
  ok wait_until(sub { !@{records($fake)} }), 'and the run container is gone';
  ok !(grep {/^compose (?:up|stop|down)/} @{commands($fake)}), 'no compose up, stop or down';
};

subtest 'compose: a service that publishes one port runs over HTTP, and only it is stopped' => sub {
  my $fake = fake_docker;
  my $dir  = compose_project(%SERVICES);
  my $up   = upstream($fake, {compose => $dir, service => 'mcp'}, idle_timeout => 1);
  my ($ok, $err) = await($up->start_p);
  ok $ok, 'started' or diag $err;
  is $up->mode, 'http', 'mode http';
  ok echo_ok($up, 'composed'), 'it answers';

  my @compose = grep {/^compose /} @{commands($fake)};
  is_deeply \@compose, [
    'compose config --format json',
    'compose ps --status running --status restarting --status paused -q mcp',
    'compose up -d --no-recreate mcp',
    'compose ps -q mcp',
    'compose port mcp 8080',
  ], 'not running yet: up -d of that service, and where it published its port';
  ok !(grep {/\bdb\b|\btool\b|\bmulti\b/} @compose), 'no other service is named';

  ok wait_until(sub { $up->state eq 'stopped' }, 10), 'stopped after idle_timeout';
  ok wait_until(sub { !@{running($fake)} }), 'the service is no longer running';
  my @after = grep {/^compose (?:stop|down|rm|kill)|^(?:stop|rm) /} @{commands($fake)};
  is_deeply \@after, ['compose stop mcp'], 'by compose stop mcp, and nothing broader';
};

subtest 'compose: ports and url decide' => sub {
  my $fake = fake_docker;
  my $dir  = compose_project(%SERVICES);

  my $unpublished = upstream($fake, {compose => $dir, service => 'mcp', port => 9999});
  my ($ok, $err) = await($unpublished->start_p);
  ok !$ok, 'a port the service does not publish: no start';
  like $err, qr/service 'mcp' does not publish port 9999 -- add it under ports: in the compose file, or give "url"/,
    'the error names the fix';

  my $multi = upstream($fake, {compose => $dir, service => 'multi'});
  ($ok, $err) = await($multi->start_p);
  ok !$ok, 'several published ports and no port: no start';
  like $err, qr/service 'multi' publishes ports 80, 8080 -- set "port" to the one the MCP server listens on/,
    'the error names the ports';
  ok !(grep {/^compose (?:up|run)/} @{commands($fake)}), 'nothing was started so far';

  my $forced = upstream($fake, {compose => $dir, service => 'mcp', stdio => \1});
  ($ok, $err) = await($forced->start_p);
  ok $ok, '"stdio": true over published ports: started' or diag $err;
  is $forced->mode, 'stdio', 'over stdio';
  ok grep({/^compose run --rm -T .* mcp$/} @{commands($fake)}), 'with compose run';
  stop_and_settle($forced);

  # url: the hub connects there and asks compose for no port
  my $mcp = MCP::Server->new(name => 'beside', version => '1.0');
  $mcp->tool(name => 'echo', description => 'Echo', input_schema => {type => 'object'},
    code => sub ($tool, $args) { $tool->text_result("beside: $args->{msg}") });
  my $web = Mojolicious->new;
  $web->log->level('fatal');
  $web->routes->post('/mcp' => $mcp->to_action({streaming => 1}));
  my $daemon = Mojo::Server::Daemon->new(app => $web, listen => ['http://127.0.0.1'], silent => 1);
  $daemon->start;
  my $url = 'http://127.0.0.1:' . $daemon->ports->[0] . '/mcp';

  my $before = scalar @{calls($fake)};
  my $there  = upstream($fake, {compose => $dir, service => 'mcp', url => $url});
  ($ok, $err) = await($there->start_p);
  ok $ok, 'with url: started' or diag $err;
  my ($ok2, $res) = await($there->call_tool('echo', {msg => 'x'}));
  is text_of($res), 'beside: x', 'the tool call went to the url';
  my @all  = @{commands($fake)};
  my @mine = @all[$before .. $#all];
  ok grep({ $_ eq 'compose up -d --no-recreate mcp' } @mine), 'the service was brought up';
  ok !(grep {/^compose port/} @mine), 'and no port was looked up';
  stop_and_settle($there);
  ok grep({ $_ eq 'compose stop mcp' } @{commands($fake)}), 'stopped with compose stop';
  $daemon->stop;
};

subtest 'compose: an https url without TLS is a failed upstream that names the fix' => sub {
  # A perl without IO::Socket::SSL 2.009+ (or with MOJO_NO_TLS) cannot speak
  # https, and cannot learn to while it runs. A compose entry's url is in its
  # config from the start, as a url entry's is; only its engine gets it late.
  # Before the fix the start brought the service up and then asked that url
  # until request_timeout ran out -- a "no MCP answer" that never said why.
  # Nothing here connects anywhere.
  my $fake  = fake_docker(images => \%IMAGES);
  my $dir   = compose_project(%SERVICES);
  my $https = 'https://127.0.0.1:9/mcp';
  no warnings 'redefine';
  local *Mojo::IOLoop::TLS::can_tls = sub { 0 };

  my $built = eval { upstream($fake, {compose => $dir, service => 'mcp', url => $https}) };
  is $built, undef, 'the upstream is not built';
  like $@, qr/^an https url needs TLS\b.*IO::Socket::SSL 2\.009.*cpanm IO::Socket::SSL.*restart the daemon\n\z/,
    'the reason says what is missing and how to fix it';

  ok eval { upstream($fake, {compose => $dir, service => 'mcp', url => 'http://127.0.0.1:9/mcp'}) },
    'an http url needs no TLS and is built as before' or diag $@;
  ok eval { upstream($fake, {compose => $dir, service => 'mcp'}) },
    'nor does a service reached where compose published it, over http' or diag $@;
  is_deeply calls($fake), [], 'no docker command so far';

  # In the hub: failed at once, with the reason a url entry with that url
  # gives, word for word -- and the warm-up and a refresh run nothing.
  my $cache = tempdir;
  push @KEEP, $cache;
  my $app = MCP::Hub->new(log => $LOG, hub_config_input => {
    mcpServers => {svc => {compose => $dir, service => 'mcp', url => $https}, remote => {url => $https}},
    hub        => {cache_dir => "$cache", docker_command => $fake->{command}, request_timeout => 2},
  });
  my %up = %{$app->upstreams_by_name};
  $app->start_background_fetches;
  my $reason = $up{remote}->error;
  like $reason, qr/^an https url needs TLS\b/, 'the url entry is failed, as k32 made it';
  is $up{svc}->state, 'failed', 'compose: failed, before any start';
  is $up{svc}->error, $reason, 'with the same reason';
  my $row = $up{svc}->status_row;
  is $row->{type},  'compose', 'the status row keeps its type';
  is $row->{error}, $reason,   'and carries the reason';

  my $t = Test::Mojo->new($app);
  $t->post_ok('/svc' => json => {jsonrpc => '2.0', id => 1, method => 'tools/list', params => {}})
    ->status_is(503)->json_is('/error', "upstream 'svc' failed: $reason", 'the 503 gives the reason');

  my ($ok, $res) = await($app->refresh_p('svc'), 10);
  is $res->{svc}{state}, 'failed', 'a refresh cannot cure it: still failed';
  is $res->{svc}{error}, $reason,  'and says why';
  is_deeply commands($fake), [], 'nothing was run: no compose config, no up';
  await($app->shutdown_p);

  # The check keys on TLS, not on the scheme alone: with TLS the same entry is
  # an ordinary compose upstream that waits for its first call.
  local *Mojo::IOLoop::TLS::can_tls = sub { 1 };
  my $up = upstream($fake, {compose => $dir, service => 'mcp', url => $https});
  is $up->state, 'stopped', 'with TLS: built, nothing started yet';
  ok !$up->placeholder, 'and no placeholder';
};

subtest 'docker: the hub builds the address, always http, so TLS is never needed' => sub {
  # A docker entry has no url: the hub reaches the container where Docker
  # published its port on the loopback (or by its name on hub.docker_network),
  # over http, and `type` only picks Streamable HTTP or SSE.
  my $fake = fake_docker(images => \%IMAGES);
  no warnings 'redefine';
  local *Mojo::IOLoop::TLS::can_tls = sub { 0 };
  my $up = upstream($fake, {docker => 't/http', port => 8080});
  my ($ok, $err) = await($up->start_p);
  ok $ok, 'started without TLS' or diag $err;
  like $up->{engine}->url, qr{^http://127\.0\.0\.1:\d+/mcp$}, 'at an http address on the loopback';
  ok echo_ok($up, 'plain'), 'and a tool call goes through';
  stop_and_settle($up);
};

subtest 'compose: a service that already runs is used as it is, and left running' => sub {
  my $fake = fake_docker;
  my $dir  = compose_project(%SERVICES);
  system("cd '$dir' && '$fake->{command}' compose up -d mcp >/dev/null 2>&1") == 0 or fail 'cannot bring mcp up';
  my ($theirs) = @{running($fake)};
  ok $theirs, 'someone else brought the service up';

  my $before = scalar @{calls($fake)};
  my $up     = upstream($fake, {compose => $dir, service => 'mcp'});
  for my $n (1 .. 3) {
    my ($ok, $err) = await($up->start_p);
    ok $ok, "start $n" or diag $err;
    ok echo_ok($up), "start $n: it answers";
    stop_and_settle($up);
  }
  my $calls = calls_since($fake, $before);
  my @hub   = @{commands($fake, $calls)};
  ok grep({/already runs/} @LOG), 'the hub says it found it running';
  ok !(grep {/^compose (?:up|stop|down|rm|kill|restart|create)\b/} @hub), 'no up, which could recreate it, and no stop';
  ok !(grep {/^(?:stop|rm|kill) /} @hub), 'nor a stop or rm of its container';
  is_deeply [map { $_->{id} } @{running($fake)}], [$theirs->{id}], 'the very same container still runs';
  my @waits = map { $_->{pid} } grep { $_->{argv}[0] eq 'wait' } @$calls;
  is scalar @waits, 3, 'each start watched it';
  ok wait_until(sub { !grep { kill 0, $_ } @waits }), 'and each stop ended that watch';

  # When compose cannot say whether it runs, the hub starts nothing -- and so
  # has nothing it could later stop.
  fail_with($fake, '^compose ps --status', err => 'unknown flag: --status');
  $before = scalar @{calls($fake)};
  my $blind = upstream($fake, {compose => $dir, service => 'mcp'}, name => 'blind');
  my ($ok, $err) = await($blind->start_p);
  ok !$ok, 'a compose ps that fails fails the start';
  like $err, qr/cannot tell whether service mcp already runs in \Q$dir\E -- docker compose ps: unknown flag: --status/,
    'saying why';
  stop_and_settle($blind);
  ok !(grep {/^compose (?:up|stop)\b/} @{commands($fake, calls_since($fake, $before))}), 'no up, and no stop';
  is_deeply [map { $_->{id} } @{running($fake)}], [$theirs->{id}], 'their service still runs';

  system("cd '$dir' && '$fake->{command}' compose stop mcp >/dev/null 2>&1");
};

subtest 'compose stdio: the image and what the service depends on are ready before the handshake' => sub {
  my $fake = fake_docker(registry => {'t/tool' => {kind => 'stdio'}});
  my $dir  = compose_project(
    pulled => {image => 't/tool', 'x-kind' => 'stdio', 'x-pull-delay' => 6,
      depends_on => {db => {condition => 'service_started', required => \1}}},
    built => {build => {context => '.'}, 'x-kind' => 'stdio', 'x-build-delay' => 6},
    db    => {'x-kind' => 'idle'},
  );

  # A pull and a build that each take longer than the handshake may (6s against
  # 5s): done inside the handshake, either would time it out.
  my $pulled = upstream($fake, {compose => $dir, service => 'pulled'}, name => 'pulled', request_timeout => 5);
  my ($ok, $err) = await($pulled->start_p);
  ok $ok, 'a slow pull does not count against request_timeout' or diag $err;
  ok echo_ok($pulled), 'it answers';
  my @compose = grep {/^compose /} @{commands($fake)};
  is scalar @compose, 4, 'four compose commands';
  like $compose[0], qr/^compose config --format json$/,      'the project is read';
  like $compose[1], qr/^compose pull pulled$/,               'the missing image is pulled';
  like $compose[2], qr/^compose up -d --no-recreate db$/,    'what it depends on is started';
  like $compose[3], qr/^compose run --rm -T .* pulled$/,     'and only then is it run';
  stop_and_settle($pulled);

  my $before = scalar @{calls($fake)};
  ($ok, $err) = await($pulled->start_p);
  ok $ok, 'started again' or diag $err;
  ok !(grep {/^compose pull/} @{commands($fake, calls_since($fake, $before))}), 'with no pull: the image is there';
  stop_and_settle($pulled);

  my $built = upstream($fake, {compose => $dir, service => 'built'}, name => 'built', request_timeout => 5);
  ($ok, $err) = await($built->start_p);
  ok $ok, 'a slow build does not count against it either' or diag $err;
  ok grep({ $_ eq 'compose build built' } @{commands($fake)}), 'the image was built first';
  stop_and_settle($built);

  ok grep({ $_->{labels}{'com.docker.compose.service'} eq 'db' } @{running($fake)}),
    'the dependency is left running, as compose run leaves it';
  system("cd '$dir' && '$fake->{command}' compose stop db >/dev/null 2>&1");
};

subtest 'compose: a dependency that exists is never recreated, stopped or restarted' => sub {
  my $fake = fake_docker;
  my $port = [{target => 8080, published => '0', protocol => 'tcp'}];
  my $deps = {db => {condition => 'service_started', required => \1}, cache => {condition => 'service_started', required => \1}};
  my %svc  = (
    mcp   => {'x-kind' => 'http', ports => $port, depends_on => $deps},
    tool  => {'x-kind' => 'stdio', depends_on => $deps},
    db    => {'x-kind' => 'idle', environment => {DB_PASSWORD => 'secret'}},
    cache => {'x-kind' => 'idle'},
  );
  my $dir = compose_project(%svc);
  my $by_service = sub { return {map { ($_->{labels}{'com.docker.compose.service'} // '') => $_ } @{records($fake)}} };

  # The user's: db runs, cache exists but is stopped.
  system("cd '$dir' && '$fake->{command}' compose up -d db cache >/dev/null 2>&1") == 0 or fail 'cannot bring db up';
  system("cd '$dir' && '$fake->{command}' compose stop cache >/dev/null 2>&1");
  my ($db, $cache) = map { $by_service->()->{$_}{id} } qw(db cache);

  # Since then the file says something else of both: what a DB_PASSWORD from
  # the user's shell, which the hub's environment lacks, or an edit does.
  $svc{db}{environment}{DB_PASSWORD} = '';
  $svc{cache}{'x-rev'} = 2;
  Mojo::File->new($dir, 'fake-compose.json')->spew(encode_json({name => 'k21proj', services => \%svc}));
  my $before = scalar @{calls($fake)};

  for my $service (qw(mcp tool)) {
    my $up = upstream($fake, {compose => $dir, service => $service}, name => $service);
    ok echo_ok($up), "$service answers";
    stop_and_settle($up);
    my $now = $by_service->();
    is $now->{db}{id},    $db,       "$service: the running dependency is the same container, not recreated";
    is $now->{db}{state}, 'running', "$service: and it still runs";
    is $now->{cache}{id}, $cache,    "$service: the stopped one was started as it was, not recreated";
  }
  my @hub = @{commands($fake, calls_since($fake, $before))};
  is_deeply [grep {/^compose (?:stop|rm|down|restart|kill)\b/} @hub], ['compose stop mcp'],
    'nothing but the service itself was ever stopped';
  ok !(grep { /^compose (?:up|run)\b/ && !/--no-recreate|--no-deps/ } @hub), 'every up and run said so';
  system("cd '$dir' && '$fake->{command}' compose stop db cache >/dev/null 2>&1");
};

subtest 'compose: what the service waits for is ready before the handshake' => sub {
  my @unhandled;
  local $SIG{__WARN__} = sub ($w) { $w =~ /Unhandled rejected promise/ ? push @unhandled, $w : warn $w };
  my $fake  = fake_docker;
  my $port  = [{target => 8080, published => '0', protocol => 'tcp'}];
  my %needs = (db => {condition => 'service_healthy', required => \1},
    migrate => {condition => 'service_completed_successfully', required => \1});
  my $dir = compose_project(
    tool    => {'x-kind' => 'stdio', depends_on => \%needs},
    mcp     => {'x-kind' => 'http', ports => $port, depends_on => \%needs},
    db      => {'x-kind' => 'idle', healthcheck => {test => ['CMD', 'true']}, 'x-healthy-after' => 7},
    migrate => {'x-kind' => 'oneshot', 'x-runtime' => 6},
  );

  # A database healthy after 7s and a migration done after 6s, against a
  # handshake that may take 5s: waited for inside it, either times it out.
  for my $service (qw(tool mcp)) {
    my $before = scalar @{calls($fake)};
    my $up = upstream($fake, {compose => $dir, service => $service}, name => $service, request_timeout => 5);
    my ($ok, $err) = await($up->start_p, 60);
    ok $ok, "$service: a slow dependency does not count against request_timeout" or diag $err;
    ok echo_ok($up), "$service answers";
    stop_and_settle($up);
    my @compose = grep {/^compose /} @{commands($fake, calls_since($fake, $before))};
    if ($service eq 'tool') {
      is $compose[1], 'compose up -d --no-recreate db migrate', 'tool: what it depends on is started';
      like $compose[2], qr/^compose ps -a --format json /, 'tool: and waited for';
      my ($run) = grep {/^compose run /} @compose;
      like $run, qr/^compose run --rm -T --no-deps /, 'tool: then it is run, without its dependencies';
    }
    system("cd '$dir' && '$fake->{command}' compose stop db >/dev/null 2>&1");    # slow again
  }

  # A dependency that will never do: the start fails, saying which and why,
  # and the service is not run.
  my $bad = compose_project(
    a       => {'x-kind' => 'stdio', depends_on => {migrate => {condition => 'service_completed_successfully'}}},
    b       => {'x-kind' => 'stdio', depends_on => {sick => {condition => 'service_healthy'}}},
    c       => {'x-kind' => 'stdio', depends_on => {plain => {condition => 'service_healthy'}}},
    migrate => {'x-kind' => 'oneshot', 'x-exit' => 3},
    sick    => {'x-kind' => 'idle', healthcheck => {test => ['CMD', 'false']}, 'x-health' => 'unhealthy'},
    plain   => {'x-kind' => 'idle'},
  );
  my %why = (
    a => qr/migrate, which a needs to complete, exited with code 3/,
    b => qr/sick, which b needs to be healthy, is unhealthy/,
    c => qr/plain has no healthcheck, but c needs it to be healthy/,
  );
  for my $service (sort keys %why) {
    my ($ok, $err) = await(upstream($fake, {compose => $bad, service => $service}, name => $service)->start_p, 30);
    ok !$ok, "$service: no start";
    like $err, $why{$service}, "$service: saying why";
  }
  ok !(grep { $_->{cwd} eq $bad && $_->{argv}[1] eq 'run' } @{calls($fake)}), 'none of them was run';
  system("cd '$bad' && '$fake->{command}' compose stop sick plain >/dev/null 2>&1");

  # A stop while it waits is heeded at once.
  my $slow = compose_project(
    tool => {'x-kind' => 'stdio', depends_on => {db => {condition => 'service_healthy'}}},
    db   => {'x-kind' => 'idle', healthcheck => {test => ['CMD', 'true']}, 'x-healthy-after' => 60},
  );
  my $up      = upstream($fake, {compose => $slow, service => 'tool'}, name => 'tool');
  my $start   = $up->start_p;
  my ($ok, $err);
  $start->then(sub { $ok = 1 }, sub ($e) { $err = $e });
  ok wait_until(sub { grep { $_->{cwd} eq $slow && "@{$_->{argv}}" =~ /^compose ps -a/ } @{calls($fake)} }), 'it waits';
  my $t0 = time;
  $up->stop;
  ok wait_until(sub { defined $err || $ok }, 10), 'the start ends';
  like $err // '', qr/stopped while starting/, 'as stopped';
  ok time - $t0 < 5, 'at once, not when the database is healthy';
  is $up->state, 'stopped', 'and the upstream is stopped';
  ok !(grep { $_->{cwd} eq $slow && $_->{argv}[1] eq 'run' } @{calls($fake)}), 'without running the service';
  system("cd '$slow' && '$fake->{command}' compose stop db >/dev/null 2>&1");

  # A compose that does not know a flag the hub uses: a word on which it needs.
  fail_with($fake, '^compose up', err => 'unknown flag: --no-recreate');
  ($ok, $err) = await(upstream($fake, {compose => $dir, service => 'tool'}, name => 'old')->start_p);
  like $err, qr/unknown flag: --no-recreate -- the hub needs Docker Compose 2 or later/, 'an old compose is named as such';
  is_deeply \@unhandled, [], 'a wait that fails or is stopped leaves no promise rejection unhandled';
};

subtest 'compose: the manifest hash' => sub {
  my $fake = fake_docker;
  my $dir  = compose_project(%SERVICES);
  my $base = upstream($fake, {compose => $dir, service => 'mcp', env => {A => 1}})->_hash;
  is upstream($fake, {compose => $dir, service => 'mcp', env => {A => 2}})->_hash, $base, 'env is not hashed';
  isnt upstream($fake, {compose => $dir, service => 'tool'})->_hash, $base, 'the service is';
  isnt upstream($fake, {compose => $dir, service => 'mcp', port => 8080})->_hash, $base, 'the port is';
  isnt upstream($fake, {compose => "$dir/..", service => 'mcp'})->_hash, $base, 'the directory is';
  isnt upstream($fake, {compose => $dir, service => 'mcp', path => '/rpc'})->_hash, $base, 'the path is';
  isnt upstream($fake, {compose => $dir, service => 'mcp', type => 'sse'})->_hash, $base, 'the type is';
  isnt upstream($fake, {compose => $dir, service => 'mcp', stdio => \1})->_hash, $base, '"stdio" is';
};

done_testing;
