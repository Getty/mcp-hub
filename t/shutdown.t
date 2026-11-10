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

subtest 'a shutdown during a refresh calls the fetch off, it does not fail it' => sub {
  # The refresh of an upstream that has no manifest yet starts it, and the
  # shutdown stops it: the start is rejected as "upstream echo: stopped". The
  # refresh took that for a fetch that failed, left the upstream failed, with
  # "stopped" for the reason, and reported it so.
  my $dir = tempdir;
  my @logged;
  my $log = Mojo::Log->new;
  $log->unsubscribe('message');
  $log->on(message => sub ($l, $level, @msg) { push @logged, "$level @msg" });
  my $hub = MCP::Hub->new(log => $log, hub_config_input => {
    mcpServers => {echo => {command => $^X, args => ['-Ilib', "$ECHO"]}},
    hub        => {cache_dir => $dir->child('cache')->to_string},
  });
  my $up = $hub->upstreams_by_name->{echo};
  ok !$up->manifest_fetched_at, 'nothing cached';
  my $result;
  my $refresh = $hub->refresh_p('echo')->then(sub ($r) { $result = $r });
  is $up->state, 'starting', 'the refresh starts it';

  my $r = await_bounded($hub->shutdown_p, 20);
  ok $r->{ok}, 'the shutdown is over' or diag $r->{err};
  $r = await_bounded($refresh, 20);
  ok $r->{ok}, 'and so is the refresh' or diag $r->{err};
  my $row = $result ? $result->{echo} : {};
  ok $row->{state} && $row->{state} ne 'failed', 'it reports the upstream as called off, not failed'
    or diag explain $row;
  ok !exists $row->{error}, 'with no error' or diag explain $row;
  is $up->state, 'stopped', 'the upstream is left stopped';
  is $up->error, undef, 'not failed';
  is_deeply [grep { /^(?:warn|error|fatal) / } @logged], [], 'nor logged as a failure' or diag explain \@logged;
};

# A reload replaces an upstream whose child stays on after its EOF with an
# always_on one, whose start waits for that child to be gone
# (MCP::Hub/predecessors). A shutdown stops it meanwhile -- or a second reload
# removes it: the start is called off and starts nothing, no child that
# outlives the hub or that no one stops.
for my $how (qw(shutdown reload)) {
  subtest "a $how calls off a start waiting for the child of the upstream a reload replaced" => sub {
    my $dir      = tempdir;
    my $file     = $dir->child('config.json');
    my $settings = {cache_dir => $dir->child('cache')->to_string};
    my $entry    = {command => $^X, args => ['-Ilib', "$ECHO", '--ignore-eof']};
    $file->spew(encode_json({mcpServers => {stays => $entry}, hub => $settings}));
    my @logged;
    my $log = Mojo::Log->new;
    $log->unsubscribe('message');
    $log->on(message => sub ($l, $level, @msg) { push @logged, "$level @msg" });
    my $hub = MCP::Hub->new(log => $log, hub_config_input => "$file");
    my $old = $hub->upstreams_by_name->{stays};
    my $r   = await_bounded($old->start_p, 30);
    ok $r->{ok}, 'the upstream started' or diag $r->{err};
    my $pid = $old->stats->{pid};

    $file->spew(encode_json({mcpServers => {stays => {%$entry, hub => {always_on => \1}}}, hub => $settings}));
    is_deeply $hub->reload->{changed}, ['stays'], 'a reload replaces it';
    my $new = $hub->upstreams_by_name->{stays};
    my $start;
    $new->start_p->then(sub { $start = 'started' }, sub ($err) { $start = $err });
    is $new->state, 'starting', 'and the new upstream starts';
    is $new->stats->{pid}, undef, 'once the old child is gone';

    if ($how eq 'reload') {
      $file->spew(encode_json({mcpServers => {}, hub => $settings}));
      is_deeply $hub->reload->{removed}, ['stays'], 'a second reload removes it';
    }
    $r = await_bounded($hub->shutdown_p, 20);
    ok $r->{ok}, 'the shutdown is over' or diag $r->{err};
    ok !kill(0, $pid), 'the old child is reaped';
    is $start, 'upstream stays: stopped', 'the start is called off';
    is $new->state, 'stopped', 'the new upstream is stopped';
    is $new->stats->{pid}, undef, 'with no child';
    is scalar(grep {/\] started /} @logged), 1, 'none was started for it' or diag explain \@logged;
    is_deeply [grep { /^(?:warn|error|fatal) / } @logged], [], 'nor is a failure logged' or diag explain \@logged;
  };
}

done_testing;
