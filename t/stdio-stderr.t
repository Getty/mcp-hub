#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File    qw(curfile tempdir);
use Mojo::Log;
use Mojo::Promise;
use MCP::Hub::Upstream::Fork;
use MCP::Hub::Upstream::Stdio;
use Time::HiRes qw(time);

use lib curfile->sibling('lib')->to_string;

# What a child writes to its stderr just before it exits is often why it
# died. Its stdout and its stderr end together, and under load the loop may
# see the end of stdout -- and the exit -- before it has read the pipe; the
# exit is then handled with those lines still in it. The tests force that
# order: the stderr pipe is taken out of the loop right after the spawn, so
# nothing but the read on the way out ever sees it.

sub log_to ($lines) {
  my $log = Mojo::Log->new(level => 'debug');
  $log->unsubscribe('message');
  $log->on(message => sub ($l, $level, @msg) { push @$lines, "$level @msg" });
  return $log;
}

sub oneliner ($name, $code, %attr) {
  return MCP::Hub::Upstream::Stdio->new(
    name      => $name,
    config    => {type => 'stdio', command => $^X, args => ['-e', $code]},
    cache_dir => tempdir->to_string,
    %attr,
  );
}

sub await_bounded ($promise, $seconds = 30) {
  my $out;
  Mojo::Promise->race(Mojo::Promise->timeout($seconds), $promise)
    ->then(sub { $out = shift })->catch(sub { $out = {err => shift} })->wait;
  return $out;
}

# Starts the upstream with the stderr pipe of its child never watched.
sub start_unwatched ($up) {
  no strict 'refs';
  no warnings 'redefine';
  my $class = ref $up;
  my $spawn = \&{"${class}::_spawn"};
  local *{"${class}::_spawn"} = sub ($self) {
    my $pid  = $spawn->($self);
    my $pipe = $self->{err_stream};
    $pipe->reactor->remove($pipe->handle);
    return $pid;
  };
  return await_bounded($up->start_p);
}

sub wait_until ($cond, $seconds) {
  my $deadline = time + $seconds;
  Mojo::Promise->timer(0.05)->wait until $cond->() || time > $deadline;
  return $cond->();
}

sub index_of ($lines, $re) {
  for my $i (0 .. $#$lines) { return $i if $lines->[$i] =~ $re }
  return -1;
}

subtest 'a stdio child: its last lines are logged before its exit' => sub {
  my @lines;
  my $up = oneliner(dying => 'print STDERR "loading config\nno such file: /etc/x.json\n"; exit 3', log => log_to(\@lines));
  my $r  = start_unwatched($up);
  is $r->{err}, 'upstream dying: exited (code 3)', 'the start fails with the exit';

  my $said = index_of(\@lines, qr/^debug \[dying\] no such file: \/etc\/x\.json$/);
  my $exit = index_of(\@lines, qr/^warn \[dying\] child exited \(code 3\)/);
  ok $said >= 0, 'what it wrote last is logged' or diag explain \@lines;
  ok index_of(\@lines, qr/^debug \[dying\] loading config$/) >= 0, 'and what it wrote before';
  ok $said >= 0 && $exit > $said, 'before the exit is';
  is $up->state, 'stopped', 'stopped';
};

subtest 'a process that writes on to the pipe is not waited for' => sub {
  # The child exits; a process it leaves behind holds only the stderr pipe and
  # writes to it without end. The exit is handled all the same, at once. The
  # writer ends once the pipe is gone (its write fails: SIGPIPE is ignored, as
  # in the hub) and after a minute at the latest; the test kills it anyway.
  my @lines;
  my $dir     = tempdir;    # held: the child writes the writer's pid into it
  my $pidfile = $dir->child('writer.pid');
  my $up      = MCP::Hub::Upstream::Stdio->new(
    name      => 'chatty',
    config    => {type => 'stdio', command => $^X, args => ['-e', <<~'CODE', "$pidfile"]},
      my $pid = fork // die "fork: $!\n";
      if (!$pid) {
        close STDIN; close STDOUT; $| = 1;
        my $end = time + 60;
        while (time < $end) { print STDERR 'x' x 99, "\n" or last }
        exit 0;
      }
      open my $fh, '>', $ARGV[0] or do { kill 'KILL', $pid; print STDERR "$ARGV[0]: $!\n"; exit 9 };
      print $fh $pid; close $fh;
      exit 2;
      CODE
    cache_dir => $dir->to_string,
    log       => log_to(\@lines),
  );
  my $t0     = time;
  my $r      = start_unwatched($up);
  my $took   = time - $t0;
  my $writer = -s $pidfile ? $pidfile->slurp : undef;

  is $r->{err}, 'upstream chatty: exited (code 2)', 'the exit is reported';
  ok $writer, 'the writer was started' or diag $r->{err};
  cmp_ok $took, '<', 10, sprintf 'without waiting for the writer (%.1fs)', $took;
  ok +(grep { /^debug \[chatty\] x{99}$/ } @lines), 'what it had written is logged';
  cmp_ok scalar(grep {/^debug \[chatty\]/} @lines), '<', 11_000, 'no more than 1 MB of it';
  is $up->state, 'stopped', 'stopped';

  if ($writer) {
    ok wait_until(sub { !kill 0, $writer }, 10), 'the writer ends once the pipe is gone';
    kill 'KILL', $writer if kill 0, $writer;
    ok wait_until(sub { !kill 0, $writer }, 10), 'and is gone';
  }
};

subtest 'a forked worker: why it died is in the exit warning' => sub {
  plan skip_all => 'forked class workers need Linux (/proc/self/fd)' unless -d '/proc/self/fd';

  # A class whose constructor works in the hub and dies in a worker.
  package WorkerDiesHere {
    use Mojo::Base 'EchoServer', -signatures;
    sub new ($class, @args) {
      die "no wiki at /nowhere\n" if $0 =~ /^mcp-hub-worker/;
      return $class->SUPER::new(@args);
    }
  }

  my @lines;
  my $up = MCP::Hub::Upstream::Fork->new(
    name      => 'dies',
    config    => {type => 'fork', class => 'WorkerDiesHere'},
    cache_dir => tempdir->to_string,
    log       => log_to(\@lines),
  );
  my $r = start_unwatched($up);
  is $r->{err}, 'upstream dies: exited (code 3)', 'the worker exits with 3';
  ok +(grep { $_ eq 'warn [dies] child exited (code 3) while starting WorkerDiesHere: worker failed: no wiki at /nowhere' }
    @lines), 'and the warning says why' or diag explain \@lines;
};

done_testing;
