#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;

use Mojo::File    qw(curfile tempdir);
use Mojo::JSON    qw(encode_json);
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

# A reload stops the upstream it removes or replaces, and lets go of it -- but
# its child is given seven seconds after its EOF, and this one stays on for all
# of them. A shutdown right after the reload is over once that child is gone
# too, not merely once the upstreams the hub now has are. The replacement
# differs from it only in its env, so it shares its manifest and starts lazily,
# with no child of its own to wait for.
for my $case (
  [removes  => removed => {}],
  [replaces => changed => {stays => {command => $^X, args => ['-Ilib', "$ECHO", '--ignore-eof'], env => {K125 => 1}}}],
) {
  my ($what, $key, $servers) = @$case;
  subtest "a shutdown waits for the child of an upstream a reload $what" => sub {
    my $dir  = tempdir;
    my $file = $dir->child('config.json');
    my $settings = {cache_dir => $dir->child('cache')->to_string};
    my $inproc = {inproc => {class => 'EchoServer'}};
    $file->spew(encode_json({
      mcpServers => {stays => {command => $^X, args => ['-Ilib', "$ECHO", '--ignore-eof']}, %$inproc},
      hub        => $settings,
    }));
    my $hub = MCP::Hub->new(log => quiet_log(), hub_config_input => "$file");
    my $old = $hub->upstreams_by_name->{stays};
    my $r   = await_bounded($old->start_p, 30);
    ok $r->{ok}, 'the upstream started' or diag $r->{err};
    my $pid = $old->stats->{pid};
    ok $pid, 'it has a child';

    $file->spew(encode_json({mcpServers => {%$servers, %$inproc}, hub => $settings}));
    my $summary = $hub->reload;
    is_deeply $summary->{$key}, ['stays'], "the reload $what it";
    ok kill(0, $pid), 'its child is still running, after its EOF';
    if (my $new = $hub->upstreams_by_name->{stays}) {
      isnt $new, $old, 'a new upstream stands in for it';
      is $new->stats->{pid}, undef, 'with no child';
    }

    $r = await_bounded($hub->shutdown_p, 20);
    ok $r->{ok}, 'the shutdown is over' or diag $r->{err};
    is $old->stats->{pid}, undef, 'the old upstream has no child by then';
    ok !kill(0, $pid), 'and its child is reaped';
  };
}

done_testing;
