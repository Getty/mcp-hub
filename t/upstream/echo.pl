#!/usr/bin/env perl
# A tiny stdio MCP server used by the hub's test suite. It speaks the legacy
# handshake (via MCP::Server::Legacy, server side) and offers just enough
# behaviour to exercise every path in MCP::Hub::Upstream::Stdio -- without any
# node, python or network. This is the ONLY upstream the test suite spawns;
# the fake docker CLI (fake-docker.pl) runs it as its "containers", over stdio
# or, with --http, over HTTP on the loopback.
use Mojo::Base -strict, -signatures;

use MCP::Server;
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Promise;

# --bad-error=string|array switches the peer into a mode that answers a
# tools/call with a broken error shape -- "error": "text" or "error": [..]
# instead of the error object the protocol asks for. Upstreams in the wild do
# that, and the hub must report it instead of leaving the request pending.
my $BAD_ERROR = (grep { m{^--bad-error=(?:string|array)$} } @ARGV)[0];
$BAD_ERROR =~ s/^--bad-error=// if defined $BAD_ERROR;
if (defined $BAD_ERROR) { _bad_error_peer($BAD_ERROR); exit 0 }

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

# --http=PORT serves the same server over Streamable HTTP at
# http://127.0.0.1:PORT/mcp instead of stdio: what t/upstream/fake-docker.pl
# runs for an HTTP container. --http-delay=SECONDS waits that long before it
# listens, like a server that is slow to come up behind a published port.
my ($HTTP) = map { /^--http=(\d+)$/ ? $1 : () } @ARGV;
if (defined $HTTP) { _serve_http($server, $HTTP); exit 0 }

$server->to_stdio;

sub _serve_http ($server, $port) {
  require Mojolicious;
  require Mojo::Server::Daemon;
  my ($delay) = map { /^--http-delay=([\d.]+)$/ ? $1 : () } @ARGV;
  select undef, undef, undef, $delay if $delay;

  my $app = Mojolicious->new;
  $app->log->level('fatal');
  $app->routes->post('/mcp' => $server->to_action({streaming => 1}));
  Mojo::Server::Daemon->new(app => $app, listen => ["http://127.0.0.1:$port"], silent => 1)->run;
  return;
}

# A hand-rolled peer: it speaks just enough of the legacy handshake to get the
# hub to call a tool, and answers that call with an error that is not an object.
sub _bad_error_peer ($shape) {
  $| = 1;    # the hub reads line by line, so nothing may sit in the buffer

  while (my $line = <STDIN>) {
    my $msg = eval { decode_json($line) };
    next unless ref $msg eq 'HASH';
    my $id = $msg->{id};
    next unless defined $id;    # a notification gets no answer
    my $method = $msg->{method} // '';
    if ($method eq 'initialize') {
      _reply({jsonrpc => '2.0', id => $id, result => {
        protocolVersion => '2025-06-18',
        capabilities    => {},
        serverInfo      => {name => 'bad-error-server', version => '0.0.1'},
      }});
    }
    elsif ($method eq 'tools/list') {
      _reply({jsonrpc => '2.0', id => $id, result => {tools => [
        {name => 'boom', description => 'Answers with a broken error', inputSchema => {type => 'object'}},
      ]}});
    }
    else {
      my $error = $shape eq 'string' ? 'nope' : ['nope', 'still nope'];
      _reply({jsonrpc => '2.0', id => $id, error => $error});
    }
  }
  return;
}

sub _reply ($obj) { print STDOUT encode_json($obj) . "\n" }
