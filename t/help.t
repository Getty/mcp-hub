use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File qw(curfile);
use MCP::Hub;

my $FIXTURES = curfile->sibling('fixtures', 'claude')->to_string;

subtest 'open mode: the help page lists every server' => sub {
  my $app = MCP::Hub->new(hub_config_input => {
    mcpServers => {
      history => {class => 'MCP::Hub::Native::ClaudeHistory', args => {root => $FIXTURES}},
      hub     => {class => 'MCP::Hub::Native::Status'},
    },
  });
  my $t = Test::Mojo->new($app);
  $t->get_ok('/')->status_is(200)
    ->content_type_like(qr{text/html})
    ->text_is('h1', 'MCP Hub')
    ->content_like(qr/mcpServers/, 'shows a ready-to-paste config')
    ->content_like(qr/history/,    'lists the history server')
    ->content_like(qr{/hub\b},     'includes the per-server URL')
    ->content_like(qr/claude mcp add/, 'shows a claude mcp add command');
};

subtest 'clients mode: nothing leaks without a token' => sub {
  my $app = MCP::Hub->new(hub_config_input => {
    mcpServers => {
      history => {class => 'MCP::Hub::Native::ClaudeHistory', args => {root => $FIXTURES}},
      secret  => {class => 'MCP::Hub::Native::Status'},
    },
    hub => {
      profiles => {limited => {servers => ['history']}, full => {servers => ['*'], admin => \1}},
      clients  => {worker => {token => 'tok-worker', profile => 'limited'}, main => {token => 'tok-main', profile => 'full'}},
    },
  });
  my $t = Test::Mojo->new($app);

  # Anonymous: a sign-in form, and no server names at all.
  $t->get_ok('/')->status_is(200)
    ->element_exists('input[name=token]', 'sign-in form present')
    ->content_unlike(qr/\bhistory\b/, 'does not leak the history server')
    ->content_unlike(qr/\bsecret\b/,  'does not leak the secret server');

  # A wrong token is rejected, still no leak.
  $t->post_ok('/' => form => {token => 'nope'})->status_is(200)
    ->content_like(qr/not recognised/, 'wrong token is reported')
    ->content_unlike(qr/\bhistory\b/, 'still no leak');

  # The worker sees history, its token and header, but not the secret server.
  $t->post_ok('/' => form => {token => 'tok-worker'})->status_is(200)
    ->content_like(qr/history/,        'worker sees history')
    ->content_like(qr/tok-worker/,     'config carries the token')
    ->content_like(qr/Authorization/,  'config carries the auth header')
    ->content_unlike(qr/\bsecret\b/,   'worker does not see the secret server');

  # A bearer header works just like the form.
  $t->get_ok('/' => {Authorization => 'Bearer tok-main'})->status_is(200)
    ->content_like(qr/history/, 'admin sees history')
    ->content_like(qr/secret/,  'admin (full) also sees secret');
};

done_testing;
