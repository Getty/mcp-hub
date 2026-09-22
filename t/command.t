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
  is MCP::Hub::_base_url('https://0.0.0.0:3080?reuse=1'), 'https://127.0.0.1:3080?reuse=1',
    'listen options are kept';
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

  for my $command (qw(status refresh)) {
    my $out = '';
    open my $fh, '>', \$out or die;
    my $old = select $fh;
    $app->start($command, '--url', $url);
    select $old;
    like $out, qr/\Qnot running at $url\E/, "$command --url overrides the configured listen address";
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
    my $out = '';
    open my $fh, '>', \$out or die;
    my $old = select $fh;
    $app->start($command, '--url', $url, '--token', 'sekret');
    select $old;
    like $out, qr/\Qnot running at $url\E/,
      "$command --url + --token talks to the daemon without reading the broken config";
  }
};

subtest 'the token override also comes from $MCP_HUB_TOKEN' => sub {
  local %ENV = %ENV;
  $ENV{MCP_HUB_TOKEN} = 'from-the-env';
  my $dir  = tempdir;
  my $app  = MCP::Hub->new(cli => 1, hub_config_input => broken_config($dir));

  my $url = 'http://127.0.0.1:' . Mojo::IOLoop::Server->generate_port;
  my $out = '';
  open my $fh, '>', \$out or die;
  my $old = select $fh;
  $app->start('status', '--url', $url);       # no --token: the env supplies it
  select $old;
  like $out, qr/\Qnot running at $url\E/, '$MCP_HUB_TOKEN plus --url bypasses the config too';
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

done_testing;
