#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File    qw(curfile tempdir);
use Mojo::Log;
use Mojo::IOLoop;
use Mojo::Promise;
use MCP::Hub::Upstream::Stdio;
use POSIX ();
use Time::HiRes ();

my $ECHO = curfile->sibling('upstream', 'echo.pl');

# The crash-loop window for the subtests that count exits. Each cycle spawns
# perl, loads Mojolicious and runs the handshake; on a busy machine three of
# them do not fit into the default five seconds. These subtests are about the
# count, not about how fast the machine is.
my $WINDOW = 60;

sub upstream (%config) {
  my $dir = tempdir;
  return MCP::Hub::Upstream::Stdio->new(
    name      => 'echo',
    config    => {type => 'stdio', command => $^X, args => ['-Ilib', "$ECHO"], %config},
    cache_dir => "$dir",
  );
}

sub _await ($promise) {
  my $out;
  $promise->then(sub { $out = shift })->catch(sub { $out = {err => shift} })->wait;
  return $out;
}

# A request that is never settled must fail the test instead of hanging it: the
# promise is raced against a timeout.
sub _await_bounded ($promise, $seconds = 5) {
  my $out;
  Mojo::Promise->race(Mojo::Promise->timeout($seconds), $promise)
    ->then(sub { $out = shift })->catch(sub { $out = {err => shift} })->wait;
  return $out;
}

# The text of an error result -- or '' when the call did not answer at all.
sub _error_text ($result) {
  return '' unless ref $result eq 'HASH';
  return '' unless ref $result->{content} eq 'ARRAY';
  return '' unless ref $result->{content}[0] eq 'HASH';
  return $result->{content}[0]{text} // '';
}

sub settle ($seconds = 0.2) { Mojo::Promise->timer($seconds)->wait }

# Whether a process has ended: it is gone, or it is a zombie. A process the
# child leaves behind is no child of the test's; once it exits, whatever it was
# handed to reaps it. Where that is a PID 1 that reaps nothing -- a container
# with no init, such as the GitHub Actions job container, whose PID 1 is
# `tail -f /dev/null` -- it stays a zombie, and kill 0 still finds it.
sub ended ($pid) {
  return 1 unless kill 0, $pid;
  open my $fh, '<', "/proc/$pid/stat" or return 0;
  my ($state) = (do { local $/; <$fh> } // '') =~ /.*\) (\S)/s;
  return ($state // '') =~ /^[ZX]$/ ? 1 : 0;
}

# A log that keeps its lines, "level message", instead of printing them.
sub log_to ($lines) {
  my $log = Mojo::Log->new;
  $log->unsubscribe('message');
  $log->on(message => sub ($l, $level, @msg) { push @$lines, "$level @msg" });
  return $log;
}

# An upstream around a perl one-liner instead of echo.pl.
sub oneliner ($name, $code, %attr) {
  return MCP::Hub::Upstream::Stdio->new(
    name      => $name,
    config    => {type => 'stdio', command => $^X, args => ['-e', $code]},
    cache_dir => tempdir->to_string,
    %attr,
  );
}

sub is_ev () { Mojo::IOLoop->singleton->reactor->isa('Mojo::Reactor::EV') }

# Whether this process catches SIGCHLD -- under EV, libev's handler, until
# something assigns $SIG{CHLD} and replaces it for good.
sub sigchld_caught () {
  open my $fh, '<', "/proc/$$/status" or return undef;
  while (<$fh>) { return (hex($1) >> (POSIX::SIGCHLD() - 1)) & 1 if /^SigCgt:\s+([0-9a-f]+)/ }
  return undef;
}

subtest 'handshake, manifest and echo' => sub {
  my $up = upstream;
  is $up->state, 'stopped', 'starts stopped';

  _await($up->start_p);
  is $up->state, 'ready', 'ready after handshake';
  ok $up->stats->{pid}, 'has a pid';

  my @tools = map { $_->name } @{$up->server->tools};
  is_deeply [sort @tools], [sort qw(echo sleep fail die exit notify slow_lists)], 'all tools listed';

  my ($prompt) = @{$up->server->prompts};
  is $prompt->name, 'greet', 'prompt listed';
  my ($resource) = @{$up->server->resources};
  is $resource->uri, 'echo://readme', 'resource listed';

  my $r = _await($up->call_tool('echo', {msg => 'hi'}));
  is $r->{content}[0]{text}, 'hi', 'echo result forwarded';
  ok !${$r->{isError}}, 'not an error';

  my $pr = _await($up->get_prompt('greet', {who => 'world'}));
  like $pr->{messages}[0]{content}{text}, qr/Hello, world/, 'prompt forwarded';

  my $rr = _await($up->read_resource('echo://readme'));
  like $rr->{contents}[0]{text}, qr/echo server/, 'resource forwarded';

  $up->stop;
  settle;
  is $up->state, 'stopped', 'stopped after stop';
};

subtest 'lazy start from a cached manifest' => sub {
  my $dir = tempdir;
  my %args = (
    name      => 'echo',
    config    => {type => 'stdio', command => $^X, args => ['-Ilib', "$ECHO"]},
    cache_dir => "$dir",
  );

  # First instance fetches and caches, then stops.
  my $first = MCP::Hub::Upstream::Stdio->new(%args);
  _await($first->start_p);
  $first->stop;
  settle;

  # Second instance sees the same cache dir: tools are known, nothing spawned.
  my $second = MCP::Hub::Upstream::Stdio->new(%args);
  is $second->state, 'stopped', 'still stopped';
  is $second->stats->{pid}, undef, 'no process spawned';
  ok scalar(@{$second->server->tools}) >= 6, 'tools populated from cache';
};

subtest 'error results' => sub {
  my $up = upstream;

  my $fail = _await($up->call_tool('fail', {}));
  ok ${$fail->{isError}}, 'fail is an error result';
  is $fail->{content}[0]{text}, 'deliberate failure', 'error text passed through';

  my $die = _await($up->call_tool('die', {}));
  ok ${$die->{isError}}, 'die becomes an error result';
  like $die->{content}[0]{text}, qr/^upstream echo:/, 'error is attributed to the upstream';

  $up->stop;
  settle;
};

subtest 'a non-object error is reported, not swallowed' => sub {
  # An upstream that answers "error": "text" or "error": [..] -- shapes that
  # are out there in the wild. Reading ->{message} from them dies under strict
  # refs, and the request it belongs to then stays pending forever. The bound
  # only stands in for "forever": spawn, handshake and call get 30 seconds, so
  # that a loaded machine cannot trip it, and a swallowed error still fails --
  # within the bound and before the request's own 60-second timeout.
  for my $shape (qw(string array)) {
    my $up = upstream(args => ['-Ilib', "$ECHO", "--bad-error=$shape"]);
    my $r  = _await_bounded($up->call_tool('boom', {}), 30);
    ok $r->{isError}, "$shape error is an error result" or diag explain $r;
    like _error_text($r), qr/^upstream echo:/, "$shape error names the upstream";
    like _error_text($r), qr/nope/, "$shape error carries the upstream message";
    $up->stop;
    settle;
  }
};

subtest 'request timeout' => sub {
  my $up = upstream(request_timeout => 1);
  my $r  = _await($up->call_tool('sleep', {seconds => 5}));
  ok ${$r->{isError}}, 'timeout is an error result';
  like $r->{content}[0]{text}, qr/timed out after 1s/, 'timeout message';
  $up->stop;
  settle;
};

# Every message the upstream sent its child while $code ran, as it went out.
sub sends_during ($code) {
  my @sent;
  no warnings 'redefine';
  my $send = \&MCP::Hub::Upstream::Stdio::_send;
  local *MCP::Hub::Upstream::Stdio::_send = sub ($self, $obj) {
    my $sent = $send->($self, $obj);
    push @sent, $obj if $sent;
    return $sent;
  };
  $code->();
  return \@sent;
}

sub cancels_in ($sent) {
  return [map { $_->{params} } grep { ($_->{method} // '') eq 'notifications/cancelled' } @$sent];
}

subtest 'a request that times out is cancelled with its reason -- never the initialize' => sub {
  # Every request that timed out was cancelled on the child, the initialize
  # too, which a client must not cancel (MCP 2025-06-18, Cancellation); and the
  # cancel did not say why, as it does over HTTP. Seen as the hub sends it: a
  # start that fails kills its child, which may die before it reads a line.
  # The call's child is started first, so that its initialize, slow on a busy
  # machine, is not the request that times out.
  my $up = upstream();
  is _await_bounded($up->start_p->then(sub { 'started' }), 30), 'started', 'started';
  $up->request_timeout(1);
  my $r;
  my $sent = sends_during(sub { $r = _await_bounded($up->call_tool('sleep', {seconds => 5}), 10) });
  is _error_text($r), 'upstream echo: timed out after 1s', 'a call times out';
  my ($call) = grep { ($_->{method} // '') eq 'tools/call' } @$sent;
  is_deeply cancels_in($sent), [{requestId => $call->{id}, reason => 'timed out after 1s'}],
    'and is cancelled, once, with the reason it failed with';
  $up->stop;

  my $mute = oneliner('mute', 'sleep 30', request_timeout => 1, log => log_to([]));
  $sent = sends_during(sub { $r = _await_bounded($mute->start_p, 10) });
  is ref $r eq 'HASH' ? $r->{err} : 'ready', 'upstream mute: timed out after 1s', 'an initialize times out';
  is_deeply [map { $_->{method} } @$sent], ['initialize'], 'and is not cancelled';
  $mute->stop;
  _await_bounded($_->stopped_p, 10) for $up, $mute;
};

subtest 'crash mid-call and restart' => sub {
  my $up = upstream;
  my $r  = _await($up->call_tool('exit', {}));
  ok ${$r->{isError}}, 'crash is an error result';
  like $r->{content}[0]{text}, qr/exited \(code 0\)/, 'exit reason reported';
  is $up->state, 'stopped', 'stopped after crash';

  my $r2 = _await($up->call_tool('echo', {msg => 'again'}));
  is $r2->{content}[0]{text}, 'again', 'restarted on the next call';
  is $up->state, 'ready', 'ready again';
  $up->stop;
  settle;
};

subtest 'a line over 16MB: the child is killed, once, and the next one starts clean' => sub {
  # The answer to this call is one line of 17MB. The child is killed for it;
  # what it sent after the limit used to go on piling up in the buffer -- and
  # being reported, and killed for, again with every read -- and the next
  # child got that buffer: killed on its first answer.
  my @lines;
  my $up = upstream(request_timeout => 30);    # room for 17MB, under load
  $up->log(log_to(\@lines));
  is _error_text(_await_bounded($up->call_tool('echo', {msg => 'before'}), 30)), 'before', 'it answers';

  my $r = _await_bounded($up->call_tool('echo', {msg => 'x' x (17 * 1024 * 1024)}), 60);
  ok $r->{isError}, 'the call whose answer is too long fails';
  like _error_text($r), qr/exited \(signal 9\)/, 'as the child is killed';
  is scalar(grep {/line buffer exceeded 16MB, killing child/} @lines), 1, 'which is reported once'
    or diag explain [grep {/16MB/} @lines];

  my $next = _await_bounded($up->call_tool('echo', {msg => 'after'}), 30);
  is _error_text($next), 'after', 'the next call is answered, by a new child' or diag explain $next;
  is scalar(grep {/line buffer exceeded 16MB/} @lines), 1, 'which nothing was left over for';
  $up->stop;
  settle;
};

subtest 'a child killed in the middle of a line leaves nothing for the next one' => sub {
  # It is killed half-way through its answer. What it got out stayed in the
  # buffer, in front of the next child's first line -- the answer to its
  # initialize, which then did not parse: the start waited for it until the
  # request timed out.
  my @lines;
  my $up  = upstream(args => ['-Ilib', "$ECHO", '--die-mid-line'], request_timeout => 10);
  my $log = log_to(\@lines);
  $log->level('debug');    # where a line that does not parse is reported
  $up->log($log);

  my $r = _await_bounded($up->call_tool('cut', {}), 30);
  like _error_text($r), qr/exited \(signal 9\)/, 'the call fails as the child is killed mid-line';
  my $next = _await_bounded($up->call_tool('echo', {msg => 'intact'}), 30);
  is _error_text($next), 'intact', 'the next child answers the next call' or diag explain $next;
  is_deeply [grep {/malformed/} @lines], [], 'its first line arrived whole';
  $up->stop;
  settle;
};

subtest 'failed after three quick exits' => sub {
  my $up = upstream()->fail_window($WINDOW);
  _await($up->call_tool('exit', {})) for 1 .. 3;
  is $up->state, 'failed', 'three exits within the window mark it failed';
  is $up->error, "3 exits within ${WINDOW}s", 'the error names the count and the window';
  $up->stop;
  settle;
};

subtest 'a child killed for a line over 16MB counts toward the crash loop' => sub {
  # A server that floods its stdout with no newline on every start. The kill
  # for it was taken for a deliberate stop: no exit was counted, and every call
  # spawned it again -- the crash loop never ended in `failed`.
  my @lines;
  my $up = oneliner('flood', q{$| = 1; print 'x' x (17 * 1024 * 1024); sleep 30}, fail_window => $WINDOW,
    request_timeout => 30);
  $up->log(log_to(\@lines));

  for my $n (1 .. 3) {
    my $r = _await_bounded($up->start_p, 30);
    like ref $r eq 'HASH' ? $r->{err} : 'started', qr/^upstream flood: exited \(signal 9\)/,
      "start $n fails as the child is killed";
  }
  is $up->state, 'failed', 'three such kills within the window mark it failed';
  is $up->error, "3 exits within ${WINDOW}s: line buffer exceeded 16MB", 'the error names the kill';
  is scalar(grep {/line buffer exceeded 16MB, killing child/} @lines), 3, 'each kill is logged';
  is_deeply [grep {/child exited/} @lines], [], 'and none of them as an exit as well';

  @lines = ();
  my $r = _await_bounded($up->call_tool('echo', {}), 5);
  like _error_text($r), qr/^upstream flood: 3 exits within ${WINDOW}s: line buffer exceeded 16MB, run /,
    'a call is answered with the reason' or diag explain $r;
  is_deeply [grep {/started/} @lines], [], 'and starts no child';
  $up->stop;
  settle;
};

subtest 'exits older than the window are forgotten' => sub {
  # The other side of the window, and safe under load: a busy machine only
  # makes the pause longer. Two exits, a pause past the one-second window, a
  # third exit -- only the third one is still inside, so this is no crash loop.
  my $up = upstream()->fail_window(1);
  _await($up->call_tool('exit', {})) for 1 .. 2;
  settle(2.1);
  _await($up->call_tool('exit', {}));
  is $up->state, 'stopped', 'stopped, not failed';
  is $up->error, undef, 'and no crash loop reported';
  $up->stop;
  settle;
};

subtest 'a child that dies at startup is counted once' => sub {
  # The child exits during the handshake: _on_close records the exit, and the
  # catch in start_p must not record it a second time. Counted twice, two
  # attempts would lock the upstream out -- and the stale stopping flag would
  # swallow the warning of the next exit.
  my @lines;
  my $log = Mojo::Log->new;
  $log->unsubscribe('message');
  $log->on(message => sub ($l, $level, @msg) { push @lines, "$level @msg" });

  my $up = MCP::Hub::Upstream::Stdio->new(
    name        => 'false',
    config      => {type => 'stdio', command => $^X, args => ['-e', 'exit 0']},
    cache_dir   => tempdir->to_string,
    fail_window => $WINDOW,
  );
  $up->log($log);

  for my $n (1 .. 2) {
    my $r = _await($up->start_p);
    ok $r->{err}, "attempt $n fails" or diag explain $r;
    is $up->state, 'stopped', "stopped after attempt $n -- one exit counted, not two";
    ok +(grep { /child exited/ } @lines), "attempt $n logs the exit" or diag explain \@lines;
    @lines = ();
  }

  my $r = _await($up->start_p);
  ok $r->{err}, 'the third attempt fails';
  is $up->state, 'failed', 'failed after the third attempt';

  $up->stop;
  settle;
};

# A peer that answers initialize -- with prompts and resources among its
# capabilities -- and tools/list, then exits: right after its answer to
# tools/list ('answered'), or once it is asked for its prompts
# ('prompts/list'). Any other $at, and it lists on; a tools/call has it close
# its stdin and stdout and live on, never to answer again.
my $BRIEF = <<~'CODE';
  use Mojo::JSON qw(decode_json encode_json);
  my $at = shift;
  $| = 1;
  while (my $line = <STDIN>) {
    my $msg = eval { decode_json($line) } // next;
    next unless defined $msg->{id};
    exit 0 if $msg->{method} eq $at;
    if ($msg->{method} eq 'tools/call') { close STDIN; close STDOUT; sleep 30; exit 0 }
    my $result = $msg->{method} eq 'initialize'
      ? {protocolVersion => '2025-06-18', serverInfo => {name => 'brief', version => '1'},
         capabilities => {tools => {}, prompts => {}, resources => {}}}
      : {tools => [{name => 'echo', inputSchema => {type => 'object'}}]};
    print encode_json({jsonrpc => '2.0', id => $msg->{id}, result => $result}), "\n";
    exit 0 if $msg->{method} eq 'tools/list' && $at eq 'answered';
  }
  CODE

sub brief ($at, %attr) {
  return MCP::Hub::Upstream::Stdio->new(
    name        => 'brief',
    config      => {type => 'stdio', command => $^X, args => ['-e', $BRIEF, $at]},
    cache_dir   => tempdir->to_string,
    fail_window => $WINDOW,
    log         => log_to([]),
    %attr,
  );
}

subtest 'a child that exits in the middle of the handshake fails the start' => sub {
  # It is gone before its prompts and resources are listed. A list it no
  # longer answered is taken for an empty one at a start, and so the start
  # came up ready with no child: no pid, and a call to it waited out the
  # request timeout. The start fails with its exit instead, and the exit
  # counts toward the crash loop -- once. The timeout only bounds a start that
  # never ends: 30 seconds, so that a loaded machine, where the child's start
  # and its answers take over a second, still sees the exit and not the timeout.
  for my $at ('answered', 'prompts/list') {
    my $up = brief($at, request_timeout => 30);
    for my $n (1 .. 3) {
      my $r = _await_bounded($up->start_p, 30);
      is ref $r eq 'HASH' ? $r->{err} : 'ready', 'upstream brief: exited (code 0)',
        "$at, attempt $n: the start fails with the exit";
      is $up->state, $n < 3 ? 'stopped' : 'failed', "$at, attempt $n: $n exit(s) counted";
      is $up->stats->{pid}, undef, "$at, attempt $n: no child";
    }
    is $up->error, "3 exits within ${WINDOW}s", "$at: the crash loop names the count";
  }
};

subtest 'a request with no stream to the child fails at once' => sub {
  # Unsent, it waited out the request timeout for an answer that cannot come
  # -- or, with the child still there, for its exit.
  my $up = brief('prompts/list', request_timeout => 30);
  my $t0 = time;
  my $r  = _await_bounded($up->start_p, 20);
  is ref $r eq 'HASH' ? $r->{err} : 'ready', 'upstream brief: exited (code 0)',
    'the start whose child is gone before its resources are listed fails';
  cmp_ok time - $t0, '<', 5, 'at once, not once that list has timed out';

  # The child closes its stdout and lives on; a refresh of it is not sent.
  $up = brief('none', request_timeout => 30);
  is _await_bounded($up->start_p, 30), $up, 'started';
  my $call     = $up->call_tool('echo', {});
  my $deadline = time + 10;
  settle(0.02) while $up->{stream} && time < $deadline;
  ok !$up->{stream}, 'its stdout is closed';
  ok $up->stats->{pid}, 'it is still there';
  my $t1      = Time::HiRes::time();
  my $refresh = _await_bounded($up->refresh_p, 20);
  is ref $refresh eq 'HASH' ? $refresh->{err} : 'through', 'upstream brief: not connected', 'the refresh fails';
  cmp_ok Time::HiRes::time() - $t1, '<', 1, 'at once';
  $up->stop;
  _await_bounded($up->stopped_p, 20);
  like _error_text(_await_bounded($call, 20)), qr/^upstream brief: exited/, 'the call fails as the child goes';
};

# These come before anything here assigns $SIG{CHLD}: the first one is about
# libev reaping children, and an assignment ends that for the whole process.
subtest 'the exit status is read under EV too' => sub {
  # The child exits at once; a child of its own holds the socket a second
  # longer. Under Mojo::Reactor::EV libev reaps the child as soon as SIGCHLD
  # is in, long before the socket closes, and a waitpid at the close came up
  # empty: this read "exited (unknown)" every time. Under Poll it is the
  # ordinary case.
  ok sigchld_caught(), 'libev reaps the children of this process' if is_ev() && -r "/proc/$$/status";
  my @lines;
  my $up = oneliner(forks => 'exit 5 if fork; sleep 1', log => log_to(\@lines));
  my $r  = _await_bounded($up->start_p, 30);
  is $r->{err}, 'upstream forks: exited (code 5)', 'the start fails with the code the child exited with';
  ok +(grep { $_ eq "warn [forks] child exited (code 5) while starting '$^X'" } @lines), 'and the log says it too'
    or diag explain \@lines;
  is $up->state, 'stopped', 'stopped';
};

subtest 'a child that closes its stdout and lives on does not block the loop' => sub {
  # Its socket closes two seconds before it exits. A blocking waitpid at the
  # close held the whole hub -- every other upstream, every request -- until
  # then.
  my $up    = oneliner(linger => 'close STDIN; close STDOUT; sleep 2; exit 4', log => log_to([]));
  my $start = $up->start_p;
  my $pid   = $up->stats->{pid};
  my $ticks = 0;
  my $tick  = Mojo::IOLoop->recurring(0.1 => sub { $ticks++ if kill 0, $pid });
  my $r     = _await_bounded($start, 30);
  Mojo::IOLoop->remove($tick);
  ok $ticks >= 5, "the loop ran on while the child lived ($ticks ticks)";
  is $r->{err}, 'upstream linger: exited (code 4)', 'its exit is reported once it comes';
  ok !kill(0, $pid), 'and it is reaped';
  is $up->state, 'stopped', 'stopped';
};

subtest 'a child that closes its stdout and does not exit is killed' => sub {
  # It can never answer again. It gets the grace a stop gives, then it goes.
  my @lines;
  my $up  = oneliner(stuck => 'close STDIN; close STDOUT; sleep 60', log => log_to(\@lines));
  my $r   = _await_bounded($up->start_p, 30);
  is $r->{err}, 'upstream stuck: exited (signal 9)', 'killed';
  ok +(grep { /^warn \[stuck\] closed its stdout 5s ago and still runs, killing it$/ } @lines), 'saying why'
    or diag explain \@lines;
  is $up->state, 'stopped', 'stopped';
};

subtest 'a stop ends even while a process the child started holds its socket' => sub {
  # The child exits at once; one process it leaves behind serves (echo.pl),
  # another only sits on the socket. A stop ends the server, but the socket
  # never closes -- so once the grace is over the hub lets go of it, instead
  # of waiting with the upstream stuck on its way out. The one that sits on
  # the socket writes its pid down: the hub is done with it, the test is not.
  my $dir    = tempdir;
  my $holder = $dir->child('holder.pid');
  my $up     = MCP::Hub::Upstream::Stdio->new(
    name      => 'holder',
    config    => {type => 'stdio', command => $^X,
      args => ['-e', <<~'CODE', "$ECHO", "$holder"]},
        exit 0 if fork;
        if (fork) { exec $^X, '-Ilib', $ARGV[0] }
        open my $fh, '>', $ARGV[1] or exit 9;
        print $fh $$; close $fh;
        sleep 20;
        CODE
    cache_dir => $dir->to_string,
    log       => log_to([]),
  );
  _await_bounded($up->start_p, 30);
  is $up->state, 'ready', 'the server answers';
  $up->stop;
  my $deadline = time + 15;
  settle(0.1) while $up->stats->{pid} && time < $deadline;
  is $up->stats->{pid}, undef, 'the stop ends';
  is $up->state, 'stopped', 'stopped';

  # Ended here, or it would sit on for 20 seconds after the test.
  my $sitter = -s $holder ? $holder->slurp : undef;
  ok $sitter, 'the socket was held';
  kill 'KILL', $sitter if $sitter;
  $deadline = time + 10;
  settle(0.05) while $sitter && !ended($sitter) && time < $deadline;
  ok !($sitter && !ended($sitter)), 'and the process that held it has ended';
};

subtest 'a call while the child is stopped starts the next one' => sub {
  # A call that comes in while an idle stop is under way must not go to the
  # child that is on its way out.
  my $up = upstream;
  _await($up->start_p);
  my $old = $up->stats->{pid};
  $up->stop;
  my $r = _await_bounded($up->call_tool('echo', {msg => 'after the stop'}), 30);
  is _error_text($r), 'after the stop', 'the call is answered' or diag explain $r;
  ok $up->stats->{pid} && $up->stats->{pid} != $old, 'by a new child';
  ok !kill(0, $old), 'the stopped one is gone';
  $up->stop;
  settle;
};

subtest 'a command that cannot be executed is logged loudly' => sub {
  my $dir = tempdir;
  my $up  = MCP::Hub::Upstream::Stdio->new(
    name      => 'missing',
    config    => {type => 'stdio', command => "$dir/definitely-not-a-binary"},
    cache_dir => "$dir",
  );

  my @lines;
  my $log = Mojo::Log->new;
  $log->unsubscribe('message');
  $log->on(message => sub ($l, $level, @msg) { push @lines, "$level @msg" });
  $up->log($log);

  # exec fails, and the child _exit()s with 127 -- the code says nothing on its
  # own, so the hint goes along: in the log, and in the reason the start fails
  # with, which is what a 503 and the status show.
  my $hint = "while starting '$dir/definitely-not-a-binary' -- is it installed and executable?";
  my $out  = _await($up->start_p);
  is $out->{err}, "upstream missing: exited (code 127) $hint", 'start rejects with the exit and the hint';
  ok +(grep { $_ eq "warn [missing] child exited (code 127) $hint" } @lines),
    'the missing command is named at warn level'
    or diag explain \@lines;

  # The hub marks it failed with that reason (MCP::Hub's warming fetch), and a
  # call is then told the reason and the way out -- in two sentences, as the
  # reason ends in a question mark.
  $up->fail($out->{err});
  is _error_text(_await($up->call_tool('anything', {}))),
    "upstream missing: exited (code 127) $hint Run 'mcp-hub refresh missing' to try again",
    'a call to it is told why and how to try again';

  # Where SIGCHLD is ignored the kernel reaps the child itself, waitpid fails
  # with ECHILD and $? is -1 -- which must not be reported as "signal 127".
  {
    local $SIG{CHLD} = 'IGNORE';
    @lines = ();
    my $ignored = MCP::Hub::Upstream::Stdio->new(
      name      => 'missing',
      config    => {type => 'stdio', command => "$dir/definitely-not-a-binary"},
      cache_dir => "$dir",
    );
    $ignored->log($log);
    _await($ignored->start_p);
    ok +(grep { /^(?:warn|error) / && /definitely-not-a-binary/ } @lines),
      'the command is named even when the child is reaped for us';
    ok !(grep { /signal 127/ } @lines), 'and no signal number is invented'
      or diag explain \@lines;
  }
};

subtest 'failed is left only by an explicit refresh' => sub {
  my $up = upstream()->fail_window($WINDOW);
  _await($up->call_tool('exit', {})) for 1 .. 3;
  is $up->state, 'failed', 'failed after three quick exits';

  # An ordinary call must not silently respawn a failed upstream.
  my $blocked = _await($up->call_tool('echo', {msg => 'hi'}));
  ok ${$blocked->{isError}}, 'a call against a failed upstream is an error result';
  like $blocked->{content}[0]{text}, qr/refresh/, 'the error says how to retry';
  is $up->stats->{pid}, undef, 'and nothing was spawned';
  is $up->state, 'failed', 'still failed';

  # An explicit refresh is the admin's "try again".
  _await($up->refresh_p);
  is $up->state, 'ready', 'refresh revives it';
  is _await($up->call_tool('echo', {msg => 'back'}))->{content}[0]{text}, 'back', 'calls work again';

  $up->stop;
  settle;
  is $up->state, 'stopped', 'a later stop leaves it stopped, not failed';
};

subtest 'list_changed triggers a refresh' => sub {
  my $up = upstream;
  _await($up->start_p);
  ok !(grep { $_->name eq 'echo2' } @{$up->server->tools}), 'echo2 absent before notify';

  _await($up->call_tool('notify', {}));
  _await($up->refresh_p);
  ok +(grep { $_->name eq 'echo2' } @{$up->server->tools}), 'echo2 present after refresh';
  $up->stop;
  settle;
};

subtest 'idle timeout stops the child' => sub {
  my $up = upstream(idle_timeout => 1);
  _await($up->start_p);
  is $up->state, 'ready', 'ready';
  ok $up->stats->{pid}, 'has a pid';

  settle(1.6);
  is $up->state, 'stopped', 'stopped after idle timeout';
  is $up->stats->{pid}, undef, 'child reaped';
};

done_testing;
