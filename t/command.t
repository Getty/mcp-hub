use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::IOLoop::Server;
use MCP::Hub;
use MCP::Hub::Command::daemon;
use MCP::Hub::Command::status;

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

done_testing;
