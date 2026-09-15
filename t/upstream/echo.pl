#!/usr/bin/env perl
# A tiny stdio MCP server used by the hub's test suite. It speaks the legacy
# handshake (via MCP::Server::Legacy, server side) and offers just enough
# behaviour to exercise every path in MCP::Hub::Upstream::Stdio -- without any
# node, python or network. This is the ONLY upstream the test suite spawns.
use Mojo::Base -strict, -signatures;

use MCP::Server;
use Mojo::IOLoop;
use Mojo::JSON qw(encode_json);
use Mojo::Promise;

my $server = MCP::Server->new(name => 'echo-server', version => '9.9.9');
$server->instructions('Echo things back.');

$server->tool(
  name         => 'echo',
  description  => 'Echo the input text back',
  input_schema => {type => 'object', properties => {msg => {type => 'string'}}, required => ['msg']},
  code         => sub ($tool, $args) { return $tool->text_result($args->{msg}) },
);

# Async: resolves after N seconds. Used to test the request timeout.
$server->tool(
  name         => 'sleep',
  description  => 'Sleep for the given number of seconds, then return',
  input_schema => {type => 'object', properties => {seconds => {type => 'number'}}},
  code         => sub ($tool, $args) {
    my $seconds = $args->{seconds} // 1;
    my $promise = Mojo::Promise->new;
    Mojo::IOLoop->timer($seconds => sub { $promise->resolve($tool->text_result("slept $seconds")) });
    return $promise;
  },
);

# Returns an error result (isError => true) -- a tool-level failure.
$server->tool(
  name         => 'fail',
  description  => 'Return an error result',
  input_schema => {type => 'object'},
  code         => sub ($tool, $args) { return $tool->text_result('deliberate failure', 1) },
);

# Dies -- the server turns this into a JSON-RPC internal error.
$server->tool(
  name         => 'die',
  description  => 'Throw an exception',
  input_schema => {type => 'object'},
  code         => sub ($tool, $args) { die "boom\n" },
);

# Terminates the whole process, to test crash detection and restart.
$server->tool(
  name         => 'exit',
  description  => 'Exit the process',
  input_schema => {type => 'object'},
  code         => sub ($tool, $args) { exit 0 },
);

# Adds a new tool and announces it, to test the list_changed refresh path.
$server->tool(
  name         => 'notify',
  description  => 'Add a tool and send notifications/tools/list_changed',
  input_schema => {type => 'object'},
  code         => sub ($tool, $args) {
    unless (grep { $_->name eq 'echo2' } @{$server->tools}) {
      $server->tool(
        name         => 'echo2',
        description  => 'A tool that appeared after a refresh',
        input_schema => {type => 'object'},
        code         => sub ($t, $a) { return $t->text_result('echo2') },
      );
    }
    print STDOUT encode_json({jsonrpc => '2.0', method => 'notifications/tools/list_changed'}) . "\n";
    return $tool->text_result('notified');
  },
);

$server->prompt(
  name        => 'greet',
  description => 'A greeting prompt',
  arguments   => [{name => 'who', description => 'Who to greet', required => 1}],
  code        => sub ($prompt, $args) { return $prompt->text_prompt("Hello, $args->{who}!") },
);

$server->resource(
  uri         => 'echo://readme',
  name        => 'readme',
  description => 'The echo server readme',
  mime_type   => 'text/plain',
  code        => sub ($resource) { return $resource->text_resource('This is the echo server.') },
);

$server->to_stdio;
