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
use Scalar::Util qw(weaken);

# Seconds each list takes before it is answered (the tool slow_lists): the
# server blocks for them, as one does that lists slowly.
has list_delay => 0;

sub _handle_tools_list     ($self, @args) { $self->_list_pause; return $self->SUPER::_handle_tools_list(@args) }
sub _handle_prompts_list   ($self, @args) { $self->_list_pause; return $self->SUPER::_handle_prompts_list(@args) }
sub _handle_resources_list ($self, @args) { $self->_list_pause; return $self->SUPER::_handle_resources_list(@args) }

sub _list_pause ($self) {
  select undef, undef, undef, $self->list_delay if $self->list_delay > 0;
  return;
}

# The methods it leaves every request for unanswered (--no-answer in echo.pl):
# a server whose prompts/list never comes back, say, while it answers the rest.
has unanswered => sub { {} };

sub handle ($self, $request, $context) {
  return undef if ref $request eq 'HASH' && defined $request->{id} && $self->unanswered->{$request->{method} // ''};
  return $self->SUPER::handle($request, $context);
}

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

  # Adds a new tool -- with `what` "prompts" or "resources" a new prompt or
  # resource -- and announces it with notifications/<what>/list_changed, to
  # test the list_changed refresh path. With `quiet` it announces nothing: only
  # a refresh the hub is asked for finds it. It reaches the server weakly: a
  # closure over $self would be a cycle through the server, and a reload that
  # drops a `class` entry would never free it.
  weaken(my $server = $self);
  $self->tool(
    name         => 'notify',
    description  => 'Add a tool (prompt, resource) and send notifications/tools/list_changed (prompts, resources)',
    input_schema => {
      type       => 'object',
      properties => {what => {type => 'string', enum => [qw(tools prompts resources)]}, quiet => {type => 'boolean'}},
    },
    code => sub ($tool, $args) {
      my $what = $args->{what} // 'tools';
      if ($what eq 'prompts') {
        $server->prompt(
          name        => 'greet2',
          description => 'A prompt that appeared after a refresh',
          code        => sub ($p, $a) { return $p->text_prompt('Hello again!') },
        ) unless grep { $_->name eq 'greet2' } @{$server->prompts};
      }
      elsif ($what eq 'resources') {
        $server->resource(
          uri         => 'echo://more',
          name        => 'more',
          description => 'A resource that appeared after a refresh',
          mime_type   => 'text/plain',
          code        => sub ($r) { return $r->text_resource('more') },
        ) unless grep { $_->uri eq 'echo://more' } @{$server->resources};
      }
      elsif (!grep { $_->name eq 'echo2' } @{$server->tools}) {
        $server->tool(
          name         => 'echo2',
          description  => 'A tool that appeared after a refresh',
          input_schema => {type => 'object'},
          code         => sub ($t, $a) { return $t->text_result('echo2') },
        );
      }
      print STDOUT encode_json({jsonrpc => '2.0', method => "notifications/$what/list_changed"}) . "\n"
        unless $args->{quiet};
      return $tool->text_result('notified');
    },
  );

  # Has every tools/list, prompts/list and resources/list from now on take
  # `seconds` before it is answered (list_delay): a server slow to list, for a
  # refresh that outlasts idle_timeout.
  $self->tool(
    name         => 'slow_lists',
    description  => 'Take the given number of seconds over every list from now on',
    input_schema => {type => 'object', properties => {seconds => {type => 'number'}}},
    code         => sub ($tool, $args) {
      $server->list_delay($args->{seconds} // 0);
      return $tool->text_result('slowed');
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
