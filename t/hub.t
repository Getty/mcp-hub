#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File    qw(curfile tempdir);
use Mojo::Log;
use Mojo::Promise;
use MCP::Hub;
use MCP::Client;

my $ECHO     = curfile->sibling('upstream', 'echo.pl');
my $FIXTURES = curfile->sibling('fixtures', 'claude')->to_string;

sub open_config ($cache) {
  return {
    mcpServers => {
      echo    => {command => $^X, args => ['-Ilib', "$ECHO"]},
      history => {class => 'MCP::Hub::Native::ClaudeHistory', args => {root => $FIXTURES}},
      hub     => {class => 'MCP::Hub::Native::Status'},
    },
    hub => {cache_dir => "$cache"},
  };
}

# Warm the manifest cache so the real test runs against a cached, lazy hub.
sub warm_cache ($config) {
  my $app      = MCP::Hub->new(hub_config_input => $config);
  $app->start_background_fetches;
  my $deadline = time + 15;
  until (time > $deadline) {
    Mojo::Promise->timer(0.1)->wait;
    last unless grep { $_->type eq 'stdio' && !$_->manifest_fetched_at } @{$app->upstreams};
  }
  $_->stop for @{$app->upstreams};
  Mojo::Promise->timer(0.3)->wait;
  return $app;
}

sub client ($t, $path) {
  my $base = $t->ua->server->url->to_string;
  $base =~ s{/$}{};
  return MCP::Client->new(ua => $t->ua, url => "$base$path");
}

sub wait_until ($cond, $seconds = 10) {
  my $deadline = time + $seconds;
  Mojo::Promise->timer(0.05)->wait until $cond->() || time > $deadline;
  return $cond->();
}

# Settle a promise: its value, or {err => ...} when it was rejected.
sub settle ($promise) {
  my $out;
  $promise->then(sub ($v) { $out = $v }, sub ($e) { $out = {err => $e} })->wait;
  return $out;
}

# ---------------------------------------------------------------------------

subtest 'open mode: lazy start, per-server endpoints, aggregate' => sub {
  my $cache = tempdir;
  warm_cache(open_config("$cache"));

  my $app = MCP::Hub->new(hub_config_input => open_config("$cache"));
  my $t   = Test::Mojo->new($app);
  my ($echo) = grep { $_->name eq 'echo' } @{$app->upstreams};

  is $echo->state, 'stopped', 'stdio upstream stopped at start';
  is $echo->stats->{pid}, undef, 'no process before any call';
  ok scalar(@{$echo->server->tools}) >= 6, 'tools known from the cache';

  my $ec    = client($t, '/echo');
  my $tools = $ec->list_tools;
  is_deeply [sort map { $_->{name} } @{$tools->{tools}}], [sort qw(echo sleep fail die exit notify)],
    'tool names are unchanged (no prefix on a per-server endpoint)';
  is $echo->stats->{pid}, undef, 'tools/list did not spawn the child';

  my $res = $ec->call_tool('echo', {msg => 'hi hub'});
  is $res->{content}[0]{text}, 'hi hub', 'tool call forwarded to the child';
  ok $echo->stats->{pid}, 'child spawned on the first tool call';

  # Perl upstream, in-process, no subprocess.
  my $hc  = client($t, '/history');
  my $lp  = $hc->call_tool('list_projects', {});
  ok !${$lp->{isError} // \0}, 'history list_projects ok';

  # Aggregate: every upstream's tools, prefixed.
  my $all = client($t, '/all')->list_tools;
  my %names = map { $_->{name} => 1 } @{$all->{tools}};
  ok $names{'echo__echo'},               'echo tool prefixed in /all';
  ok $names{'history__list_projects'},   'history tool prefixed in /all';
  ok $names{'hub__hub_status'},          'status tool prefixed in /all';

  my $agg_res = client($t, '/all')->call_tool('echo__echo', {msg => 'aggregated'});
  is $agg_res->{content}[0]{text}, 'aggregated', 'aggregate tool call forwards correctly';

  # Admin API is open in open mode.
  $t->get_ok('/_hub/status')->status_is(200)->json_is('/mode', 'open');
  $t->json_has('/upstreams');

  $_->stop for @{$app->upstreams};
  Mojo::Promise->timer(0.3)->wait;
};

subtest 'clients mode: tokens, profiles, 401/404/403' => sub {
  my $config = {
    mcpServers => {
      history => {class => 'MCP::Hub::Native::ClaudeHistory', args => {root => $FIXTURES}},
      hub     => {class => 'MCP::Hub::Native::Status'},
    },
    hub => {
      profiles => {
        full    => {servers => ['*'], admin => \1},
        limited => {servers => ['history']},
      },
      clients => {
        main   => {token => 'tok-main',   profile => 'full'},
        worker => {token => 'tok-worker', profile => 'limited'},
      },
    },
  };
  my $app = MCP::Hub->new(hub_config_input => $config);
  my $t   = Test::Mojo->new($app);

  my $rpc = {jsonrpc => '2.0', id => 1, method => 'tools/list', params => {}};

  # No token -> 401.
  $t->post_ok('/history' => json => $rpc)->status_is(401)
    ->header_is('WWW-Authenticate' => 'Bearer');

  # Wrong token -> 401.
  $t->post_ok('/history' => {Authorization => 'Bearer nope'} => json => $rpc)->status_is(401);

  # worker may see history...
  $t->post_ok('/history' => {Authorization => 'Bearer tok-worker'} => json => $rpc)->status_is(200);

  # ...but not hub (404, indistinguishable from "does not exist").
  $t->post_ok('/hub' => {Authorization => 'Bearer tok-worker'} => json => $rpc)->status_is(404);

  # main (admin) sees everything.
  $t->post_ok('/hub' => {Authorization => 'Bearer tok-main'} => json => $rpc)->status_is(200);

  # Admin API: main yes, worker no.
  $t->get_ok('/_hub/status' => {Authorization => 'Bearer tok-main'})->status_is(200)
    ->json_is('/mode', 'clients');
  $t->get_ok('/_hub/status' => {Authorization => 'Bearer tok-worker'})->status_is(403);

  # Every client that authenticated above is stamped with a last_seen.
  my %seen = map { $_->{name} => $_ } @{$app->status_report->{clients}};
  ok $seen{main}{last_seen},   'status reports last_seen for main';
  ok $seen{worker}{last_seen}, 'status reports last_seen for worker';
};

subtest 'an upstream that cannot be built stays visible' => sub {
  my %servers = (
    broken  => {class => 'No::Such::Native::Class'},
    history => {class => 'MCP::Hub::Native::ClaudeHistory', args => {root => $FIXTURES}},
  );
  my $rpc = {jsonrpc => '2.0', id => 1, method => 'tools/list', params => {}};

  my $app = MCP::Hub->new(hub_config_input => {mcpServers => \%servers});
  my $t   = Test::Mojo->new($app);

  my ($row) = grep { $_->{name} eq 'broken' } @{$app->status_report->{upstreams}};
  ok $row, 'the broken entry is still reported in the status';
  is $row->{state}, 'failed', 'reported as failed';
  like $row->{error}, qr/No::Such::Native::Class/, 'with the reason';

  # Its endpoint says why instead of pretending the server does not exist.
  $t->post_ok('/broken' => json => $rpc)->status_is(503)
    ->json_like('/error', qr/No::Such::Native::Class/);

  # The healthy servers are unaffected.
  $t->post_ok('/history' => json => $rpc)->status_is(200);

  # The setup page shows it as unavailable rather than hiding it.
  $t->get_ok('/')->status_is(200)->content_like(qr/Unavailable/, 'setup page marks it unavailable');

  # A profile that may not see it still gets a 404, not a 503.
  my $gated = MCP::Hub->new(hub_config_input => {
    mcpServers => \%servers,
    hub        => {
      profiles => {limited => {servers => ['history']}},
      clients  => {worker => {token => 'tok-worker', profile => 'limited'}},
    },
  });
  Test::Mojo->new($gated)
    ->post_ok('/broken' => {Authorization => 'Bearer tok-worker'} => json => $rpc)->status_is(404);
};

subtest 'a warming fetch that fails is failed, with the reason, until a refresh' => sub {
  # Before the fix such an upstream went back to `stopped` with no error, and
  # its endpoint answered 503 "not ready yet" -- the still-fetching meaning --
  # for good, though nothing was fetching any more.
  my $tmp  = tempdir;
  my $flag = $tmp->child('up');
  my $rpc  = {jsonrpc => '2.0', id => 1, method => 'tools/list', params => {}};
  my $app  = MCP::Hub->new(hub_config_input => {
    mcpServers => {
      # Exits 1 until the flag file exists, and is echo.pl from then on.
      gated   => {command => $^X, args => ['-e', 'exit 1 unless -e $ARGV[0]; exec $^X, "-Ilib", $ARGV[1]', "$flag", "$ECHO"]},
      # exec fails: the child _exit()s with 127.
      missing => {command => $tmp->child('no-such-mcp-server')->to_string},
      # always_on with no cached manifest: its start is the warming fetch.
      always  => {command => $^X, args => ['-e', 'exit 1'], hub => {always_on => \1}},
    },
    hub => {cache_dir => $tmp->child('cache')->to_string},
  });
  $app->log->level('fatal');
  my $t  = Test::Mojo->new($app);
  my %up = %{$app->upstreams_by_name};

  $app->start_background_fetches;
  ok wait_until(sub { !grep { $_->state ne 'failed' } values %up }), 'every warming fetch ends in failed'
    or diag explain {map { $_ => $up{$_}->state } keys %up};

  my %why = (gated => 'exited (code 1)', always => 'exited (code 1)', missing => 'exited (code 127)');
  for my $name (qw(gated missing always)) {
    is $up{$name}->error, $why{$name}, "$name: the reason, without a second upstream prefix";
    my ($row) = grep { $_->{name} eq $name } @{$app->status_report->{upstreams}};
    is $row->{state}, 'failed', "$name: the status says failed";
    is $row->{error}, $up{$name}->error, "$name: and why";
    $t->post_ok("/$name" => json => $rpc)->status_is(503, "$name: 503")
      ->json_is('/error', "upstream '$name' failed: " . $up{$name}->error, "$name: the failed meaning")
      ->json_unlike('/error', qr/not ready yet/, "$name: not the still-fetching one");
  }

  # A call does not start it again: only a refresh does.
  my $started = $up{gated}->stats->{started_at};
  my $call    = settle($up{gated}->call_tool('echo', {msg => 'x'}));
  like $call->{content}[0]{text}, qr/run 'mcp-hub refresh gated' to try again/, 'a call says how to get out';
  is $up{gated}->stats->{started_at}, $started, 'and spawns nothing';
  is $up{gated}->state, 'failed', 'it stays failed';

  # A refresh that fails again leaves it failed with the reason -- not back in
  # the "not ready yet" it was stuck in before.
  my $again = settle($app->refresh_p('gated'));
  is $again->{gated}{state}, 'failed', 'a refresh that fails again: failed';
  is $again->{gated}{error}, 'exited (code 1)', 'and the refresh result says why';
  $t->post_ok('/gated' => json => $rpc)->status_is(503)->json_like('/error', qr/^upstream 'gated' failed: /);

  # Fix the cause, refresh: the failure is cleared and the tools are there.
  $flag->spew('');
  my $back = settle($app->refresh_p('gated'));
  is $back->{gated}{state}, 'ready', 'once the cause is gone a refresh brings it back';
  ok $back->{gated}{count} >= 6, 'with its tools';
  is $up{gated}->error, undef, 'and no reason any more';
  $t->post_ok('/gated' => json => $rpc)->status_is(200);
  ok scalar(grep { $_->{name} eq 'echo' } @{client($t, '/gated')->list_tools->{tools}}), 'tools/list answers';

  $_->stop for values %up;
  Mojo::Promise->timer(0.3)->wait;
};

subtest 'a failed start of an upstream with a cached manifest is not failed' => sub {
  # Only a fetch that leaves the upstream with nothing to list makes it failed.
  # With a cached manifest tools/list is answered, and the next call starts it
  # again under its crash-loop rule -- here an always_on start at daemon start.
  my $tmp    = tempdir;
  my $flag   = $tmp->child('up');
  my $rpc    = {jsonrpc => '2.0', id => 1, method => 'tools/list', params => {}};
  my $config = {
    mcpServers => {gated => {command => $^X, args => ['-e', 'exit 1 unless -e $ARGV[0]; exec $^X, "-Ilib", $ARGV[1]', "$flag", "$ECHO"],
      hub => {always_on => \1}}},
    hub => {cache_dir => $tmp->child('cache')->to_string},
  };

  $flag->spew('');
  my $warm = MCP::Hub->new(hub_config_input => $config);
  $warm->start_background_fetches;
  ok wait_until(sub { $warm->upstreams->[0]->manifest_fetched_at }), 'the manifest is cached';
  $warm->upstreams->[0]->stop;
  Mojo::Promise->timer(0.3)->wait;
  $flag->remove;

  my $app = MCP::Hub->new(hub_config_input => $config);
  $app->log->level('fatal');
  my $up = $app->upstreams->[0];
  $app->start_background_fetches;
  ok wait_until(sub { $up->state eq 'stopped' }), 'its start fails';
  Mojo::Promise->timer(0.3)->wait;
  is $up->state, 'stopped', 'stopped, not failed';
  is $up->error, undef, 'with no reason';
  Test::Mojo->new($app)->post_ok('/gated' => json => $rpc)->status_is(200, 'tools/list answers from the cache');
};

subtest '503 "not ready yet" means a fetch is under way' => sub {
  my $rpc    = {jsonrpc => '2.0', id => 1, method => 'tools/list', params => {}};
  my $cache  = tempdir;
  my $config = {
    # echo.pl, a second late.
    mcpServers => {slow => {command => $^X, args => ['-e', 'sleep 1; exec $^X, "-Ilib", $ARGV[0]', "$ECHO"]}},
    hub        => {cache_dir => "$cache"},
  };

  # With no background fetch started, nothing is fetching: the endpoint must
  # not claim otherwise, and tools/list spawns nothing (lazy start).
  my $idle = MCP::Hub->new(hub_config_input => $config);
  Test::Mojo->new($idle)->post_ok('/slow' => json => $rpc)->status_is(503)
    ->json_is('/error', "upstream 'slow' has no tool list yet, run 'mcp-hub refresh slow' to fetch it");
  is $idle->upstreams->[0]->stats->{started_at}, undef, 'tools/list started nothing';

  my $app = MCP::Hub->new(hub_config_input => $config);
  my $t   = Test::Mojo->new($app);
  my $up  = $app->upstreams->[0];
  $app->start_background_fetches;
  is $up->state, 'starting', 'the warming fetch is under way';
  $t->post_ok('/slow' => json => $rpc)->status_is(503)->json_is('/error', "upstream 'slow' is not ready yet");
  ok wait_until(sub { $up->manifest_fetched_at }), 'until it is done';
  $t->post_ok('/slow' => json => $rpc)->status_is(200);

  $up->stop;
  Mojo::Promise->timer(0.3)->wait;
};

subtest 'refresh via the admin API' => sub {
  my $config = {
    mcpServers => {
      history => {class => 'MCP::Hub::Native::ClaudeHistory', args => {root => $FIXTURES}},
      broken  => {class => 'No::Such::Class'},
    },
  };
  my $app = MCP::Hub->new(hub_config_input => $config);
  my $t   = Test::Mojo->new($app);
  $t->post_ok('/_hub/refresh' => json => {})->status_is(200)
    ->json_is('/history/count', 4)->json_is('/history/state', 'ready')
    ->json_is('/broken/state', 'failed')->json_like('/broken/error', qr/No::Such::Class/);
};

subtest 'the build error of a placeholder is logged once' => sub {
  # The warm-up used to call start_p on the failed placeholder of a non-perl
  # entry (here a forked class), and that rejection logged the build error a
  # second time.
  my @log;
  my $log = Mojo::Log->new(level => 'debug');
  $log->unsubscribe('message')->on(message => sub ($l, $level, @lines) { push @log, "$level: @lines" });
  my $cache = tempdir;
  my $app   = MCP::Hub->new(log => $log, hub_config_input => {
    mcpServers => {broken => {class => 'No::Such::Forked::Class', hub => {fork => \1}}},
    hub        => {cache_dir => "$cache"},
  });
  my $up = $app->upstreams_by_name->{broken};
  ok $up->placeholder, 'the entry is a placeholder';
  is $up->type, 'fork', 'of a type that is warmed';

  $app->start_background_fetches;
  Mojo::Promise->timer(0.2)->wait;
  my @logged = grep { index($_, $up->error) >= 0 } @log;
  is scalar @logged, 1, 'its build error is logged exactly once' or diag explain \@log;
  like $logged[0], qr/^error: failed to build upstream broken: /, 'when it was built';
  is $up->state, 'failed', 'and it stays failed';
};

subtest 'config command output' => sub {
  # open mode
  my $open = MCP::Hub->new(hub_config_input => open_config(tempdir));
  my $data = $open->export_config;
  ok $data->{mcpServers}{echo}, 'open mode emits an entry per server';
  is $data->{mcpServers}{echo}{type}, 'http', 'http entry';
  like $data->{mcpServers}{echo}{url}, qr{/echo$}, 'url ends in the server name';
  ok !$data->{mcpServers}{echo}{headers}, 'no auth header in open mode';

  # clients mode
  my $clients = MCP::Hub->new(hub_config_input => {
    mcpServers => {history => {class => 'MCP::Hub::Native::ClaudeHistory', args => {root => $FIXTURES}}, hub => {class => 'MCP::Hub::Native::Status'}},
    hub => {
      profiles => {limited => {servers => ['history']}, full => {servers => ['*'], admin => \1}},
      clients  => {worker => {token => 'sekret', profile => 'limited'}, main => {token => 'm', profile => 'full'}},
    },
  });
  my $wcfg = $clients->export_config(client => 'worker');
  ok $wcfg->{mcpServers}{history}, 'worker sees history';
  ok !$wcfg->{mcpServers}{hub},    'worker does not see hub';
  is $wcfg->{mcpServers}{history}{headers}{Authorization}, 'Bearer sekret', 'auth header carries the token';

  my $all = $clients->export_config(client => 'main', all => 1);
  is_deeply [keys %{$all->{mcpServers}}], ['hub'], '--all emits a single hub entry';
  like $all->{mcpServers}{hub}{url}, qr{/all$}, 'points at /all';

  # running the actual command prints JSON
  my $out = '';
  open my $fh, '>', \$out or die;
  my $old = select $fh;
  $open->start('config');
  select $old;
  like $out, qr/"mcpServers"/, 'config command prints mcpServers JSON';
};

done_testing;
