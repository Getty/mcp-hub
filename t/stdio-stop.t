#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;

# Every signal this process sends, [signal, pid, when] -- the hub's side of how
# a stop ends a child. Set before MCP::Hub::Upstream::Stdio is compiled, so
# that its kills come here.
my @KILLS;
BEGIN {
  *CORE::GLOBAL::kill = sub {
    my ($signal, @pids) = @_;
    push @KILLS, map { [$signal, $_, Time::HiRes::time()] } @pids unless $signal eq '0';
    return CORE::kill($signal, @pids);
  };
}

use Test::More;
use Mojo::File    qw(curfile tempdir);
use Mojo::JSON    qw(encode_json);
use Mojo::Log;
use Mojo::IOLoop;
use Mojo::Promise;
use MCP::Hub;
use MCP::Hub::Upstream::Stdio;
use Scalar::Util qw(weaken);
use Time::HiRes ();

# How a stop ends a stdio child (MCP::Hub::Upstream::Stdio, "Lifecycle"): its
# stdin is closed, and a child that exits on that within EOF_GRACE seconds is
# never signalled; one still there gets SIGTERM, and SIGKILL KILL_GRACE seconds
# after that. echo.pl, told to, writes down every SIGTERM it gets -- the
# child's side of it.

my $ECHO       = curfile->sibling('upstream', 'echo.pl');
my $EOF_GRACE  = MCP::Hub::Upstream::Stdio->EOF_GRACE;
my $KILL_GRACE = MCP::Hub::Upstream::Stdio->KILL_GRACE;
my $SLACK      = 0.1;    # timer against clock, parent against child

# Every spawn and every exit handled, as "spawn PID" and "exit PID", in order:
# which of two children of a server ran when.
my @EVENTS;

# The status of every exit the upstream handles, by pid -- a deliberate one is
# not logged.
my %STATUS;
{
  no warnings 'redefine';
  my $on_exit = \&MCP::Hub::Upstream::Stdio::_on_exit;
  *MCP::Hub::Upstream::Stdio::_on_exit = sub {
    my ($self, $status) = @_;
    $STATUS{$self->{pid}} = $status if $self->{pid};
    push @EVENTS, "exit $self->{pid}" if $self->{pid};
    goto &$on_exit;
  };
}
sub exit_of ($pid) { return MCP::Hub::Upstream::Stdio::_exit_reason($STATUS{$pid}) }

# Every child started, so that none outlives a test that failed half-way: one
# whose exit was never handled is still this process's, its pid no other's.
my %SPAWNED;
{
  no warnings 'redefine';
  my $attach = \&MCP::Hub::Upstream::Stdio::_attach;
  *MCP::Hub::Upstream::Stdio::_attach = sub {
    $SPAWNED{$_[1]} = 1;
    push @EVENTS, "spawn $_[1]";
    goto &$attach;
  };
}
END { CORE::kill('KILL', $_) for grep { !exists $STATUS{$_} } keys %SPAWNED }

sub log_to ($lines) {
  my $log = Mojo::Log->new;
  $log->unsubscribe('message');
  $log->on(message => sub ($l, $level, @msg) { push @$lines, "$level @msg" });
  return $log;
}

sub await_bounded ($promise, $seconds) {
  my $out;
  Mojo::Promise->race(Mojo::Promise->timeout($seconds), $promise)
    ->then(sub { $out = shift // 1 })->catch(sub { $out = {err => shift} })->wait;
  return $out;
}

sub settle ($seconds) { Mojo::Promise->timer($seconds)->wait }

# An echo.pl child that writes its SIGTERMs to a file of its own, and the file.
sub upstream (@flags) {
  my $dir     = tempdir;
  my $signals = $dir->child('signals');
  my $up      = MCP::Hub::Upstream::Stdio->new(
    name      => 'echo',
    config    => {type => 'stdio', command => $^X, args => ['-Ilib', "$ECHO", "--signals=$signals", @flags]},
    cache_dir => "$dir",
    log       => log_to([]),
  );
  return ($up, $signals);
}

# The times of the SIGTERMs the child got, after $t0.
sub terms ($signals, $t0) {
  return () unless -e $signals;
  return map { /^TERM ([\d.]+)$/ ? $1 - $t0 : () } split /\n/, $signals->slurp;
}

# Started, then stopped: the pid, the time of the stop, and how long it took
# for stopped_p to resolve -- undef if it did not within $seconds.
sub stop_and_wait ($up, $seconds = 20) {
  my $r = await_bounded($up->start_p, 30);
  die "no start: $r->{err}\n" if ref $r eq 'HASH' && $r->{err};
  my $pid = $up->stats->{pid};
  my $t0  = Time::HiRes::time();
  $up->stop;
  my $done = await_bounded($up->stopped_p, $seconds);
  my $took = Time::HiRes::time() - $t0;
  return ($pid, $t0, (ref $done eq 'HASH' ? undef : $took));
}

subtest 'a child that exits at the end of its input is never signalled' => sub {
  my ($up, $signals) = upstream;
  my ($pid, $t0, $took) = stop_and_wait($up);
  ok defined $took, 'stopped';
  cmp_ok $took, '<', $EOF_GRACE, sprintf 'within the grace (%.2fs)', $took // -1;
  is_deeply [terms($signals, $t0)], [], 'it got no SIGTERM';
  is_deeply [grep { $_->[1] == $pid } @KILLS], [], 'nor any other signal';
  is exit_of($pid), 'code 0', 'it exited on its own';
  ok !kill(0, $pid), 'and is gone once stopped_p resolves';
  is $up->state, 'stopped', 'stopped';
};

subtest 'one that takes its time over it is given the time' => sub {
  # A server that finishes what it is in the middle of -- a commit, say --
  # before it goes.
  my ($up, $signals) = upstream('--eof-delay=1');
  my ($pid, $t0, $took) = stop_and_wait($up);
  ok defined $took, 'stopped';
  cmp_ok $took, '>=', 1, sprintf 'once it was done (%.2fs)', $took // -1;
  is_deeply [terms($signals, $t0)], [], 'it got no SIGTERM';
  is exit_of($pid), 'code 0', 'it exited on its own';
};

subtest 'a call in flight that ends within the grace is finished' => sub {
  # The server reads its EOF once the call is done, and goes.
  my ($up, $signals) = upstream;
  await_bounded($up->start_p, 30);
  my $pid = $up->stats->{pid};
  my $r;
  $up->call_tool('sleep', {seconds => 0.5})->then(sub { $r = shift })->catch(sub { $r = {err => shift} });
  settle(0.1);    # the call has reached the child
  my $t0 = Time::HiRes::time();
  $up->stop;
  my $done = await_bounded($up->stopped_p, 20);
  ok !(ref $done eq 'HASH'), sprintf 'stopped (%.2fs)', Time::HiRes::time() - $t0;
  is ref $r eq 'HASH' && ref $r->{content} eq 'ARRAY' ? $r->{content}[0]{text} : undef, 'slept 0.5', 'the call is answered'
    or diag explain $r;
  is_deeply [terms($signals, $t0)], [], 'the child got no SIGTERM';
  is exit_of($pid), 'code 0', 'and exited on its own';
};

subtest 'one that stays on after its EOF gets SIGTERM once the grace is over' => sub {
  my ($up, $signals) = upstream('--ignore-eof');
  my ($pid, $t0, $took) = stop_and_wait($up);
  ok defined $took, 'stopped';
  my @terms = terms($signals, $t0);
  is scalar @terms, 1, 'it got one SIGTERM';
  cmp_ok $terms[0] // 0, '>=', $EOF_GRACE - $SLACK, sprintf 'not before the grace was over (%.2fs)', $terms[0] // -1;
  cmp_ok $took, '<', $EOF_GRACE + $KILL_GRACE, sprintf 'and went on it (%.2fs)', $took // -1;
  is exit_of($pid), 'code 0', 'its handler exited';
  ok !kill(0, $pid), 'gone once stopped_p resolves';
};

subtest 'one that ignores SIGTERM as well is killed after the second grace' => sub {
  my ($up, $signals) = upstream('--ignore-eof', '--ignore-term');
  my ($pid, $t0, $took) = stop_and_wait($up);
  ok defined $took, 'stopped';
  my @terms = terms($signals, $t0);
  is scalar @terms, 1, 'it got one SIGTERM';
  cmp_ok $terms[0] // 0, '>=', $EOF_GRACE - $SLACK, sprintf 'after the grace (%.2fs)', $terms[0] // -1;
  cmp_ok $took, '>=', $EOF_GRACE + $KILL_GRACE - $SLACK, sprintf 'SIGKILL %ds after it (%.2fs)', $KILL_GRACE, $took // -1;
  is exit_of($pid), 'signal 9', 'killed';
  ok !kill(0, $pid), 'gone once stopped_p resolves';
};

subtest 'a second stop neither starts the grace over nor hurries it' => sub {
  my ($up, $signals) = upstream('--ignore-eof');
  my $r = await_bounded($up->start_p, 30);
  ok !(ref $r eq 'HASH'), 'started' or diag $r->{err};
  my $pid = $up->stats->{pid};
  my $t0  = Time::HiRes::time();
  $up->stop;
  settle(1);
  $up->stop;
  is_deeply [terms($signals, $t0)], [], 'no SIGTERM for the second stop';
  my $done = await_bounded($up->stopped_p, 20);
  ok !(ref $done eq 'HASH'), 'stopped' or diag $done->{err};
  my @terms = terms($signals, $t0);
  is scalar @terms, 1, 'one SIGTERM';
  cmp_ok $terms[0] // 0, '>=', $EOF_GRACE - $SLACK, sprintf 'once the first grace was over (%.2fs)', $terms[0] // -1;
  cmp_ok $terms[0] // 99, '<', $EOF_GRACE + 0.9, 'not a second later';
};

subtest 'a call during the grace goes to the next child' => sub {
  # The one that is leaving has been sent its EOF: nothing more can reach it.
  my ($up, $signals) = upstream('--ignore-eof');
  await_bounded($up->start_p, 30);
  my $old = $up->stats->{pid};
  my $t0  = Time::HiRes::time();
  $up->stop;
  my $r    = await_bounded($up->call_tool('echo', {msg => 'after the stop'}), 30);
  my $took = Time::HiRes::time() - $t0;
  is ref $r eq 'HASH' && ref $r->{content} eq 'ARRAY' ? $r->{content}[0]{text} : undef, 'after the stop', 'answered'
    or diag explain $r;
  my $new = $up->stats->{pid};
  ok $new && $new != $old, 'by a new child';
  cmp_ok $took, '>=', $EOF_GRACE - $SLACK, sprintf 'once the old one was gone (%.2fs)', $took;
  ok !kill(0, $old), 'which it is';
  is scalar(terms($signals, $t0)), 1, 'on its SIGTERM';
  $up->stop;
  await_bounded($up->stopped_p, 20);
};

subtest 'a child being stopped is stopping until it is gone' => sub {
  # Up to seven seconds: it stayed `ready` all that time, in the status, though
  # nothing more could reach it.
  my ($up, $signals) = upstream('--eof-delay=1');
  await_bounded($up->start_p, 30);
  my $pid = $up->stats->{pid};
  $up->stop;
  is $up->state, 'stopping', 'stopping once it is sent its EOF';
  is $up->status_row->{state}, 'stopping', 'and in its status row';
  is $up->status_row->{pid}, $pid, 'with its pid, which is still there';
  await_bounded($up->stopped_p, 20);
  is $up->state, 'stopped', 'stopped once it is gone';
  is $up->status_row->{pid}, undef, 'with no pid';

  # A start the stop called off: the child is still there after the start
  # failed, and stopping until it is gone. The stop comes as the start asks
  # for the tools (as in 'a stop during the start'): the child has answered
  # its initialize by then, so how long perl took to start it does not decide
  # whether it is still there. A stop sent right after the spawn reached a
  # child that was not up yet, and on a loaded host it got its SIGTERM
  # (EOF_GRACE) before it answered and was gone before the test looked.
  no warnings 'redefine';
  my $request = \&MCP::Hub::Upstream::Stdio::_request_p;
  local *MCP::Hub::Upstream::Stdio::_request_p = sub ($self, $method, @rest) {
    $self->stop if $method eq 'tools/list';
    return $request->($self, $method, @rest);
  };
  my $start = $up->start_p;
  ok $up->stats->{pid}, 'the next child is there';
  my $r = await_bounded($start, 20);
  is ref $r eq 'HASH' ? $r->{err} : 'ready', 'upstream echo: stopped', 'a start the stop called off fails as stopped';
  is $up->state, 'stopping', 'and its child is stopping';
  await_bounded($up->stopped_p, 20);
  is $up->state, 'stopped', 'until it is gone';
};

subtest 'a refresh during the grace asks the next child' => sub {
  # It went to the leaving child, and failed: "the child the refresh began on
  # is gone". It waits for that child to be gone and starts the next, as a call
  # does.
  my ($up, $signals) = upstream('--eof-delay=1');
  await_bounded($up->start_p, 30);
  my $old = $up->stats->{pid};
  $up->stop;
  my $r = await_bounded($up->refresh_p, 30);
  is ref $r eq 'HASH' ? $r->{err} : 'refreshed', 'refreshed', 'the refresh is through' or diag explain $r;
  my $new = $up->stats->{pid};
  ok $new && $new != $old, 'by a new child';
  ok !kill(0, $old), 'once the old one was gone';
  is exit_of($old), 'code 0', 'which ended on its EOF';
  is $up->state, 'ready', 'ready';
  ok +(grep { $_->name eq 'echo' } @{$up->server->tools}), 'with its tools';
  $up->stop;
  await_bounded($up->stopped_p, 20);
};

subtest 'a list_changed from a child being stopped starts nothing' => sub {
  # A refresh for it would wait for the child to be gone and start the next
  # one: after an idle stop, a child no call asked for -- and the next idle
  # stop the same again.
  my ($up, $signals) = upstream('--eof-delay=1', '--notify-on-eof');
  my @logged;
  $up->log(log_to(\@logged)->level('debug'));
  await_bounded($up->start_p, 30);
  my $pid = $up->stats->{pid};
  $up->stop;
  await_bounded($up->stopped_p, 20);
  settle(0.5);    # time for a start that was kicked off to show
  is scalar(grep {/started/} @logged), 1, 'no child started after the stop' or diag explain \@logged;
  is $up->stats->{pid}, undef, 'none is running';
  is $up->state, 'stopped', 'stopped';
  is scalar(grep { $_ eq 'debug [echo] notifications/tools/list_changed from a child being stopped, not refreshing' }
      @logged), 1, 'the notification is let go, at debug'
    or diag explain \@logged;
};

subtest 'a call that comes upon a stop fails at once' => sub {
  # It is let through on the ready child, and the stop comes before its
  # request goes out: the child has been sent its EOF, and nothing more can
  # reach it. The request is not sent, and fails at once -- unsent, it waited
  # for the child's exit, or with the child gone out the request timeout.
  my ($up, $signals) = upstream('--ignore-eof');
  $up->request_timeout(30);
  await_bounded($up->start_p, 30);
  my $t0   = Time::HiRes::time();
  my $call = $up->call_tool('echo', {msg => 'too late'});
  $up->stop;
  my $r    = await_bounded($call, 20);
  my $took = Time::HiRes::time() - $t0;
  is ref $r eq 'HASH' && ref $r->{content} eq 'ARRAY' ? $r->{content}[0]{text} : undef, 'upstream echo: stopped',
    'the call fails as stopped' or diag explain $r;
  cmp_ok $took, '<', 1, sprintf 'at once (%.2fs)', $took;
  await_bounded($up->stopped_p, 20);
  is scalar(terms($signals, $t0)), 1, 'and the stop goes on as it would: SIGTERM once the grace is over';
};

subtest 'a request written just before the stop still reaches the child' => sub {
  # Written in the same tick as the stop, it is still in the stream's buffer
  # when the stop sends EOF -- and the stop shut the socket's write side at
  # once. The request was lost: a child that ends on its EOF never read it, and
  # the request failed as its exit; for one that stays on, the stream wrote it
  # to the shut socket again and again, a core busy until the child was
  # signalled. The EOF goes once what was written before it is out.
  for my $case (['ends on its EOF', 0], ['stays on after it', 1, '--ignore-eof']) {
    my ($what, $terms, @flags) = @$case;
    my ($up, $signals) = upstream(@flags);
    await_bounded($up->start_p, 30);
    my $pid = $up->stats->{pid};
    my ($r, $cpu0, $t0);
    Mojo::IOLoop->next_tick(sub {
      ($cpu0, $t0) = ((times)[0], Time::HiRes::time());
      $up->_request_p('tools/call', {name => 'echo', arguments => {msg => 'hi'}})
        ->then(sub { $r = shift }, sub { $r = {err => shift} });
      $up->stop;
    });
    await_bounded($up->stopped_p, 20);
    my $cpu = (times)[0] - $cpu0;
    is ref $r eq 'HASH' && ref $r->{content} eq 'ARRAY' ? $r->{content}[0]{text} : undef, 'hi',
      "a child that $what: the request is answered" or diag explain $r;
    my @terms = terms($signals, $t0);
    is scalar @terms, $terms, "and the stop goes on as it would: $terms SIGTERM";
    is exit_of($pid), 'code 0', 'the child ends';
    cmp_ok $cpu, '<', 0.5, sprintf 'no core busy meanwhile (%.2fs of CPU)', $cpu;
  }
};

subtest 'a stop during the start is no failed start' => sub {
  # It comes as the start asks for its tools, or for its prompts -- which a
  # start takes for an empty list when they are not answered. The request is
  # not sent and the start fails as stopped, at once; it is not counted toward
  # the crash loop, and the child is left to the stop: it ends on its EOF,
  # never signalled. Nor is it logged as a failure: it was logged at error,
  # "handshake failed: upstream echo: stopped", where the Http transport logs
  # it at debug -- a reload that replaces a starting entry wrote an error line
  # for something that is no failure.
  for my $at ('tools/list', 'prompts/list') {
    my ($up, $signals) = upstream('--eof-delay=1');
    my @logged;
    $up->log(log_to(\@logged)->level('debug'));
    $up->fail_window(60);
    $up->request_timeout(30);
    my $t0;
    no warnings 'redefine';
    my $request = \&MCP::Hub::Upstream::Stdio::_request_p;
    local *MCP::Hub::Upstream::Stdio::_request_p = sub ($self, $method, @rest) {
      if ($method eq $at) { $t0 = Time::HiRes::time(); $self->stop }
      return $request->($self, $method, @rest);
    };
    for my $n (1 .. 3) {
      undef $t0;
      my $start = $up->start_p;
      my $pid   = $up->stats->{pid};
      my $r     = await_bounded($start, 20);
      my $took  = Time::HiRes::time() - ($t0 // 0);
      is ref $r eq 'HASH' ? $r->{err} : 'ready', 'upstream echo: stopped', "$at, attempt $n: the start fails as stopped";
      cmp_ok $took, '<', 0.5, sprintf "$at, attempt $n: at once, not once the child is gone (%.2fs)", $took;
      await_bounded($up->stopped_p, 20);
      is exit_of($pid), 'code 0', "$at, attempt $n: the child ends on its EOF";
      is_deeply [grep { $_->[1] == $pid } @KILLS], [], "$at, attempt $n: unsignalled";
    }
    is $up->state, 'stopped', "$at: none of the stops counted";
    is_deeply [grep { !/^(?:trace|debug|info) / } @logged], [], "$at: nothing logged as a failure"
      or diag explain \@logged;
    is scalar(grep { $_ eq 'debug [echo] start called off by a stop' } @logged), 3,
      "$at: each start the stop called off is logged at debug, as such";
  }
};

subtest 'a start whose child ends on the EOF of a stop, with an answer held back, fails as stopped' => sub {
  # The stop comes after the request went out: the child has it, and holds
  # its answer back. It ends at once on its EOF, and its exit fails the request
  # first -- the start failed as "upstream holder: exited (code 0)", though it
  # was logged as called off and counted as no failed start, and the upstream
  # showed `stopped`. Over HTTP a start a stop called off is rejected as
  # stopped, whatever step of it the stop cut short; so here. A prompts/list a
  # start takes for an empty list when it is not answered failed as stopped
  # already.
  my $peer = <<~'CODE';
    use Mojo::JSON qw(decode_json encode_json);
    my $at = shift;
    $| = 1;
    while (my $line = <STDIN>) {
      my $msg = eval { decode_json($line) } // next;
      next unless defined $msg->{id};
      if ($msg->{method} eq $at) { print STDERR "holding $at\n"; next }
      my $result = $msg->{method} eq 'initialize'
        ? {protocolVersion => '2025-06-18', serverInfo => {name => 'holder', version => '1'},
           capabilities => {tools => {}, prompts => {}}}
        : $msg->{method} eq 'tools/list' ? {tools => [{name => 'echo', inputSchema => {type => 'object'}}]}
        :                                  {prompts => []};
      print encode_json({jsonrpc => '2.0', id => $msg->{id}, result => $result}), "\n";
    }
    exit 0;    # at once, at the end of its input
    CODE
  for my $at ('initialize', 'tools/list', 'prompts/list') {
    # The stop comes as the child says it holds the answer: it has the request.
    my (@logged, $up);
    my $log = log_to(\@logged)->level('debug');
    my $weak;
    $log->on(message => sub ($l, $level, @msg) { $weak->stop if $weak && "@msg" eq "[holder] holding $at" });
    $up = MCP::Hub::Upstream::Stdio->new(
      name        => 'holder',
      config      => {type => 'stdio', command => $^X, args => ['-e', $peer, $at]},
      cache_dir   => tempdir->to_string,
      fail_window => 60,
      log         => $log,
    );
    $up->request_timeout(30);
    weaken($weak = $up);
    for my $n (1 .. 3) {
      my $start = $up->start_p;
      my $pid   = $up->stats->{pid};
      my $r     = await_bounded($start, 20);
      is ref $r eq 'HASH' ? $r->{err} : 'ready', 'upstream holder: stopped', "$at, attempt $n: the start fails as stopped";
      await_bounded($up->stopped_p, 20);
      is exit_of($pid), 'code 0', "$at, attempt $n: the child ends on its EOF";
      is_deeply [grep { $_->[1] == $pid } @KILLS], [], "$at, attempt $n: unsignalled";
    }
    is scalar(grep { $_ eq "debug [holder] holding $at" } @logged), 3, "$at: each time the child had the request";
    my $row = $up->status_row;
    is_deeply [@$row{qw(state error)}], ['stopped', undef], "$at: the status shows it stopped, with no error, as the start says"
      or diag explain $row;
    is_deeply [grep { !/^(?:trace|debug|info) / } @logged], [], "$at: nothing logged as a failure"
      or diag explain \@logged;
    is scalar(grep { $_ eq 'debug [holder] start called off by a stop' } @logged), 3,
      "$at: each start logged as called off by a stop";
  }
};

subtest 'a start that fails on its own is logged as the failure it is' => sub {
  # The other side of the stop during the start: a child that is gone before
  # it answers its initialize -- no stop asked for -- fails the start, at error.
  my @logged;
  my $up = MCP::Hub::Upstream::Stdio->new(
    name      => 'gone',
    config    => {type => 'stdio', command => $^X, args => ['-e', 'exit 3']},
    cache_dir => tempdir->to_string,
    log       => log_to(\@logged)->level('debug'),
  );
  my $r = await_bounded($up->start_p, 20);
  is ref $r eq 'HASH' ? $r->{err} : 'ready', 'upstream gone: exited (code 3)', 'the start fails with the exit';
  is_deeply [grep {/^error /} @logged], ['error [gone] handshake failed: upstream gone: exited (code 3)'],
    'logged at error' or diag explain \@logged;
  ok !(grep {/called off/} @logged), 'not as called off by a stop';
};

subtest 'a child reaped before its grace is over gets no signal' => sub {
  # Its pid may be another process's by then. The child exits at once; the
  # server it started answers, a process of its own holds the socket on. The
  # stop ends anyway (t/stdio.t); here, no signal goes to the pid once the
  # child's exit is in.
  #
  # The precondition is that the exit is in before the grace is over, and the
  # reactors differ on it: under EV libev reaps the child at once, otherwise
  # its status is collected only once its socket closes -- which the process
  # holding the socket prevents -- or at the SIGKILL. The child's `collect` is
  # what the socket's close calls; it polls without blocking until the child is
  # reaped, and here it is called at the start, so that the reap happens
  # before the stop under both. Without it, under Poll the child is a zombie at
  # the SIGTERM, its pid cannot be another's, and the guard would measure nothing.
  my %reaped;
  no warnings 'redefine';
  my $on_reaped = \&MCP::Hub::Upstream::Stdio::_on_reaped;
  local *MCP::Hub::Upstream::Stdio::_on_reaped = sub {
    my ($self) = @_;
    $reaped{$self->{pid}} //= Time::HiRes::time() if $self->{pid};
    goto &$on_reaped;
  };
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
  my $r = await_bounded($up->start_p, 30);
  ok !(ref $r eq 'HASH' && $r->{err}), 'started' or diag $r->{err};
  my $pid = $up->stats->{pid};
  $up->{child}{collect}->();
  my $deadline = Time::HiRes::time() + 5;
  settle(0.02) until $reaped{$pid} || Time::HiRes::time() > $deadline;
  ok $reaped{$pid}, 'the child was reaped, with its socket still held';

  my $t0 = Time::HiRes::time();
  $up->stop;
  my $done = await_bounded($up->stopped_p, 20);
  my $took = Time::HiRes::time() - $t0;
  ok !(ref $done eq 'HASH'), sprintf 'the stop ends (%.2fs)', $took;
  cmp_ok $took, '>=', $EOF_GRACE - $SLACK, 'the stop outlasted the grace, when a SIGTERM would have gone out';
  cmp_ok $reaped{$pid} // $t0, '<', $t0, 'the reap came before the stop, and so before the SIGTERM would go out';
  my @late = grep { $_->[1] == $pid } @KILLS;
  is_deeply \@late, [], 'and no signal went to the pid' or diag explain \@late;

  # The process that held the socket is the test's to end.
  my $sitter = -s $holder ? $holder->slurp : undef;
  ok $sitter, 'the socket was held';
  CORE::kill('KILL', $sitter) if $sitter;
  $deadline = Time::HiRes::time() + 10;
  settle(0.05) while $sitter && CORE::kill(0, $sitter) && Time::HiRes::time() < $deadline;
  ok !($sitter && CORE::kill(0, $sitter)), 'and is gone';
};

subtest 'a shutdown waits for a child that stays on after its EOF' => sub {
  # Until it is gone: with the loop stopped, the child would never get the
  # SIGTERM that ends it.
  my $dir     = tempdir;
  my $signals = $dir->child('signals');
  my $hub     = MCP::Hub->new(log => log_to([]), hub_config_input => {
    mcpServers => {stays => {command => $^X, args => ['-Ilib', "$ECHO", "--signals=$signals", '--ignore-eof']}},
    hub        => {cache_dir => $dir->child('cache')->to_string},
  });
  my $up = $hub->upstreams_by_name->{stays};
  await_bounded($up->start_p, 30);
  my $pid = $up->stats->{pid};
  ok $pid, 'a child';
  my $t0   = Time::HiRes::time();
  my $done = await_bounded($hub->shutdown_p, 20);
  my $took = Time::HiRes::time() - $t0;
  ok !(ref $done eq 'HASH' && $done->{err}), 'the shutdown is done';
  ok !kill(0, $pid), sprintf 'and the child gone by then (%.2fs)', $took;
  is scalar(terms($signals, $t0)), 1, 'ended by its SIGTERM';
};

subtest 'a refresh waiting on the child of an upstream a reload lets go of starts nothing' => sub {
  # The hub holds the upstream only until that child is gone
  # (MCP::Hub::_let_go): a child the refresh started then would be stopped by
  # no one -- not by the shutdown, which waits for the upstreams it holds.
  my $dir  = tempdir;
  my $file = $dir->child('config.json');
  my $hub_settings = {cache_dir => $dir->child('cache')->to_string};
  $file->spew(encode_json({
    mcpServers => {goes => {command => $^X, args => ['-Ilib', "$ECHO", '--eof-delay=1']}},
    hub        => $hub_settings,
  }));
  my @logged;
  my $hub = MCP::Hub->new(log => log_to(\@logged)->level('debug'), hub_config_input => "$file");
  my $up  = $hub->upstreams_by_name->{goes};
  await_bounded($up->start_p, 30);
  my $pid = $up->stats->{pid};
  $up->stop;    # an idle stop, say
  my $refresh = $up->refresh_p;

  $file->spew(encode_json({mcpServers => {}, hub => $hub_settings}));
  is_deeply $hub->reload->{removed}, ['goes'], 'a reload removes it meanwhile';
  my $r = await_bounded($refresh, 20);
  is ref $r eq 'HASH' ? $r->{err} : 'refreshed', 'upstream goes: stopped', 'the refresh fails as stopped';
  ok !kill(0, $pid), 'once the child is gone';
  settle(0.5);    # time for a start that was kicked off to show
  is $up->stats->{pid}, undef, 'and no child is started for it';
  is scalar(grep {/started/} @logged), 1, 'none at all' or diag explain [grep {/started/} @logged];
  ok +(grep { $_ eq 'debug [goes] no longer mounted, it starts no child' } @logged), 'it says why, at debug';
  await_bounded($hub->shutdown_p, 20);
};

subtest 'a call waiting on the child of an upstream a reload lets go of starts nothing' => sub {
  # A call during a stop waits for the child to be gone and starts the next.
  # The reload lets go of the upstream meanwhile: the hub holds it only until
  # that child is gone (MCP::Hub::_let_go), so the child the call started was
  # stopped by no one -- not by the shutdown, which waits for the upstreams it
  # holds. The call fails as stopped, as a refresh does.
  my $dir  = tempdir;
  my $file = $dir->child('config.json');
  my $hub_settings = {cache_dir => $dir->child('cache')->to_string};
  $file->spew(encode_json({
    mcpServers => {goes => {command => $^X, args => ['-Ilib', "$ECHO", '--eof-delay=1']}},
    hub        => $hub_settings,
  }));
  my @logged;
  my $hub = MCP::Hub->new(log => log_to(\@logged)->level('debug'), hub_config_input => "$file");
  my $up  = $hub->upstreams_by_name->{goes};
  await_bounded($up->start_p, 30);
  my $pid = $up->stats->{pid};
  $up->stop;    # an idle stop, say
  my $call = $up->call_tool('echo', {msg => 'a child of its own'});

  $file->spew(encode_json({mcpServers => {}, hub => $hub_settings}));
  is_deeply $hub->reload->{removed}, ['goes'], 'a reload removes it meanwhile';
  my $r = await_bounded($call, 20);
  is ref $r eq 'HASH' && ref $r->{content} eq 'ARRAY' ? $r->{content}[0]{text} : undef, 'upstream goes: stopped',
    'the call fails as stopped' or diag explain $r;
  ok !kill(0, $pid), 'once the child is gone';
  # A child started for the call is there by the time the call is answered.
  is $up->stats->{pid}, undef, 'and no child is started for it';
  is scalar(grep {/started/} @logged), 1, 'none at all' or diag explain [grep {/started/} @logged];
  ok +(grep { $_ eq 'debug [goes] no longer mounted, it starts no child' } @logged), 'it says why, at debug';
  await_bounded($hub->shutdown_p, 20);
};

# A reload stops the upstream it replaces, and its child is given seven seconds
# after its EOF -- this one stays on for the first two, until its SIGTERM. Its
# successor's child started at once, and the two ran side by side; it starts
# once the old one is gone, however its start comes: a call (only the env
# changed, so the manifest is shared and nothing is warmed), an always_on start,
# or the warming fetch of an entry with no manifest of its own yet.
for my $case (
  [call      => {env  => {K187 => 1}}],
  [always_on => {hub  => {always_on => \1}}],
  [warming   => {args => ['-Ilib', "$ECHO"]}],
) {
  my ($how, $change) = @$case;
  subtest "after a reload the child of a changed server starts once the old one is gone ($how)" => sub {
    my $dir      = tempdir;
    my $file     = $dir->child('config.json');
    my $signals  = $dir->child('signals');
    my $settings = {cache_dir => $dir->child('cache')->to_string};
    my $entry    = {command => $^X, args => ['-Ilib', "$ECHO", "--signals=$signals", '--ignore-eof']};
    $file->spew(encode_json({mcpServers => {stays => $entry}, hub => $settings}));
    my $hub = MCP::Hub->new(log => log_to([]), hub_config_input => "$file");
    my $old = $hub->upstreams_by_name->{stays};
    my $mark = @EVENTS;
    my $r    = await_bounded($old->start_p, 30);
    ok !(ref $r eq 'HASH' && $r->{err}), 'the upstream started' or diag $r->{err};
    my $pid = $old->stats->{pid};

    $file->spew(encode_json({mcpServers => {stays => {%$entry, %$change}}, hub => $settings}));
    my $t0 = Time::HiRes::time();
    is_deeply $hub->reload->{changed}, ['stays'], 'a reload replaces it';
    my $new = $hub->upstreams_by_name->{stays};
    ok kill(0, $pid), 'its child is still running, after its EOF';
    my $start = $how eq 'call' ? $new->call_tool('echo', {msg => 'the new child'}) : $new->start_p;
    is $new->stats->{pid}, undef, 'the new upstream has no child yet';
    is $new->state, 'starting', 'it is starting';

    $r = await_bounded($start, 30);
    if ($how eq 'call') { is $r->{content}[0]{text}, 'the new child', 'the call is answered' or diag explain $r }
    else                { ok !(ref $r eq 'HASH' && $r->{err}), 'it is started' or diag explain $r }
    my %who  = ($pid => 'old');
    my @seen = map { my ($what, $p) = split / /; "$what " . ($who{$p} //= 'new') } @EVENTS[$mark .. $#EVENTS];
    is_deeply [@seen[0 .. 2]], ['spawn old', 'exit old', 'spawn new'], 'by the old child, once it was gone'
      or diag explain \@seen;
    is scalar(grep {/^spawn/} @seen), 2, 'and by that one alone' or diag explain \@seen;
    is scalar(terms($signals, $t0)), 1, 'which ended on its SIGTERM, as before';
    await_bounded($hub->shutdown_p, 20);
  };
}

subtest 'a start that waited for the old child and then fails leaves no rejection unhandled' => sub {
  # The start's promise is its callers'. The wait handed it on to a promise of
  # its own that no one held, and Mojo::Promise carped about that one as an
  # unhandled rejection, on every start that failed after its wait.
  my @warned;
  local $SIG{__WARN__} = sub { push @warned, @_ };
  my $dir      = tempdir;
  my $file     = $dir->child('config.json');
  my $settings = {cache_dir => $dir->child('cache')->to_string};
  $file->spew(encode_json({
    mcpServers => {stays => {command => $^X, args => ['-Ilib', "$ECHO", '--ignore-eof']}},
    hub        => $settings,
  }));
  my $hub = MCP::Hub->new(log => log_to([]), hub_config_input => "$file");
  my $old = $hub->upstreams_by_name->{stays};
  my $r   = await_bounded($old->start_p, 30);
  ok !(ref $r eq 'HASH' && $r->{err}), 'the upstream started' or diag $r->{err};

  $file->spew(encode_json({mcpServers => {stays => {command => $^X, args => ['-e', 'exit 3']}}, hub => $settings}));
  is_deeply $hub->reload->{changed}, ['stays'], 'a reload replaces it with one that cannot start';
  $r = await_bounded($hub->upstreams_by_name->{stays}->start_p, 30);
  ok ref $r eq 'HASH' && $r->{err}, 'whose start fails, once the old child is gone' or diag explain $r;
  await_bounded($hub->shutdown_p, 20);
  is_deeply [grep {/Unhandled rejected promise/} @warned], [], 'and no rejection is left unhandled'
    or diag explain \@warned;
};

done_testing;
