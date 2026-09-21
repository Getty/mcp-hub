use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File        qw(curfile tempdir);
use Mojo::IOLoop;
use Mojo::IOLoop::Server;
use Mojo::JSON        qw(encode_json);
use Mojo::Promise;
use Mojo::Server::Daemon;
use Mojo::UserAgent;
use POSIX             ();
use Scalar::Util      qw(refaddr);
use MCP::Hub;
use MCP::Client;

my $ECHO     = curfile->sibling('upstream', 'echo.pl')->to_string;
my $FIXTURES = curfile->sibling('fixtures', 'claude')->to_string;

# Two spellings of the same command: same program, different manifest hash, so
# one of them is a genuinely "changed" entry the cache cannot answer for.
sub echo_entry      { return {command => $^X, args => ['-Ilib', $ECHO]} }
sub echo_entry_alt  { return {command => $^X, args => ['-I', 'lib', $ECHO]} }
sub history_entry   { return {class => 'MCP::Hub::Native::ClaudeHistory', args => {root => $FIXTURES}} }

sub write_config ($file, $data) {
  $file->spurt(encode_json($data));
  return $file;
}

# Warm the manifest cache for every stdio entry in $data, so the hub under test
# starts lazy: tools are known, nothing is spawned.
sub warm_cache ($data, $cache) {
  my $app = MCP::Hub->new(hub_config_input => {%$data, hub => {%{$data->{hub} // {}}, cache_dir => "$cache"}});
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

# The manifest cache is keyed by server name as well as by command hash, so a
# server that a later reload adds has to be warmed under that name: $warm is the
# set to warm, $data the set to start with.
sub hub_for ($file, $cache, $data, $warm = undef) {
  warm_cache($warm // $data, $cache);
  write_config($file, {%$data, hub => {%{$data->{hub} // {}}, cache_dir => "$cache"}});
  return MCP::Hub->new(hub_config_input => "$file");
}

sub client ($t, $path) {
  my $base = $t->ua->server->url->to_string;
  $base =~ s{/$}{};
  return MCP::Client->new(ua => $t->ua, url => "$base$path");
}

sub rpc { return {jsonrpc => '2.0', id => 1, method => 'tools/list', params => {}} }

sub settle { Mojo::Promise->timer($_[0] // 0.4)->wait; return }

# ---------------------------------------------------------------------------

subtest 'a reload touches only what changed' => sub {
  my $dir   = tempdir;
  my $cache = $dir->child('cache');
  my $file  = $dir->child('config.json');
  my $data  = {mcpServers => {echo => echo_entry(), gone => echo_entry(), history => history_entry()}};

  my $app = hub_for($file, $cache, $data);
  my $t   = Test::Mojo->new($app);

  my ($echo, $gone) = map { $app->upstreams_by_name->{$_} } qw(echo gone);
  is $echo->stats->{pid}, undef, 'nothing spawned at start';

  # Give both stdio upstreams a running child and some history.
  is client($t, '/echo')->call_tool('echo', {msg => 'one'})->{content}[0]{text}, 'one', 'echo answers';
  is client($t, '/gone')->call_tool('echo', {msg => 'two'})->{content}[0]{text}, 'two', 'gone answers';
  my $echo_pid  = $echo->stats->{pid};
  my $gone_pid  = $gone->stats->{pid};
  my $echo_addr = refaddr $echo;
  ok $echo_pid && $gone_pid, 'both children are running';
  is $echo->stats->{calls}, 1, 'one call counted on echo';

  # Drop one server, add another, and leave echo and history completely alone.
  write_config($file, {
    mcpServers => {echo => echo_entry(), history => history_entry(), hub => {class => 'MCP::Hub::Native::Status'}},
    hub        => {cache_dir => "$cache"},
  });
  my $summary = $app->reload;

  ok $summary->{ok}, 'the reload was applied';
  is_deeply [sort @{$summary->{added}}],     ['hub'],              'hub added';
  is_deeply [sort @{$summary->{removed}}],   ['gone'],             'gone removed';
  is_deeply [sort @{$summary->{changed}}],   [],                   'nothing changed';
  is_deeply [sort @{$summary->{unchanged}}], [qw(echo history)],   'echo and history untouched';
  is_deeply $summary->{warnings}, [], 'no warnings';

  # The point of the whole feature: the untouched upstream is the same object,
  # with the same process and the same statistics behind it.
  is refaddr $app->upstreams_by_name->{echo}, $echo_addr, 'unchanged upstream is the same object';
  is $echo->stats->{pid}, $echo_pid, 'and the same child process';
  is $echo->stats->{calls}, 1, 'and its call statistics survived';
  is client($t, '/echo')->call_tool('echo', {msg => 'still here'})->{content}[0]{text}, 'still here',
    'it still answers without being restarted';
  is $echo->stats->{pid}, $echo_pid, 'no respawn for that call either';

  # The removed one is stopped, unmounted, and out of /all and the status.
  settle;
  is $gone->stats->{pid}, undef, "the removed server's child was stopped";
  ok !kill(0, $gone_pid), 'and the process is really gone';
  $t->post_ok('/gone' => json => rpc())->status_is(404)->json_is('/error', 'Not found');
  ok !grep({ $_->{name} eq 'gone' } @{$app->status_report->{upstreams}}), 'gone left the status report';

  my %all = map { $_->{name} => 1 } @{client($t, '/all')->list_tools->{tools}};
  ok !$all{'gone__echo'},      'gone left /all';
  ok $all{'echo__echo'},       'echo is still in /all';
  ok $all{'hub__hub_status'},  'the added server is in /all';

  # The added one is mounted and lazy: its manifest came from the cache, so
  # nothing was spawned for it.
  $t->post_ok('/hub' => json => rpc())->status_is(200);

  $_->stop for @{$app->upstreams};
  settle;
};

subtest 'an added stdio server is mounted but not started' => sub {
  my $dir   = tempdir;
  my $cache = $dir->child('cache');
  my $file  = $dir->child('config.json');

  my $app = hub_for($file, $cache,
    {mcpServers => {history => history_entry(), echo => echo_entry()}},
    {mcpServers => {history => history_entry(), echo => echo_entry(), later => echo_entry()}});
  my $t = Test::Mojo->new($app);

  # later already has a cached manifest -- it was configured once before -- so
  # there is nothing for it to fetch and nothing to spawn.
  write_config($file, {
    mcpServers => {history => history_entry(), echo => echo_entry(), later => echo_entry()},
    hub        => {cache_dir => "$cache"},
  });
  is_deeply $app->reload->{added}, ['later'], 'later was added';

  my $later = $app->upstreams_by_name->{later};
  ok $later->manifest_fetched_at, 'it picked up the cached manifest';
  is $later->stats->{pid}, undef, 'and spawned nothing -- lazy start survives a reload';

  my $tools = client($t, '/later')->list_tools;
  ok scalar(grep { $_->{name} eq 'echo' } @{$tools->{tools}}), 'tools/list is answered from the cache';
  is $later->stats->{pid}, undef, 'still no process after tools/list';

  is client($t, '/later')->call_tool('echo', {msg => 'lazy'})->{content}[0]{text}, 'lazy', 'the call works';
  ok $later->stats->{pid}, 'and only the call spawned the child';

  $_->stop for @{$app->upstreams};
  settle;
};

subtest 'a changed entry is rebuilt and only that one' => sub {
  my $dir   = tempdir;
  my $cache = $dir->child('cache');
  my $file  = $dir->child('config.json');

  my $app = hub_for($file, $cache, {mcpServers => {echo => echo_entry(), keep => history_entry()}});
  my $t   = Test::Mojo->new($app);

  is client($t, '/echo')->call_tool('echo', {msg => 'before'})->{content}[0]{text}, 'before', 'echo answers';
  my $old      = $app->upstreams_by_name->{echo};
  my $old_pid  = $old->stats->{pid};
  my $keep_addr = refaddr $app->upstreams_by_name->{keep};
  ok $old_pid, 'the child is running';

  write_config($file, {
    mcpServers => {echo => echo_entry_alt(), keep => history_entry()},
    hub        => {cache_dir => "$cache"},
  });
  my $summary = $app->reload;

  is_deeply $summary->{changed},   ['echo'], 'echo counted as changed';
  is_deeply $summary->{unchanged}, ['keep'], 'the other entry is untouched';
  is refaddr $app->upstreams_by_name->{keep}, $keep_addr, 'and is literally the same object';

  my $new = $app->upstreams_by_name->{echo};
  isnt refaddr $new, refaddr $old, 'the changed one is a new object';
  is_deeply $new->config->{args}, ['-I', 'lib', $ECHO], 'built from the new entry';

  settle;
  is $old->stats->{pid}, undef, 'the old child was stopped';
  ok !kill(0, $old_pid), 'and is gone';

  # It had no cached manifest under the new hash, so the reload warmed it in
  # the background exactly as a daemon start would -- and stopped it again.
  my $deadline = time + 15;
  until (time > $deadline) {
    Mojo::Promise->timer(0.1)->wait;
    last if $new->manifest_fetched_at;
  }
  ok $new->manifest_fetched_at, 'the new entry fetched its manifest in the background';
  is client($t, '/echo')->call_tool('echo', {msg => 'after'})->{content}[0]{text}, 'after',
    'and the endpoint works';

  $_->stop for @{$app->upstreams};
  settle;
};

subtest 'a timeout-only change is applied without restarting anything' => sub {
  my $dir   = tempdir;
  my $cache = $dir->child('cache');
  my $file  = $dir->child('config.json');

  my $app = hub_for($file, $cache, {mcpServers => {echo => echo_entry()}, hub => {idle_timeout => 300}});
  my $t   = Test::Mojo->new($app);

  is client($t, '/echo')->call_tool('echo', {msg => 'x'})->{content}[0]{text}, 'x', 'echo answers';
  my $echo = $app->upstreams_by_name->{echo};
  my ($addr, $pid) = (refaddr $echo, $echo->stats->{pid});
  is $echo->idle_timeout, 300, 'the global idle_timeout applies';

  write_config($file, {mcpServers => {echo => echo_entry()}, hub => {cache_dir => "$cache", idle_timeout => 120}});
  my $summary = $app->reload;

  is_deeply $summary->{changed}, ['echo'], 'the entry counts as changed';
  is refaddr $app->upstreams_by_name->{echo}, $addr, 'but the upstream is the same object';
  is $echo->stats->{pid}, $pid, 'with the same child';
  is $echo->idle_timeout, 120, 'and the new idle_timeout applied in place';

  $_->stop for @{$app->upstreams};
  settle;
};

subtest 'an invalid configuration changes nothing' => sub {
  my $dir   = tempdir;
  my $cache = $dir->child('cache');
  my $file  = $dir->child('config.json');
  my $data  = {
    mcpServers => {history => history_entry(), hub => {class => 'MCP::Hub::Native::Status'}},
    hub        => {
      profiles => {limited => {servers => ['history']}},
      clients  => {worker  => {token => 'tok-worker', profile => 'limited'}},
    },
  };

  my $app = hub_for($file, $cache, $data);
  my $t   = Test::Mojo->new($app);
  my $config = $app->hub_config;
  my %addr   = map { $_ => refaddr $app->upstreams_by_name->{$_} } qw(history hub);

  for my $case (
    ['{"mcpServers": {'                                      => qr/invalid JSON/],
    ['{"mcpServers": {"x": {"command": "a", "bogus": 1}}}'   => qr/unknown key 'bogus'/],
    ['{"hub": {"idle_timeout": "soon"}}'                     => qr/hub\.idle_timeout.*integer/],
  ) {
    my ($text, $expect) = @$case;
    $file->spurt($text);
    my $summary = $app->reload;
    ok !$summary->{ok}, 'the reload was refused';
    like $summary->{error}, $expect, 'with the reason';
    unlike $summary->{error}, qr/line \d+\.$/, 'and without a Perl source location tacked on';

    is refaddr $app->hub_config, refaddr $config, 'the running configuration is untouched';
    is refaddr $app->upstreams_by_name->{$_}, $addr{$_}, "$_ is untouched" for qw(history hub);
  }

  # ...and the profile rules from that configuration are still enforced.
  $t->post_ok('/hub' => {Authorization => 'Bearer tok-worker'} => json => rpc())->status_is(404);
  $t->post_ok('/history' => {Authorization => 'Bearer tok-worker'} => json => rpc())->status_is(200);
  $t->post_ok('/history' => json => rpc())->status_is(401);
};

subtest 'an invalid YAML configuration is refused the same way' => sub {
  my $dir  = tempdir;
  my $file = $dir->child('config.yml');
  $file->spurt("mcpServers:\n  history:\n    class: MCP::Hub::Native::ClaudeHistory\n");

  my $app = MCP::Hub->new(hub_config_input => "$file");
  is $app->hub_config_path, "$file", 'the YAML path is remembered';
  my $config = $app->hub_config;

  $file->spurt("mcpServers:\n  history:\n   - broken\n  \tindent\n");
  my $summary = $app->reload;
  ok !$summary->{ok}, 'refused';
  like $summary->{error}, qr/invalid YAML/, 'as a YAML error';
  is refaddr $app->hub_config, refaddr $config, 'the running configuration survived';

  # A file that validates again is applied.
  $file->spurt("mcpServers:\n  history:\n    class: MCP::Hub::Native::ClaudeHistory\n"
      . "  hub:\n    class: MCP::Hub::Native::Status\n");
  is_deeply $app->reload->{added}, ['hub'], 'the next good write is applied';
};

subtest 'access rules swap in place, with no upstream restarted' => sub {
  my $dir   = tempdir;
  my $cache = $dir->child('cache');
  my $file  = $dir->child('config.json');
  my %auth  = (
    profiles => {
      full   => {servers => ['*'], admin => \1},
      worker => {servers => ['echo', 'history']},
    },
    clients => {
      main => {token => 'tok-main',   profile => 'full'},
      hand => {token => 'tok-worker', profile => 'worker'},
    },
  );

  my $app = hub_for($file, $cache, {
    mcpServers => {echo => echo_entry(), history => history_entry()},
    hub        => {%auth},
  });
  my $t = Test::Mojo->new($app);

  my $ec = MCP::Client->new(ua => $t->ua, headers => {Authorization => 'Bearer tok-worker'},
    url => $t->ua->server->url->to_string =~ s{/$}{}r . '/echo');

  is $ec->call_tool('echo', {msg => 'gated'})->{content}[0]{text}, 'gated', 'the worker may call echo';
  my $echo = $app->upstreams_by_name->{echo};
  my ($addr, $pid) = (refaddr $echo, $echo->stats->{pid});
  ok $pid, 'the child is running';

  my %seen_before = %{$app->auth->last_seen};
  ok $seen_before{hand}, 'the client was stamped as seen';

  # Deny one tool and take history out of the profile.
  write_config($file, {
    mcpServers => {echo => echo_entry(), history => history_entry()},
    hub        => {
      %auth,
      cache_dir => "$cache",
      profiles  => {
        full   => {servers => ['*'], admin => \1},
        worker => {servers => ['echo'], tools => {echo => {deny => ['echo']}}},
      },
    },
  });
  my $summary = $app->reload;

  ok $summary->{ok}, 'applied';
  is $summary->{auth}, 1, 'reported as an access-rules change';
  is_deeply $summary->{unchanged}, [qw(echo history)], 'no upstream was rebuilt';
  is refaddr $app->upstreams_by_name->{echo}, $addr, 'echo is the same object';
  is $echo->stats->{pid}, $pid, 'with the same child';

  # last_seen lives on the Auth, not on the configuration's client hash, so it
  # comes through the swap. Checked here, before any further request restamps it.
  is $app->auth->last_seen->{hand}, $seen_before{hand}, 'last_seen survived the swap';

  # The denied tool is gone from the list...
  my %names = map { $_->{name} => 1 } @{$ec->list_tools->{tools}};
  ok !$names{echo},  'the denied tool left tools/list';
  ok $names{sleep},  'the rest of the tools are still there';

  # ...and calling it is "not found", not merely invisible.
  my $tx = $t->ua->post($t->ua->server->url->clone->path('/echo'),
    {Authorization => 'Bearer tok-worker'},
    json => {jsonrpc => '2.0', id => 7, method => 'tools/call', params => {name => 'echo', arguments => {msg => 'x'}}});
  is $tx->res->json('/error/code'), -32602, 'tools/call on a denied tool is an error';
  like $tx->res->json('/error/message'), qr/not found/i, 'reported as not found';

  is $echo->stats->{pid}, $pid, 'and none of that restarted the child';

  # The server dropped from the profile is a 404 again.
  $t->post_ok('/history' => {Authorization => 'Bearer tok-worker'} => json => rpc())->status_is(404);
  $t->post_ok('/history' => {Authorization => 'Bearer tok-main'} => json => rpc())->status_is(200);

  # ...and it is exactly the 404 a name that was never configured gets, down to
  # the body: a client must not be able to work out which servers exist.
  my @answers = map {
    my $tx = $t->ua->post($t->ua->server->url->clone->path($_),
      {Authorization => 'Bearer tok-worker'}, json => rpc());
    [$tx->res->code, $tx->res->headers->content_type // '', $tx->res->body];
  } qw(/history /never-configured);
  is_deeply $answers[1], $answers[0], 'an unknown name is indistinguishable from a hidden one';

  $_->stop for @{$app->upstreams};
  settle;
};

subtest 'a reload can flip open mode to clients mode' => sub {
  my $dir  = tempdir;
  my $file = $dir->child('config.json');
  write_config($file, {mcpServers => {history => history_entry()}});

  my $app = MCP::Hub->new(hub_config_input => "$file");
  my $t   = Test::Mojo->new($app);

  is $app->hub_config->mode, 'open', 'starts in open mode';
  $t->post_ok('/history' => json => rpc())->status_is(200);

  write_config($file, {
    mcpServers => {history => history_entry()},
    hub        => {
      profiles => {full => {servers => ['*'], admin => \1}},
      clients  => {main => {token => 'tok-main', profile => 'full'}},
    },
  });
  ok $app->reload->{ok}, 'reload applied';

  is $app->hub_config->mode, 'clients', 'now in clients mode';
  $t->post_ok('/history' => json => rpc())->status_is(401)->header_is('WWW-Authenticate' => 'Bearer');
  $t->post_ok('/history' => {Authorization => 'Bearer tok-main'} => json => rpc())->status_is(200);
};

subtest 'listen and cache_dir changes are reported, everything else applied' => sub {
  my $dir  = tempdir;
  my $file = $dir->child('config.json');
  write_config($file, {mcpServers => {history => history_entry()}, hub => {listen => 'http://127.0.0.1:3080'}});

  my $app = MCP::Hub->new(hub_config_input => "$file");
  my $cache_before = $app->active_cache_dir;

  write_config($file, {
    mcpServers => {history => history_entry(), hub => {class => 'MCP::Hub::Native::Status'}},
    hub        => {listen => 'http://0.0.0.0:9999', cache_dir => $dir->child('elsewhere')->to_string},
  });
  my $summary = $app->reload;

  ok $summary->{ok}, 'applied';
  is_deeply $summary->{added}, ['hub'], 'the rest of the change went through';
  is scalar @{$summary->{warnings}}, 2, 'two warnings';
  like join('|', @{$summary->{warnings}}), qr/hub\.listen changed.*restart the daemon/, 'listen needs a restart';
  like join('|', @{$summary->{warnings}}), qr/hub\.cache_dir changed.*restart the daemon/, 'cache_dir too';
  is $app->active_cache_dir, $cache_before, 'the running cache directory did not move';
};

subtest 'a broken placeholder is retried on every reload' => sub {
  my $dir  = tempdir;
  my $lib  = $dir->child('lib');
  my $file = $dir->child('config.json');
  $lib->child('TestReload')->make_path->child('Native.pm')->spurt(<<'PERL');
package TestReload::Native;
use Mojo::Base 'MCP::Server', -signatures;
sub new ($class, %args) {
  my $self = $class->SUPER::new(name => 'late', version => '1.0', %args);
  $self->tool(name => 'late_ping', description => 'pong', input_schema => {type => 'object'},
    code => sub ($tool, $args) { $tool->text_result('pong') });
  return $self;
}
1;
PERL

  write_config($file, {
    mcpServers => {late => {class => 'TestReload::Native'}, history => history_entry()},
  });
  my $app = MCP::Hub->new(hub_config_input => "$file");
  my $t   = Test::Mojo->new($app);

  my $late = $app->upstreams_by_name->{late};
  is $late->state, 'failed', 'the class cannot be loaded, so the entry is a failed placeholder';
  ok $late->placeholder, 'marked as a placeholder';
  $t->post_ok('/late' => json => rpc())->status_is(503)->json_like('/error', qr/TestReload::Native/);

  # The configuration file is not touched at all: only the module became
  # available. A reload must still try again.
  unshift @INC, "$lib";
  my $summary = $app->reload;

  is_deeply $summary->{changed},   ['late'],    'the placeholder was retried';
  is_deeply $summary->{unchanged}, ['history'], 'and nothing else was';
  my $now = $app->upstreams_by_name->{late};
  is $now->state, 'ready', 'it is up this time';
  ok !$now->placeholder, 'and no longer a placeholder';
  $t->post_ok('/late' => json => rpc())->status_is(200)->json_like('/result/tools/0/name', qr/late_ping/);

  shift @INC;
};

subtest 'the reload endpoint is admin-only' => sub {
  my $dir  = tempdir;
  my $file = $dir->child('config.json');
  write_config($file, {
    mcpServers => {history => history_entry()},
    hub        => {
      profiles => {full => {servers => ['*'], admin => \1}, limited => {servers => ['history']}},
      clients  => {main => {token => 'tok-main', profile => 'full'}, worker => {token => 'tok-worker', profile => 'limited'}},
    },
  });
  my $t = Test::Mojo->new(MCP::Hub->new(hub_config_input => "$file"));

  $t->post_ok('/_hub/reload' => {Authorization => 'Bearer tok-worker'} => json => {})->status_is(403);
  $t->post_ok('/_hub/reload' => json => {})->status_is(401);
  $t->post_ok('/_hub/reload' => {Authorization => 'Bearer tok-main'} => json => {})->status_is(200)
    ->json_is('/ok', 1)->json_is('/unchanged', ['history']);

  $file->spurt('{"mcpServers": {');
  $t->post_ok('/_hub/reload' => {Authorization => 'Bearer tok-main'} => json => {})->status_is(500)
    ->json_like('/error', qr/invalid JSON/);
};

sub run_command ($app, @args) {
  my $out = '';
  open my $fh, '>', \$out or die $!;
  my $old = select $fh;
  my $ok  = eval { $app->start(@args); 1 };
  my $err = $@;
  select $old;
  return ($ok, $out, $err);
}

subtest 'the reload command prints the summary, and fails loudly' => sub {
  my $dir  = tempdir;
  my $file = $dir->child('config.json');
  write_config($file, {mcpServers => {history => history_entry()}});

  my $url = 'http://127.0.0.1:' . Mojo::IOLoop::Server->generate_port;
  my $app = MCP::Hub->new(hub_config_input => "$file");

  # The daemon has to run in its own process: a blocking Mojo::UserAgent
  # request -- which is what the command makes -- drives its own event loop,
  # so a daemon on this one would never get a turn.
  my $pid = fork // die "fork: $!";
  unless ($pid) {
    Mojo::IOLoop->reset;
    Mojo::Server::Daemon->new(app => $app, listen => [$url], silent => 1)->run;
    POSIX::_exit(0);
  }

  my $deadline = time + 20;
  my $ready    = 0;
  until ($ready || time > $deadline) {
    my $tx = Mojo::UserAgent->new->request_timeout(1)->get("$url/");
    $ready = $tx->res->code ? 1 : 0;
    Mojo::Promise->timer(0.1)->wait unless $ready;
  }
  ok $ready, 'the daemon is up';

  write_config($file, {mcpServers => {history => history_entry(), hub => {class => 'MCP::Hub::Native::Status'}}});
  my (undef, $out) = run_command($app, 'reload', '--url', $url);
  like $out, qr/added\s+hub/,   'the command prints what was added';
  like $out, qr/unchanged\s+1/, 'and how much was left alone';

  # A configuration that does not validate: the reason, and a non-zero exit.
  $file->spurt('{"hub": {"bogus": 1}}');
  (my $ok, $out, my $err) = run_command($app, 'reload', '--url', $url);
  ok !$ok, 'the command dies, so the shell sees a non-zero exit';
  like $err, qr/unknown key 'bogus'/, 'with the validation error';

  # The refused reload left the daemon's two servers in place: asking again
  # with the same file reports both as unchanged, not as freshly added.
  write_config($file, {mcpServers => {history => history_entry(), hub => {class => 'MCP::Hub::Native::Status'}}});
  (undef, $out) = run_command($app, 'reload', '--url', $url);
  like $out, qr/unchanged\s+2/, 'the running hub kept both servers through the refusal';
  unlike $out, qr/^added/m,     'and added nothing back';

  kill 'TERM', $pid;
  waitpid $pid, 0;
};

subtest 'auto_reload watches the file' => sub {
  my $dir  = tempdir;
  my $file = $dir->child('config.json');
  write_config($file, {mcpServers => {history => history_entry()}, hub => {auto_reload => \1}});

  my $app = MCP::Hub->new(hub_config_input => "$file");
  $app->auto_reload_interval(0.05);
  $app->start_config_watch;
  ok $app->watching_config, 'hub.auto_reload starts the watcher';

  # A change to the file is picked up without anyone asking.
  write_config($file, {
    mcpServers => {history => history_entry(), hub => {class => 'MCP::Hub::Native::Status'}},
    hub        => {auto_reload => \1},
  });
  settle(0.5);
  ok $app->upstreams_by_name->{hub}, 'the added server appeared by itself';

  # A half-written file is refused and leaves everything standing.
  my $config = $app->hub_config;
  $file->spurt('{"mcpServers": {"history": {"cla');
  settle(0.5);
  is refaddr $app->hub_config, refaddr $config, 'the broken write changed nothing';
  ok $app->upstreams_by_name->{hub}, 'and the servers are still there';

  # The write that follows it is applied as usual.
  write_config($file, {mcpServers => {history => history_entry()}, hub => {auto_reload => \1}});
  settle(0.5);
  ok !$app->upstreams_by_name->{hub}, 'the next good write went through';

  # Editors replace a file by renaming a new one over it, which gives the path
  # a different inode. Polling by path sees that; polling a held handle would
  # not, and neither would a single bind-mounted file in a container.
  my $swap = $dir->child('config.new');
  write_config($swap, {
    mcpServers => {history => history_entry(), hub => {class => 'MCP::Hub::Native::Status'}},
    hub        => {auto_reload => \1},
  });
  rename "$swap", "$file" or die "rename: $!";
  settle(0.5);
  ok $app->upstreams_by_name->{hub}, 'a file replaced by rename is picked up too';

  # Switching it off in the file stops the watcher.
  write_config($file, {mcpServers => {history => history_entry()}});
  settle(0.5);
  ok !$app->watching_config,          'auto_reload off stops the watcher';
  ok !$app->upstreams_by_name->{hub}, 'that last change was still applied';

  # ...and then nothing is picked up any more.
  write_config($file, {mcpServers => {history => history_entry(), hub => {class => 'MCP::Hub::Native::Status'}}});
  settle(0.3);
  ok !$app->upstreams_by_name->{hub}, 'a change after that is not noticed';

  $app->stop_config_watch;
};

subtest 'SIGHUP reloads exactly once' => sub {
  my $dir  = tempdir;
  my $file = $dir->child('config.json');
  write_config($file, {mcpServers => {history => history_entry()}});

  my $app = MCP::Hub->new(hub_config_input => "$file");
  $app->watch_sighup;

  my $calls = 0;
  my $real  = \&MCP::Hub::reload;
  no warnings 'redefine';
  local *MCP::Hub::reload = sub { $calls++; return $real->(@_) };
  use warnings;

  write_config($file, {mcpServers => {history => history_entry(), hub => {class => 'MCP::Hub::Native::Status'}}});
  kill HUP => $$;
  settle(0.4);

  is $calls, 1, 'one signal, one reload';
  ok $app->upstreams_by_name->{hub}, 'and the new configuration is live';

  # Triggers that pile up before the loop runs collapse into one.
  $calls = 0;
  $app->schedule_reload('test');
  $app->schedule_reload('test');
  $app->schedule_reload('test');
  settle(0.2);
  is $calls, 1, 'three triggers, still one reload';
};

subtest 'a hub configured from data has nothing to reload' => sub {
  my $app = MCP::Hub->new(hub_config_input => {mcpServers => {history => history_entry()}});
  is $app->hub_config_path, undef, 'no path was resolved';
  my $summary = $app->reload;
  ok !$summary->{ok}, 'the reload is refused';
  like $summary->{error}, qr/not loaded from a file/, 'and says why';
};

subtest 'a configuration file created after the daemon started is picked up' => sub {
  my $dir  = tempdir;
  my $file = $dir->child('config.json');

  my $app = MCP::Hub->new(hub_config_input => "$file");
  is $app->hub_config_path, "$file", 'the missing path is remembered all the same';
  is scalar @{$app->upstreams}, 0, 'the hub started with no servers';

  write_config($file, {mcpServers => {history => history_entry()}});
  is_deeply $app->reload->{added}, ['history'], 'and picks the file up once it exists';
};

done_testing;
