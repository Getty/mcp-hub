use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File    qw(curfile tempdir);
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

subtest 'refresh via the admin API' => sub {
  my $config = {
    mcpServers => {history => {class => 'MCP::Hub::Native::ClaudeHistory', args => {root => $FIXTURES}}},
  };
  my $app = MCP::Hub->new(hub_config_input => $config);
  my $t   = Test::Mojo->new($app);
  $t->post_ok('/_hub/refresh' => json => {})->status_is(200)->json_is('/history', 4);
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
