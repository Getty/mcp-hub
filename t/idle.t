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
