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
use Mojo::Log;
use Mojo::IOLoop;
use Mojo::Promise;
use MCP::Hub;
use MCP::Hub::Upstream::Stdio;
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

# The status of every exit the upstream handles, by pid -- a deliberate one is
# not logged.
my %STATUS;
{
  no warnings 'redefine';
  my $on_exit = \&MCP::Hub::Upstream::Stdio::_on_exit;
  *MCP::Hub::Upstream::Stdio::_on_exit = sub {
    my ($self, $status) = @_;
    $STATUS{$self->{pid}} = $status if $self->{pid};
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

done_testing;
