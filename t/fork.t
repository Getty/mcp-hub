#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;

plan skip_all => 'forked class workers need Linux (/proc/self/fd)' unless -d '/proc/self/fd';

use Test::Mojo;
use Mojo::File    qw(curfile tempdir);
use Mojo::Log;
use Mojo::Promise;
use MCP::Client;
use MCP::Hub;

use lib curfile->sibling('lib')->to_string;

# Workers are forks of this very process, so they inherit its END blocks --
# Test::More's among them. This one stands for all of them: it leaves a mark
# when it runs anywhere but here.
my $HUB_PID = $$;
my $MARKS   = tempdir;
END { $MARKS->child("end-ran-in-$$")->spurt('1') if $$ != $HUB_PID }

# A class whose constructor works in the hub and dies in a worker.
package WorkerDies {
  use Mojo::Base 'EchoServer', -signatures;
  sub new ($class, @args) {
    die "no wiki at /nowhere\n" if $0 =~ /^mcp-hub-worker/;
    return $class->SUPER::new(@args);
  }
}

my @LOG;
sub hub ($servers) {
  my $log = Mojo::Log->new(level => 'debug');
  $log->unsubscribe('message')->on(message => sub ($l, $level, @lines) { push @LOG, "$level: @lines" });
  my $cache = tempdir;
  return MCP::Hub->new(log => $log, hub_config_input => {mcpServers => $servers, hub => {cache_dir => "$cache"}});
}

sub client ($t, $path) {
  my $base = $t->ua->server->url->to_string;
  $base =~ s{/$}{};
  return MCP::Client->new(ua => $t->ua, url => "$base$path");
}

sub forked ($class, %hub) { return {class => $class, hub => {fork => \1, %hub}} }

sub wait_until ($cond, $timeout = 5) {
  my $deadline = time + $timeout;
  Mojo::Promise->timer(0.05)->wait until $cond->() || time > $deadline;
  return $cond->();
}

sub fds ($pid) {
  opendir my $dh, "/proc/$pid/fd" or return {};
  my %links = map { my $l = readlink "/proc/$pid/fd/$_"; defined $l ? ($_ => $l) : () } grep {/^\d+$/} readdir $dh;
  return \%links;
}

sub sockets ($pid) { return {map { /^socket:\[(\d+)\]$/ ? ($1 => 1) : () } values %{fds($pid)}} }

sub proc_status ($pid, $field) {
  open my $fh, '<', "/proc/$pid/status" or return undef;
  while (<$fh>) { return $1 if /^\Q$field\E:\s+(\S+)/ }
  return undef;
}

# The inode of the socket listening on $port, from the kernel's own table.
sub listen_inode ($port) {
  my $hex = sprintf '%04X', $port;
  for my $file ('/proc/net/tcp', '/proc/net/tcp6') {
    open my $fh, '<', $file or next;
    while (<$fh>) {
      my @f = split ' ';
      return $f[9] if ($f[1] // '') =~ /:$hex$/ && ($f[3] // '') eq '0A';
    }
  }
  return undef;
}

sub text ($res) { return $res->{content}[0]{text} // '' }

# ---------------------------------------------------------------------------

my $app = hub({
  probe           => forked('ForkProbe'),
  composed        => forked('ComposedEcho'),
  probe_inproc    => {class => 'ForkProbe'},
  composed_inproc => {class => 'ComposedEcho'},
  idle            => forked('EchoServer', idle_timeout => 1),
  dies            => forked('WorkerDies'),
  threads         => forked('EchoServer'),
  needs_hub       => forked('MCP::Hub::Native::Status'),
  not_a_server    => forked('Mojo::Collection'),
  plain_not       => {class => 'Mojo::Collection'},
});
my $t  = Test::Mojo->new($app);
my %up = %{$app->upstreams_by_name};

subtest 'a forked class is listed without a process' => sub {
  for my $name (qw(probe composed)) {
    is $up{$name}->type,  'fork',    "$name is a fork upstream";
    is $up{$name}->state, 'stopped', "$name is stopped after startup";
    is $up{$name}->stats->{pid}, undef, "$name has no worker";
    ok $up{$name}->manifest_fetched_at, "$name has its manifest from the class";
  }

  for my $name (qw(probe composed)) {
    my $forked = client($t, "/$name")->list_tools->{tools};
    my $inproc = client($t, "/${name}_inproc")->list_tools->{tools};
    ok scalar @$forked >= 6, "$name lists its tools";
    is_deeply [sort { $a->{name} cmp $b->{name} } @$forked], [sort { $a->{name} cmp $b->{name} } @$inproc],
      "$name lists exactly what the class renders in process";
  }

  my ($echo) = grep { $_->{name} eq 'echo' } @{client($t, '/probe')->list_tools->{tools}};
  is $echo->{title}, 'Echo', 'the title rides along';
  is $echo->{_meta}{'anthropic/maxResultSizeChars'}, 1234, 'and so does _meta';

  is client($t, '/probe')->discover->{instructions}, 'Echo things back.', 'the instructions are there';
  is_deeply [map { $_->{name} } @{client($t, '/probe')->list_prompts->{prompts}}], ['greet'], 'prompts listed';
  is_deeply [map { $_->{uri} } @{client($t, '/probe')->list_resources->{resources}}], ['echo://readme'],
    'resources listed';

  my $all = {map { $_->{name} => 1 } @{client($t, '/all')->list_tools->{tools}}};
  ok $all->{probe__whoami}, 'the forked class is in /all';

  is $up{$_}->stats->{pid}, undef, "listing forked nothing for $_" for qw(probe composed);
};

subtest 'a call runs in a worker forked from the hub' => sub {
  my $c   = client($t, '/probe');
  my $who = $c->call_tool('whoami', {})->{structuredContent};
  isnt $who->{pid}, $$, 'the worker is a process of its own';
  is $who->{ppid}, $$, 'forked from the hub';
  is $who->{name}, 'mcp-hub-worker probe', 'and named after its entry';
  is $up{probe}->stats->{pid}, $who->{pid}, 'the status shows the worker';
  is $up{probe}->state, 'ready', 'which is ready';

  is text($c->call_tool('echo', {msg => 'through a worker'})), 'through a worker', 'echo answers';
  is text($c->call_tool('sleep', {seconds => 0.2})), 'slept 0.2', 'a promise is waited for in the worker';
  is $c->call_tool('whoami', {})->{structuredContent}{pid}, $who->{pid}, 'calls share the one worker';

  my $prompt = $c->get_prompt('greet', {who => 'fork'});
  is $prompt->{messages}[0]{content}{text}, 'Hello, fork!', 'prompts/get through the worker';

  my $row = $up{probe}->status_row;
  is $row->{type}, 'fork', 'the status row says fork';
  ok $row->{pss_kb} && $row->{pss_kb} > 0, "and carries pss_kb ($row->{pss_kb})";

  my $composed = client($t, '/composed')->call_tool('echo', {msg => 'option (a)'});
  is text($composed), 'option (a)', 'a class with a server method runs forked too';
};

subtest 'the worker holds nothing of the hub' => sub {
  my $pid = $up{probe}->stats->{pid} or return fail 'no worker';

  my $inode = listen_inode($t->ua->server->url->port);
  ok $inode, 'found the socket the hub listens on';
  ok sockets($$)->{$inode}, 'the hub holds it';
  ok !sockets($pid)->{$inode}, 'the worker does not';

  my $hub    = sockets($$);
  my @shared = grep { $hub->{$_} } keys %{sockets($pid)};
  is_deeply \@shared, [], 'the worker shares no socket with the hub';

  my $links = fds($pid);
  my @kept  = grep { $_ > 2 && $links->{$_} ne '/dev/null' && !-f "/proc/$pid/fd/$_" } sort keys %$links;
  is_deeply [map {"$_ -> $links->{$_}"} @kept], [], 'every other fd is /dev/null or a reopened file';

  like proc_status($pid, 'SigCgt'), qr/^0+$/, 'the worker catches no signal';
  ok hex(substr(proc_status($pid, 'SigIgn'), -1)) & 1, 'and ignores HUP';
  # The control for the line above: only libev installs signal handlers of its own.
  like proc_status($$, 'SigCgt'), qr/[1-9a-f]/, 'while the hub still has its handlers'
    if Mojo::IOLoop->singleton->reactor->isa('Mojo::Reactor::EV');

  # Mojo lists the hub's listening sockets in MOJO_REUSE, by fd -- fds that are
  # /dev/null in the worker.
  my $port = $t->ua->server->url->port;
  like $ENV{MOJO_REUSE}, qr/(?:^|,)127\.0\.0\.1:$port:\d+(?:,|$)/, 'the hub has its listener in MOJO_REUSE';
  my $env = client($t, '/probe')->call_tool('getenv', {name => 'MOJO_REUSE'})->{structuredContent};
  ok !$env->{set}, 'the worker has no MOJO_REUSE' or diag "MOJO_REUSE=$env->{value}";
  is $up{probe}->stats->{pid}, $pid, 'as the same worker tells';
};

# libev's default loop reaps every child itself, at top priority, as soon as
# SIGCHLD is in: the hub's waitpid then finds nothing and the exit reads
# "unknown" -- a race the hub has with every child, under EV only. The two
# subtests that look at a worker's exit status keep libev out of it.
subtest 'exit in class code runs none of the hub END blocks' => sub {
  local $SIG{CHLD} = 'DEFAULT';
  my $c   = client($t, '/probe');
  my $pid = $c->call_tool('whoami', {})->{structuredContent}{pid};

  my $res = $c->call_tool('exit', {code => 7});
  ok $res->{isError}, 'the call fails';
  like text($res), qr/exited \(code 7\)/, 'with the status the class exited with';
  ok wait_until(sub { !kill 0, $pid }), 'the worker is gone';
  is_deeply [map { $_->basename } $MARKS->list->each], [], 'and no END block of the hub ran in it';

  my $again = $c->call_tool('whoami', {})->{structuredContent}{pid};
  ok $again && $again != $pid, 'the next call forks a new worker';
};

subtest 'an idle worker is stopped, the next call forks again' => sub {
  my $c = client($t, '/idle');
  is text($c->call_tool('echo', {msg => 'one'})), 'one', 'first call';
  my $pid = $up{idle}->stats->{pid};
  ok $pid, 'a worker runs';

  ok wait_until(sub { $up{idle}->state eq 'stopped' }, 5), 'stopped after idle_timeout';
  is $up{idle}->stats->{pid}, undef, 'no worker in the status';
  ok wait_until(sub { !kill 0, $pid }), 'and the process is gone';
  ok scalar @{client($t, '/idle')->list_tools->{tools}}, 'tools/list still answers';
  is $up{idle}->stats->{pid}, undef, 'without forking';

  is text($c->call_tool('echo', {msg => 'two'})), 'two', 'the next call answers';
  ok $up{idle}->stats->{pid} && $up{idle}->stats->{pid} != $pid, 'from a new worker';
};

subtest 'a constructor that dies in the worker is reported' => sub {
  local $SIG{CHLD} = 'DEFAULT';
  @LOG = ();
  is $up{dies}->state, 'stopped', 'the class built in the hub';
  my $res = client($t, '/dies')->call_tool('echo', {msg => 'x'});
  ok $res->{isError}, 'the call fails';
  like text($res), qr/exited \(code 3\)/, 'the worker exited with 3';
  ok scalar(grep {/child exited \(code 3\) while starting WorkerDies: worker failed: no wiki at \/nowhere/} @LOG),
    "the log says why (@{[ (grep {/child exited/} @LOG)[0] // 'nothing logged' ]})";
};

subtest 'a hub running threads forks nothing' => sub {
  no warnings 'redefine';
  local *MCP::Hub::Upstream::Fork::_thread_count = sub ($self) {2};
  my $c = client($t, '/threads');

  for my $n (1 .. 3) {
    my $res = $c->call_tool('echo', {msg => 'x'});
    like text($res), qr/cannot fork a worker for EchoServer: the hub runs 2 threads/, "refused ($n)";
  }
  is $up{threads}->stats->{pid}, undef, 'no worker';
  is $up{threads}->state, 'failed', 'three refusals are a crash loop';
  $t->post_ok('/threads', json => {jsonrpc => '2.0', id => 1, method => 'tools/call',
    params => {name => 'echo', arguments => {msg => 'x'}}})->status_is(503)
    ->json_like('/error', qr/upstream 'threads' failed: cannot fork a worker for EchoServer: the hub runs 2 threads/);
  ok !$up{threads}->placeholder, 'the upstream and its facade are kept';
  ok scalar(grep { $_->{name} eq 'threads__echo' } @{client($t, '/all')->list_tools->{tools}}),
    'its tools are still listed in /all';
  like text(client($t, '/all')->call_tool('threads__echo', {msg => 'x'})),
    qr/the hub runs 2 threads, run 'mcp-hub refresh threads' to try again/, 'where a call says what to do';
};

subtest 'a refresh ends the crash loop' => sub {
  my $up = $up{threads};
  my $ok;
  $up->refresh_p->then(sub { $ok = 1 })->catch(sub ($err) { diag $err })->wait;
  ok $ok, 'refreshed';
  is $up->state, 'ready', 'ready again';
  ok $up->stats->{pid}, 'with a worker';
  is text(client($t, '/threads')->call_tool('echo', {msg => 'back'})), 'back', 'which answers';
};

subtest 'a class that cannot be forked stays visible as failed' => sub {
  is $up{needs_hub}->state, 'failed', 'a class with a hub attribute is refused';
  like $up{needs_hub}->error, qr/MCP::Hub::Native::Status needs the live hub \(it has a 'hub' attribute\)/,
    'saying why';
  ok $up{needs_hub}->placeholder, 'as a placeholder';
  $t->post_ok('/needs_hub', json => {jsonrpc => '2.0', id => 1, method => 'tools/list'})->status_is(503)
    ->json_like('/error', qr/needs the live hub/);

  for my $name (qw(not_a_server plain_not)) {
    is $up{$name}->state, 'failed', "$name: a class that is no server is refused";
    like $up{$name}->error,
      qr/Mojo::Collection is neither an MCP::Server subclass nor has a 'server' method returning one/, 'saying why';
  }
};

subtest 'option (a) in process' => sub {
  is $up{composed_inproc}->type, 'perl', 'a plain class entry';
  is text(client($t, '/composed_inproc')->call_tool('echo', {msg => 'in process'})), 'in process',
    'a class with a server method is mounted in process';
  is $up{composed_inproc}->stats->{pid}, undef, 'with no process';
};

subtest 'shutdown stops every worker' => sub {
  is text(client($t, '/composed')->call_tool('echo', {msg => 'x'})), 'x', 'a call';
  my $pid = $up{composed}->stats->{pid};
  ok $pid, 'leaves a worker running';
  $app->shutdown_p->wait;
  ok wait_until(sub { !kill 0, $pid }), 'and is gone after shutdown';
  is $up{$_}->stats->{pid}, undef, "$_ has no worker" for qw(probe composed idle);
};

is_deeply [map { $_->basename } $MARKS->list->each], [], 'no worker ever ran an END block of the hub';

done_testing;
