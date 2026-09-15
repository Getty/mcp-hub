use Mojo::Base -strict, -signatures;
use Test::More;
use MCP::Hub;
use MCP::Hub::Command::daemon;

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

done_testing;
