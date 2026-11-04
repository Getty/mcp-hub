package EchoServer;
use Mojo::Base 'MCP::Server', -signatures;

# The test suite's echo server as a class. t/upstream/echo.pl runs it over
# stdio (and, through fake-docker.pl, as a "container"); a `class` entry --
# forked or in process -- mounts the same class, so one fixture covers every
# transport. It offers just enough behaviour to exercise every path of the
# upstreams, without any node, python or network.

use Mojo::IOLoop;
use Mojo::JSON qw(encode_json);
use Mojo::Promise;

sub new ($class, @args) {
  my $self = $class->SUPER::new(name => 'echo-server', version => '9.9.9', @args);
  $self->instructions('Echo things back.');

  $self->tool(
    name         => 'echo',
    description  => 'Echo the input text back',
    input_schema => {type => 'object', properties => {msg => {type => 'string'}}, required => ['msg']},
    code         => sub ($tool, $args) { return $tool->text_result($args->{msg}) },
  );

  # Async: resolves after N seconds. Used to test the request timeout.
  $self->tool(
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
  $self->tool(
    name         => 'fail',
    description  => 'Return an error result',
    input_schema => {type => 'object'},
    code         => sub ($tool, $args) { return $tool->text_result('deliberate failure', 1) },
  );

  # Dies -- the server turns this into a JSON-RPC internal error.
  $self->tool(
    name         => 'die',
    description  => 'Throw an exception',
    input_schema => {type => 'object'},
    code         => sub ($tool, $args) { die "boom\n" },
  );

  # Terminates the whole process (with `code`, 0 by default), to test crash
  # detection and restart.
  $self->tool(
    name         => 'exit',
    description  => 'Exit the process',
    input_schema => {type => 'object', properties => {code => {type => 'integer'}}},
    code         => sub ($tool, $args) { exit($args->{code} // 0) },
  );

  # Adds a new tool and announces it, to test the list_changed refresh path.
  $self->tool(
    name         => 'notify',
    description  => 'Add a tool and send notifications/tools/list_changed',
    input_schema => {type => 'object'},
    code         => sub ($tool, $args) {
      unless (grep { $_->name eq 'echo2' } @{$self->tools}) {
        $self->tool(
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

  $self->prompt(
    name        => 'greet',
    description => 'A greeting prompt',
    arguments   => [{name => 'who', description => 'Who to greet', required => 1}],
    code        => sub ($prompt, $args) { return $prompt->text_prompt("Hello, $args->{who}!") },
  );

  $self->resource(
    uri         => 'echo://readme',
    name        => 'readme',
    description => 'The echo server readme',
    mime_type   => 'text/plain',
    code        => sub ($resource) { return $resource->text_resource('This is the echo server.') },
  );

  return $self;
}

1;
