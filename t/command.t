#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File         qw(tempdir);
use Mojo::IOLoop::Server;
use MCP::Hub;
use MCP::Hub::Config;
use MCP::Hub::Command::daemon;
use MCP::Hub::Command::status;
use MCP::Hub::Command::refresh;

# A config file the validation rejects, written to a temp dir kept alive by the
# caller (Mojo::File::tempdir cleans up when its object goes out of scope).
sub broken_config ($dir) {
  my $file = $dir->child('config.json');
  $file->spurt('{ "hub": { "bogus_key": true } }');
  return "$file";
}

my $app = MCP::Hub->new(hub_config_input => {
  mcpServers => {run => {class => 'MCP::Hub::Native::Status'}},
  hub        => {listen => 'http://127.0.0.1:4242'},
});

subtest 'our command namespace wins over the built-ins' => sub {
  # Regression: the daemon command must resolve to ours, not the built-in
  # Mojolicious::Command::daemon (which ignores the configured listen address).
  is $app->commands->namespaces->[0], 'MCP::Hub::Command',
    'MCP::Hub::Command is searched before Mojolicious::Command';
  isa_ok 'MCP::Hub::Command::daemon', 'Mojolicious::Command::daemon',
    'our daemon still inherits the real daemon command';
};

subtest 'daemon defaults the listen address from the config' => sub {
  my $cmd = MCP::Hub::Command::daemon->new(app => $app);
  is_deeply [$cmd->default_listen()], ['-l', 'http://127.0.0.1:4242'],
    'no -l given -> config listen is prepended';
  is_deeply [$cmd->default_listen('-l', 'http://127.0.0.1:9')], ['-l', 'http://127.0.0.1:9'],
    'an explicit -l is left untouched';
  is_deeply [$cmd->default_listen('--listen', 'http://x')], ['--listen', 'http://x'],
    'an explicit --listen is left untouched';
};

subtest 'the base URL a wildcard listen address is reachable at' => sub {
  is MCP::Hub::_base_url('http://127.0.0.1:3080'), 'http://127.0.0.1:3080', 'a concrete address is kept';
  is MCP::Hub::_base_url('http://127.0.0.1:3080/'), 'http://127.0.0.1:3080', 'trailing slash removed';
  is MCP::Hub::_base_url('http://*:3080'),          'http://127.0.0.1:3080', '* -> loopback';
  is MCP::Hub::_base_url('http://0.0.0.0:3080'),    'http://127.0.0.1:3080', '0.0.0.0 -> loopback';
  is MCP::Hub::_base_url('http://[::]:3080'),       'http://[::1]:3080',     '[::] -> loopback';
  # The query holds the server's listen options; a client calling
  # '...?reuse=1/hub' reaches no endpoint at all.
  is MCP::Hub::_base_url('https://0.0.0.0:3080?reuse=1'), 'https://127.0.0.1:3080',
    'listen options are dropped';
  is MCP::Hub::_base_url('https://127.0.0.1:3443?cert=/a/server.crt&key=/a/server.key'),
    'https://127.0.0.1:3443', 'cert and key are dropped';
  is MCP::Hub::_base_url('https://127.0.0.1:3443/?cert=/a/b.crt'), 'https://127.0.0.1:3443',
    'a query after a trailing slash is dropped, and the slash too';
  is MCP::Hub::_base_url('https://*:3443?cert=/a/b.crt'), 'https://127.0.0.1:3443',
    'a wildcard with a query -> loopback, without the query';
  is MCP::Hub::_base_url('http://127.0.0.1:3080#x'), 'http://127.0.0.1:3080', 'a fragment is dropped';
};

subtest 'an https listen with cert and key: config and status/refresh/reload call the bare base' => sub {
  my $app = MCP::Hub->new(cli => 1, hub_config_input => {
    mcpServers => {run => {class => 'MCP::Hub::Native::Status'}},
    hub        => {listen => 'https://127.0.0.1:3443?cert=/a/server.crt&key=/a/server.key'},
  });

  is $app->export_config->{mcpServers}{run}{url}, 'https://127.0.0.1:3443/run',
    'mcp-hub config prints the endpoint without the listen options';
  is $app->export_config(all => 1)->{mcpServers}{hub}{url}, 'https://127.0.0.1:3443/all',
    'and so does mcp-hub config --all';

  # status, refresh and reload all take their base from this one helper.
  my ($base) = MCP::Hub::Command::status::_endpoint($app, undef, undef, undef);
  is $base, 'https://127.0.0.1:3443', 'status/refresh/reload talk to the bare base';
};

subtest 'the status table names a failure and when a client was last seen' => sub {
  my $report = {
    mode      => 'clients',
    upstreams => [
      {name => 'echo',   type => 'stdio', state => 'ready',  pid => 42, rss_kb => 1234, calls => 2, errors => 0},
      {name => 'broken', type => 'perl',  state => 'failed', calls => 0, errors => 0,
        error => 'cannot load class No::Such::Class'},
    ],
    clients => [
      {name => 'main',   profile => 'full',    last_seen => time - 120},
      {name => 'worker', profile => 'limited', last_seen => undef},
    ],
  };

  my $out = '';
  open my $fh, '>', \$out or die;
  my $old = select $fh;
  MCP::Hub::Command::status::_print_table($report);
  select $old;

  like $out, qr/broken\s+perl\s+failed.*cannot load class No::Such::Class/,
    'a failed upstream prints its reason';
  like $out, qr/main\s+full\s+2m ago/,      'last_seen is printed as an age';
  like $out, qr/worker\s+limited\s+never/,  'a client that never authenticated says never';
};

subtest 'status and refresh talk to --url' => sub {
  my $url = 'http://127.0.0.1:' . Mojo::IOLoop::Server->generate_port;

  # status dies with it, and so exits 1 (t/cli.t); refresh prints it.
  for my $command (qw(status refresh)) {
    my ($out, $err) = run_command($app, $command, '--url', $url);
    like $command eq 'status' ? $err : $out, qr/\Qnot running at $url\E/,
      "$command --url overrides the configured listen address";
  }
};

subtest 'a broken config file is remembered (cli), not thrown, so --url + token still reaches the daemon' => sub {
  my $dir  = tempdir;
  my $file = broken_config($dir);

  # cli => 1 mirrors bin/mcp-hub: the app builds, the error is deferred.
  my $app = MCP::Hub->new(cli => 1, hub_config_input => $file);
  like   $app->config_error, qr/unknown key 'bogus_key'/, 'the broken file is remembered, not thrown';
  unlike $app->config_error, qr/ at \S+ line \d+/,         'and with no Perl source location on it';

  my $url = 'http://127.0.0.1:' . Mojo::IOLoop::Server->generate_port;
  for my $command (qw(status refresh reload)) {
    my ($out, $err) = run_command($app, $command, '--url', $url, '--token', 'sekret');
    like $command eq 'status' ? $err : $out, qr/\Qnot running at $url\E/,
      "$command --url + --token talks to the daemon without reading the broken config";
  }
};

subtest 'the token override also comes from $MCP_HUB_TOKEN' => sub {
  local %ENV = %ENV;
  $ENV{MCP_HUB_TOKEN} = 'from-the-env';
  my $dir  = tempdir;
  my $app  = MCP::Hub->new(cli => 1, hub_config_input => broken_config($dir));

  my $url = 'http://127.0.0.1:' . Mojo::IOLoop::Server->generate_port;
  my (undef, $err) = run_command($app, 'status', '--url', $url);    # no --token: the env supplies it
  like $err, qr/\Qnot running at $url\E/, '$MCP_HUB_TOKEN plus --url bypasses the config too';
};

subtest 'without a token a broken config is still fatal, cleanly, where it is needed' => sub {
  local %ENV = %ENV;
  delete $ENV{MCP_HUB_TOKEN};
  my $dir = tempdir;
  my $app = MCP::Hub->new(cli => 1, hub_config_input => broken_config($dir));

  my $url = 'http://127.0.0.1:' . Mojo::IOLoop::Server->generate_port;
  # --url but no token: the admin token would have to come from the config, so
  # the deferred error becomes fatal now.
  eval { $app->start('status', '--url', $url) };
  like   $@, qr/unknown key 'bogus_key'/, 'the config error surfaces';
  unlike $@, qr/ at \S+ line \d+/,        'still without a Carp location tail';
};

subtest 'an embedder gets the same clean error thrown at construction' => sub {
  my $dir = tempdir;
  eval { MCP::Hub->new(hub_config_input => broken_config($dir)) };   # cli => 0
  like   $@, qr/Invalid configuration at hub\.bogus_key: unknown key 'bogus_key'/,
    'the JSON path is kept';
  unlike $@, qr/ at \S+ line \d+/, 'the Perl source location is stripped';
};

subtest 'the shared stripper folds a croaked error onto one clean line' => sub {
  my $carped = "Invalid configuration at hub.x: bad\n at lib/MCP/Hub.pm line 340.\n";
  is MCP::Hub::Config::_strip_location($carped),
    'Invalid configuration at hub.x: bad', 'the newline and the location tail are gone';
};

subtest 'refresh renders a failed upstream as failed, never "0 tools"' => sub {
  # Regression: a broken placeholder refreshes to a count of 0, which read as
  # success. It must show its failure and reason instead.
  my $counts = {
    ok     => {count => 3, state => 'ready'},
    broken => {count => 0, state => 'failed', error => 'cannot load class No::Such::Class'},
  };

  my $out = '';
  open my $fh, '>', \$out or die;
  my $old = select $fh;
  MCP::Hub::Command::refresh::_print_counts($counts);
  select $old;

  like   $out, qr/^ok\s+3 tools$/m, 'a ready upstream shows its tool count';
  like   $out, qr/^broken\s+failed: cannot load class No::Such::Class$/m,
    'a failed upstream shows failed and the reason';
  unlike $out, qr/broken\s+0 tools/, 'and never "0 tools"';
};

# --- the commands that would serve the hub in more than one process ---------

# Run one command line against $app: what it printed, and the error it died
# with (undef when it did not).
sub run_command ($app, @args) {
  my $out = '';
  open my $fh, '>', \$out or die;
  my $old = select $fh;
  my $ok  = eval { $app->start(@args); 1 };
  select $old;
  return ($out, $ok ? undef : $@);
}

# Should a refusal ever stop working, the real command must not start a
# pre-forking server, or read a CGI request from STDIN, inside the test: each
# dies instead, naming itself.
my @REFUSED = qw(prefork cgi psgi);
for my $name (@REFUSED) {
  my $class = "Mojolicious::Command::$name";
  eval "require $class; 1" or die $@;
  no strict 'refs';
  no warnings 'redefine';
  *{"${class}::run"} = sub { die "reached $class\n" };
}

subtest 'prefork, cgi and psgi are refused, saying why and pointing at mcp-hub daemon' => sub {
  delete local @ENV{qw(PLACK_ENV PATH_INFO GATEWAY_INTERFACE MOJO_NO_DETECT)};
  for my $name (@REFUSED) {
    for my $args ([$name], [$name, '-l', 'http://127.0.0.1:9'], ['help', $name], [$name, '--help']) {
      my ($out, $err) = run_command($app, @$args);
      like $err, qr/^mcp-hub refuses "$name": the hub is one process that owns every upstream and all state/,
        "mcp-hub @$args is refused, and says why";
      like $err, qr/Run "mcp-hub daemon" instead\.\n\z/, '...and points at mcp-hub daemon';
      is $out, '', '...and prints nothing';
    }
  }
};

subtest 'a CGI or PSGI environment cannot turn a command into cgi or psgi' => sub {
  # Mojolicious::Commands lets the environment override the command name: with
  # PLACK_ENV set, mcp-hub daemon served nothing, returned a PSGI app and
  # exited 0. A command that returns at once stands in for daemon here.
  my %env = (psgi => {PLACK_ENV => 'production'}, cgi => {GATEWAY_INTERFACE => 'CGI/1.1'});
  for my $as (sort keys %env) {
    my ($var) = keys %{$env{$as}};
    delete local @ENV{qw(PLACK_ENV PATH_INFO GATEWAY_INTERFACE MOJO_NO_DETECT)};
    local $ENV{$var} = $env{$as}{$var};
    my ($out, $err) = run_command($app, 'token');
    like $err, qr/^mcp-hub refuses to run as \U$as\E \($var/, "$var set: refused, naming the variable";
    like $err, qr/one process that owns every upstream/,     '...and saying why';
    like $err, qr/"mcp-hub daemon"/,                         '...and pointing at mcp-hub daemon';
    is $out, '', '...and the command never ran';

    local $ENV{MOJO_NO_DETECT} = 1;
    ($out, $err) = run_command($app, 'token');
    is $err, undef, "$var set with MOJO_NO_DETECT=1: the named command runs";
    like $out, qr/\A[\w-]{43}\n\z/, '...and prints its token';
  }
};

subtest 'the command list leaves them out and keeps the commands worth having' => sub {
  delete local $ENV{HARNESS_ACTIVE};    # Mojolicious prints no list under a test harness
  delete local @ENV{qw(PLACK_ENV PATH_INFO GATEWAY_INTERFACE MOJO_NO_DETECT)};
  for my $args ([], ['help'], ['--help'], ['-h']) {
    my ($out, $err) = run_command($app, @$args);
    is $err, undef, "mcp-hub @$args lists the commands";
    my (undef, $table) = split /^Commands:\n/m, $out, 2;
    my %listed = map { /^ (\w[\w-]*) / ? ($1 => 1) : () } split /\n/, $table // '';
    ok !$listed{$_}, "$_ is not listed" for @REFUSED, qw(cpanify generate inflate);
    ok $listed{$_},  "$_ is listed" for qw(config daemon refresh reload status token eval get routes version);
  }
};

subtest "the text around the list is mcp-hub's own, not Mojolicious's" => sub {
  # Regression: the usage above the list and the hint below it were the
  # inherited Mojolicious ones -- "mojo generate lite-app", CGI and PSGI
  # auto-detection, PLACK_ENV setting the mode, "APPLICATION help COMMAND".
  delete local $ENV{HARNESS_ACTIVE};
  delete local @ENV{qw(PLACK_ENV PATH_INFO GATEWAY_INTERFACE MOJO_NO_DETECT)};
  for my $args ([], ['help'], ['--help'], ['-h']) {
    my ($out) = run_command($app, @$args);
    my ($usage, $rest) = split /^Commands:\n/m, $out, 2;
    my (undef, $hint)  = split /^\n/m, $rest // '', 2;
    my $text = join '', $usage // '', $hint // '';

    like $usage, qr/\AUsage: mcp-hub /,        "mcp-hub @$args: the usage is mcp-hub's";
    like $usage, qr/^  mcp-hub daemon$/m,      '...with mcp-hub examples';
    like $usage, qr/^  -c, --config <path> /m, '...and the global --config';
    like $hint,  qr/See 'mcp-hub help COMMAND'/, "...and the hint names mcp-hub";
    unlike $text, qr/\b$_\b/i, "...never naming $_" for @REFUSED, qw(cpanify generate inflate);
    unlike $text, qr/PLACK_ENV|automatically detected|\bmojo\b|myapp|APPLICATION/,
      '...nor auto-detection, PLACK_ENV or a Mojolicious example';
  }
};

subtest 'a server of its own is refused as it starts the hub, unless it is a plain daemon' => sub {
  # A script that hands the hub to a server never comes past Commands::run:
  # the hub refuses the server itself, as it starts (before_server_start). None
  # of these forks or serves a request: Prefork's start is the daemon's, the
  # fork is in its run.
  require Mojo::Server::CGI;
  require Mojo::Server::PSGI;
  require Mojo::Server::Prefork;
  {
    package Local::Daemon;
    use Mojo::Base 'Mojo::Server::Daemon';
  }
  my $hub    = MCP::Hub->new(hub_config_input => {mcpServers => {run => {class => 'MCP::Hub::Native::Status'}}});
  my $listen = ['http://127.0.0.1:0'];
  my $why    = qr/the hub is one process that owns every upstream and all state; /;

  my $prefork = Mojo::Server::Prefork->new(app => $hub, listen => $listen);
  ok !eval { $prefork->start; 1 }, 'a Mojo::Server::Prefork around the hub does not start';
  like $@, qr/^mcp-hub refuses to run under prefork: $why/, '...refused, saying why';
  like $@, qr/Run "mcp-hub daemon" instead\.\n\z/,          '...and pointing at mcp-hub daemon';
  is_deeply $prefork->acceptors, [], '...and it listens on nothing';

  my $err;
  {
    # Should the refusal ever stop working, the request it reads is empty and
    # the response it writes goes nowhere -- not into the TAP stream.
    open local *STDIN,  '<', '/dev/null' or die $!;
    open local *STDOUT, '>', '/dev/null' or die $!;
    ok !eval { Mojo::Server::CGI->new(app => $hub)->run; 1 }, 'nor does a Mojo::Server::CGI';
    $err = $@;
  }
  like $err, qr/^mcp-hub refuses to run under cgi: $why/, '...refused';
  ok !eval { Mojo::Server::PSGI->new(app => $hub)->to_psgi_app; 1 }, 'nor a Mojo::Server::PSGI';
  like $@, qr/^mcp-hub refuses to run under psgi: $why/, '...refused';

  my $own = Local::Daemon->new(app => $hub, listen => $listen);
  ok !eval { $own->start; 1 }, 'nor a subclass of the daemon';
  like $@, qr/^mcp-hub refuses to run under Local::Daemon: ${why}only a plain Mojo::Server::Daemon serves it/,
    '...refused, naming it';
  is_deeply $own->acceptors, [], '...and it listens on nothing';

  my $daemon = Mojo::Server::Daemon->new(app => $hub, listen => $listen, silent => 1);
  ok eval { $daemon->start; 1 }, 'a plain Mojo::Server::Daemon serves it' or diag $@;
  is scalar @{$daemon->acceptors}, 1, '...listening';
  $daemon->stop;
};

subtest 'the Mojolicious author tools are not hub commands' => sub {
  is_deeply $app->commands->namespaces, ['MCP::Hub::Command', 'Mojolicious::Command'],
    'ours first, then the core commands; no Mojolicious::Command::Author';
  my (undef, $err) = run_command($app, 'generate');
  like $err, qr/^Unknown command "generate"/, 'mcp-hub generate is an unknown command';
};

done_testing;
