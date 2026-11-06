#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File    qw(curfile tempdir);
use Mojo::Promise;
use MCP::Hub;
use MCP::Client;

use lib curfile->sibling('lib')->to_string;

# What a manifest refresh tells the agents that listen: on the upstream's own
# endpoint a list_changed for each of its lists that changed, on /all one for
# each of the lists /all shows (tools and prompts, it aggregates no
# resources) -- and for a refresh that changed nothing, nothing. The listeners
# are real subscriptions/listen streams, as in t/reload.t.

my $ECHO = curfile->sibling('upstream', 'echo.pl')->to_string;

my %ENTRY = (
  stdio => {command => $^X, args => ['-Ilib', $ECHO]},
  fork  => {class => 'EchoServer', hub => {fork => \1}},
);

sub hub ($entry) {
  my $cache = tempdir;
  my $app   = MCP::Hub->new(hub_config_input => {mcpServers => {echo => $entry}, hub => {cache_dir => "$cache"}});
  $app->log->level('fatal');
  return $app;
}

sub client ($t, $path) {
  my $base = $t->ua->server->url->to_string;
  $base =~ s{/$}{};
  return MCP::Client->new(ua => $t->ua, url => "$base$path");
}

# Settle a promise: its value, or {err => ...} when it was rejected.
sub settle ($promise) {
  my $out;
  $promise->then(sub ($v) { $out = $v }, sub ($e) { $out = {err => $e} })->wait;
  return $out;
}

for my $type (sort keys %ENTRY) {
  next if $type eq 'fork' && !-d '/proc/self/fd';    # a forked worker needs Linux

  for my $path ('/echo', '/all') {
    subtest "$type: a refresh tells a listener on $path what changed, and nothing else" => sub {
      my $app  = hub($ENTRY{$type});
      my $t    = Test::Mojo->new($app);
      my $echo = $app->upstreams_by_name->{echo};
      # The guard for a notification that never comes: the stream then goes
      # quiet and is dropped, instead of the test hanging.
      $t->ua->inactivity_timeout(5);

      # Running, with its manifest: a refresh of it asks it for its lists again.
      is settle($echo->start_p), $echo, 'the upstream is running';
      my $pid = $echo->stats->{pid};

      # Each step changes one list of the upstream -- or, the first, none --
      # without announcing it, and has the hub refresh it. Last comes a
      # notification sent by hand: what the listener hears before it is all the
      # refreshes told it.
      my $server = $path eq '/all' ? $app->aggregate : $echo->server;
      my $change = sub ($what) {
        return sub { $echo->call_tool('notify', {what => $what, quiet => \1})->then(sub { $app->refresh_p('echo') }) };
      };
      my @steps = (
        sub { $app->refresh_p('echo') },
        $change->('resources'),
        $change->('tools'),
        $change->('prompts'),
        sub { $server->notify_list_changed('resources'); return },
      );

      # What the listener is to hear, the one sent by hand last.
      my $expect = $path eq '/all' ? [qw(tools prompts resources)] : [qw(resources tools prompts resources)];

      my (@heard, @refreshed);
      client($t, $path)->listen({toolsListChanged => \1, promptsListChanged => \1, resourcesListChanged => \1}, sub ($message) {
        my $method = $message->{method} // '';
        if ($method eq 'notifications/subscriptions/acknowledged') {
          my $chain = Mojo::Promise->resolve;
          for my $step (@steps) {
            $chain = $chain->then($step)->then(sub ($counts = undef) { push @refreshed, $counts if $counts; return });
          }
          $chain->catch(sub ($err) { push @refreshed, {err => "$err"} });
          return 1;
        }
        push @heard, $method =~ s{^notifications/(\w+)/list_changed$}{$1}r;
        return @heard < @$expect;
      });

      is scalar(@refreshed), 4, 'four refreshes' or diag explain \@refreshed;
      is_deeply [map { $_->{echo}{state} // $_->{err} } @refreshed], [('ready') x 4], 'all of them through';
      is $echo->stats->{pid}, $pid, 'by the child that was running';
      is_deeply \@heard, $expect,
        $path eq '/all'
        ? 'the listener on /all hears of the tools and the prompts that changed, then the one sent by hand'
        : 'the listener on the endpoint hears of each list that changed, then the one sent by hand';
      ok +(grep { $_->name eq 'echo__echo2' } @{$app->aggregate->tools}),    '/all lists the new tool';
      ok +(grep { $_->name eq 'echo__greet2' } @{$app->aggregate->prompts}), 'and the new prompt';

      $echo->stop;
      settle($echo->stopped_p);
      ok !$echo->stats->{pid}, 'stopped';
    };
  }
}

done_testing;
