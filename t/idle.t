#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File    qw(curfile tempdir);
use Mojo::Log;
use Mojo::Promise;
use MCP::Hub::Upstream;
use MCP::Hub::Upstream::Perl;
use MCP::Hub::Upstream::Stdio;
use Time::HiRes qw(time);

use lib curfile->sibling('lib')->to_string;

# The idle timer: what touch and apply_timeouts do to it, for an upstream that
# stops its process when idle and for one that never does. Its idle stop
# itself is covered with each kind (t/stdio.t, t/fork.t, t/docker.t).

my $ECHO = curfile->sibling('upstream', 'echo.pl');

sub quiet () { my $log = Mojo::Log->new; $log->unsubscribe('message'); return $log }

# A log that keeps its lines, [time, "level message"], instead of printing them.
sub log_to ($lines) {
  my $log = quiet();
  $log->on(message => sub ($l, $level, @msg) { push @$lines, [time, "$level @msg"] });
  return $log;
}

# When the idle stop came, by its log line -- or undef.
sub idle_stop_at ($lines) { my ($stop) = grep { $_->[1] =~ /idle for/ } @$lines; return $stop && $stop->[0] }

# An upstream that idles and whose requests the test answers by hand: no
# process, nothing but the base class's idle countdown.
package Held {
  use Mojo::Base 'MCP::Hub::Upstream', -signatures;
  has idle_timeout => 1;
  has held         => sub { [] };
  sub start_p ($self) { $self->state('ready'); return Mojo::Promise->resolve($self) }
  sub stop    ($self) { $self->state('stopped'); return $self }
  sub _request_p ($self, $method, $params) { push @{$self->held}, my $p = Mojo::Promise->new; return $p }
}

sub upstream (%config) {
  return MCP::Hub::Upstream::Stdio->new(
    name      => 'echo',
    config    => {type => 'stdio', command => $^X, args => ['-Ilib', "$ECHO"], %config},
    cache_dir => tempdir->to_string,
    log       => quiet(),
  );
}

sub await_bounded ($promise, $seconds = 30) {
  my $out;
  Mojo::Promise->race(Mojo::Promise->timeout($seconds), $promise)
    ->then(sub { $out = shift })->catch(sub { $out = {err => shift} })->wait;
  return $out;
}

sub wait_until ($cond, $seconds = 10) {
  my $deadline = time + $seconds;
  Mojo::Promise->timer(0.05)->wait until $cond->() || time > $deadline;
  return $cond->();
}

subtest 'a shorter idle_timeout re-arms the timer of a running child' => sub {
  my $up = upstream(idle_timeout => 300);
  await_bounded($up->start_p);
  is $up->state, 'ready', 'ready, with 300 seconds to go';

  $up->apply_timeouts({idle_timeout => 1});
  is $up->idle_timeout, 1, 'the new timeout is applied';
  ok wait_until(sub { $up->state eq 'stopped' }), 'and the child stops after it, not after the old one';
};

subtest 'an idle_timeout of 0 stops the countdown' => sub {
  my $up = upstream(idle_timeout => 1);
  await_bounded($up->start_p);
  $up->apply_timeouts({idle_timeout => 0});
  Mojo::Promise->timer(1.6)->wait;
  is $up->state, 'ready', 'still running after the old timeout';
  ok $up->stats->{pid}, 'with its child';
  $up->stop;
  ok wait_until(sub { !$up->stats->{pid} }), 'stopped';
};

subtest 'a request re-arms the timer' => sub {
  my $up = upstream(idle_timeout => 2);
  await_bounded($up->start_p);
  for (1 .. 3) {
    Mojo::Promise->timer(1)->wait;
    await_bounded($up->call_tool('echo', {msg => 'x'}));
  }
  is $up->state, 'ready', 'three seconds of requests, a second apart, keep it running';
  ok wait_until(sub { $up->state eq 'stopped' }), 'and it stops once they end';
};

subtest 'a call longer than idle_timeout is not stopped under it' => sub {
  # The countdown started with the call, and the child was sent its EOF a
  # second into this one: the start of a stop, while the call was running.
  my @lines;
  my $up   = upstream(idle_timeout => 1);
  $up->log(log_to(\@lines));
  my $call = $up->call_tool('sleep', {seconds => 2});    # idle_timeout + 1
  my $pid  = $up->stats->{pid};
  my $r    = await_bounded($call);
  my $end  = time;
  is $r->{content}[0]{text}, 'slept 2', 'the call is answered' or diag explain $r;
  Mojo::Promise->timer(0.3)->wait;    # what a stop under it would have ended by now
  is idle_stop_at(\@lines), undef, 'with no idle stop while it ran';
  is $up->state, 'ready', 'the upstream is ready';
  is $up->stats->{pid}, $pid, 'with the child that answered';
  ok wait_until(sub { $up->state eq 'stopped' }), 'which stops once idle';
  cmp_ok idle_stop_at(\@lines) // 0, '>=', $end + 0.9, 'idle_timeout after the call ended';
};

subtest 'a call longer than idle_timeout and the grace of a stop is answered' => sub {
  # Two seconds after the EOF a stop sends SIGTERM: a call that ran past both
  # was killed with its child.
  my $up = upstream(idle_timeout => 1);
  my $r  = await_bounded($up->call_tool('sleep', {seconds => 4}));
  is $r->{content}[0]{text}, 'slept 4', 'the call is answered' or diag explain $r;
  $up->stop;
  ok wait_until(sub { !$up->stats->{pid} }), 'stopped';
};

subtest 'the countdown starts when the last request in flight ends' => sub {
  my $up = Held->new(name => 'held', config => {type => 'held'}, log => quiet());
  my $ended = 0;
  $_->then(sub { $ended++ }) for $up->call_tool('a', {}), $up->get_prompt('b', {}), $up->read_resource('c://');
  ok wait_until(sub { @{$up->held} == 3 }), 'a call, a prompt and a resource in flight';
  ok !$up->{idle_timer}, 'no countdown while they run';
  $up->apply_timeouts({idle_timeout => 2});
  ok !$up->{idle_timer}, 'nor from a new idle_timeout';

  $up->held->[0]->resolve({content => []});
  $up->held->[1]->reject('upstream held: nope');
  ok wait_until(sub { $ended == 2 }), 'two of them end';
  ok !$up->{idle_timer}, 'and the one left holds the countdown off';

  $up->held->[2]->resolve({contents => []});
  ok wait_until(sub { $up->{idle_timer} }), 'which starts when it ends';
  ok wait_until(sub { $up->state eq 'stopped' }), 'and stops the upstream';
};

subtest 'a refresh longer than idle_timeout is not stopped under it' => sub {
  # Only calls held the countdown off. A refresh of the running child asks it
  # for one list after another, and the idle stop came between two of them: it
  # sent the EOF, and the next list was refused -- taken for an empty one, so
  # the refresh lost that list, and the child it was asking went.
  my @lines;
  my $up = upstream(idle_timeout => 1);
  $up->log(log_to(\@lines));
  await_bounded($up->call_tool('slow_lists', {seconds => 0.7}));    # three lists: 2.1 s
  await_bounded($up->call_tool('notify', {what => 'tools', quiet => \1}));
  my $pid = $up->stats->{pid};

  my $refreshed = await_bounded($up->refresh_p);
  my $end       = time;
  is $refreshed, $up, 'the refresh is through' or diag explain $refreshed;
  Mojo::Promise->timer(0.3)->wait;    # what a stop under it would have ended by now
  is idle_stop_at(\@lines), undef, 'with no idle stop while it ran';
  is $up->state, 'ready', 'the upstream is ready';
  is $up->stats->{pid}, $pid, 'with the child it asked';
  ok +(grep { $_->name eq 'echo2' } @{$up->server->tools}), 'whose new tool the refresh found';
  is_deeply [map { $_->name } @{$up->server->prompts}],  ['greet'],         'with its prompts';
  is_deeply [map { $_->uri } @{$up->server->resources}], ['echo://readme'], 'and its resources';
  ok wait_until(sub { $up->state eq 'stopped' }), 'which stops once idle';
  cmp_ok idle_stop_at(\@lines) // 0, '>=', $end + 0.9, 'idle_timeout after the refresh ended';
};

subtest 'apply_timeouts on a stopped child arms nothing' => sub {
  my $up = upstream(idle_timeout => 300);
  $up->apply_timeouts({idle_timeout => 1, request_timeout => 7});
  is $up->idle_timeout,    1, 'the idle_timeout is taken';
  is $up->request_timeout, 7, 'and the request_timeout';
  ok !$up->{idle_timer}, 'with no timer, as there is no child';
};

subtest 'an upstream that never idles has no idle timer' => sub {
  my $up = MCP::Hub::Upstream->build({name => 'echo', type => 'perl', class => 'EchoServer'});
  ok !$up->can('idle_timeout'), 'an in-process server has no idle_timeout';
  $up->touch;
  ok $up->last_used, 'touch records the request';
  ok !$up->{idle_timer}, 'and arms nothing';
  $up->apply_timeouts({idle_timeout => 1, request_timeout => 9});
  is $up->request_timeout, 9, 'apply_timeouts takes the request_timeout';
  ok !$up->{idle_timer}, 'and ignores the idle_timeout';
};

done_testing;
