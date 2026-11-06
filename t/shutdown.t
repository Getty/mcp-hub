#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;

use Mojo::File    qw(curfile tempdir);
use Mojo::Log;
use Mojo::Promise;
use MCP::Hub;
use MCP::Hub::Upstream::Stdio;

use lib curfile->sibling('lib')->to_string;

# A shutdown is over once every child the hub stopped is gone -- its exit
# handled, not merely signalled. The daemon exits when it is: a child still
# running then would never get the signal that ends it (MCP::Hub/shutdown_p,
# MCP::Hub::Upstream/stopped_p).

my $ECHO = curfile->sibling('upstream', 'echo.pl');

sub quiet_log () {
  my $log = Mojo::Log->new;
  $log->unsubscribe('message');
  return $log;
}

sub await_bounded ($promise, $seconds) {
  my $out;
  Mojo::Promise->race(Mojo::Promise->timeout($seconds), $promise)
    ->then(sub { $out = {ok => 1} })->catch(sub { $out = {err => shift} })->wait;
  return $out;
}

subtest 'stopped_p of a stdio upstream with no child resolves at once' => sub {
  my $up = MCP::Hub::Upstream::Stdio->new(
    name      => 'idle',
    config    => {type => 'stdio', command => $^X, args => ['-Ilib', "$ECHO"]},
    cache_dir => tempdir->to_string,
    log       => quiet_log(),
  );
  $up->stop;
  my $resolved;
  $up->stopped_p->then(sub { $resolved = shift });
  Mojo::Promise->resolve->wait;    # one turn of the loop, no timer
  is $resolved, $up, 'resolved, with the upstream';
};

# The forked worker only where there are forked workers.
my $FORK = -d '/proc/self/fd';

for my $round (1 .. 3) {
  subtest "a shutdown resolves once every child is gone (round $round)" => sub {
    my $dir = tempdir;
    my $hub = MCP::Hub->new(log => quiet_log(), hub_config_input => {
      mcpServers => {
        echo => {command => $^X, args => ['-Ilib', "$ECHO"]},
        ($FORK ? (worker => {class => 'ForkProbe', hub => {fork => \1}}) : ()),
        inproc => {class => 'EchoServer'},
      },
      hub => {cache_dir => $dir->child('cache')->to_string},
    });
    my @names = grep { $_ ne 'inproc' } sort keys %{$hub->upstreams_by_name};
    my %pid;
    for my $name (@names) {
      my $up = $hub->upstreams_by_name->{$name};
      my $r  = await_bounded($up->start_p, 30);
      ok $r->{ok}, "$name started" or diag $r->{err};
      $pid{$name} = $up->stats->{pid};
      ok $pid{$name}, "$name has a child";
    }

    my $r = await_bounded($hub->shutdown_p, 20);
    ok $r->{ok}, 'the shutdown is over' or diag $r->{err};
    for my $name (@names) {
      my $up = $hub->upstreams_by_name->{$name};
      is $up->stats->{pid}, undef, "$name has no child by then";
      is $up->state, 'stopped', "$name is stopped";
      ok !kill(0, $pid{$name}), "$name\'s child is reaped";
    }
  };
}

done_testing;
