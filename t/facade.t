use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::Promise;
use MCP::Server::Context;
use MCP::Hub::Facade;

# A mock upstream: every forwarding method returns a resolved promise built by
# a stored callback, so we can assert exactly what the facade forwards.
package MockUpstream {
  use Mojo::Base -base, -signatures;
  use Mojo::Promise;
  has name       => 'mock';
  has calls      => sub { [] };
  has tool_cb    => sub { sub { {content => [{type => 'text', text => 'ok'}], isError => \0} } };
  has prompt_cb  => sub { sub { {messages => [{role => 'user', content => {type => 'text', text => 'p'}}]} } };
  has resource_cb => sub { sub { {contents => [{uri => 'file://x', text => 'r'}]} } };
  sub call_tool ($self, $name, $args) {
    push @{$self->calls}, ['tool', $name, $args];
    return Mojo::Promise->resolve($self->tool_cb->($name, $args));
  }
  sub get_prompt ($self, $name, $args) {
    push @{$self->calls}, ['prompt', $name, $args];
    return Mojo::Promise->resolve($self->prompt_cb->($name, $args));
  }
  sub read_resource ($self, $uri) {
    push @{$self->calls}, ['resource', $uri];
    return Mojo::Promise->resolve($self->resource_cb->($uri));
  }
}

sub _await ($promise) {
  my $out;
  $promise->then(sub { $out = shift })->catch(sub { $out = {error => shift} })->wait;
  return $out;
}

my $manifest = {
  server_info  => {name => 'context7', version => '1.2.3'},
  instructions => 'Use resolve first.',
  tools => [
    {
      name        => 'resolve',
      description => 'Resolve a library id',
      inputSchema => {type => 'object', properties => {q => {type => 'string'}}, required => ['q']},
      annotations => {readOnlyHint => \1},
      title       => 'Resolve Library',
      icons       => [{src => 'file://icon.png'}],
      _meta       => {'anthropic/maxResultSizeChars' => 50000},
    },
  ],
  prompts   => [{name => 'demo', description => 'A demo prompt', title => 'Demo'}],
  resources => [{uri => 'file://readme', name => 'readme', mimeType => 'text/markdown', _meta => {x => 1}}],
};

my $up      = MockUpstream->new;
my $server  = MCP::Hub::Facade->build($up, $manifest);
my $context = MCP::Server::Context->new;

subtest 'server metadata comes from the manifest' => sub {
  is $server->name,         'context7',           'name';
  is $server->version,      '1.2.3',              'version';
  is $server->instructions, 'Use resolve first.', 'instructions';
  isa_ok $server, 'MCP::Hub::Facade::Server';
};

subtest 'tools/list keeps title, icons and _meta' => sub {
  my ($result) = $server->_handle_tools_list($context);
  my ($tool) = @{$result->{tools}};
  is $tool->{name},        'resolve',          'name rendered';
  is $tool->{title},       'Resolve Library',  'title merged back in';
  is_deeply $tool->{icons}, [{src => 'file://icon.png'}], 'icons merged';
  is $tool->{_meta}{'anthropic/maxResultSizeChars'}, 50000, '_meta merged';
  is_deeply $tool->{annotations}, {readOnlyHint => \1}, 'annotations passed through';
};

subtest 'validate_input is disabled' => sub {
  my ($tool) = @{$server->tools};
  isa_ok $tool, 'MCP::Hub::Facade::Tool';
  # 'q' is required by the schema, but the facade must not reject the call.
  is $tool->validate_input({}), 0, 'missing required arg still validates';
};

subtest 'tool call forwards to the upstream and passes the result through' => sub {
  my ($tool) = @{$server->tools};
  my $result = _await($tool->call({q => 'react'}, $context));
  is_deeply $result, {content => [{type => 'text', text => 'ok'}], isError => \0}, 'result unchanged';
  is_deeply $up->calls->[-1], ['tool', 'resolve', {q => 'react'}], 'upstream called with name and args';
};

subtest 'prompt and resource forwarding' => sub {
  my ($prompt) = @{$server->prompts};
  my $pres = _await($prompt->call({}, $context));
  is $pres->{messages}[0]{content}{text}, 'p', 'prompt result passed through';

  my ($resource) = @{$server->resources};
  my $rres = _await($resource->call($context));
  is $rres->{contents}[0]{text}, 'r', 'resource result passed through';

  my ($result) = $server->_handle_prompts_list($context);
  is $result->{prompts}[0]{title}, 'Demo', 'prompt title merged';

  my ($rlist) = $server->_handle_resources_list($context);
  is $rlist->{resources}[0]{_meta}{x}, 1, 'resource _meta merged';
};

subtest 'apply rebuilds in place, keeping the instance' => sub {
  my $before = "$server";
  MCP::Hub::Facade->apply($server, $up, {
    server_info => {name => 'context7', version => '2.0.0'},
    tools => [{name => 'other', description => 'new', inputSchema => {type => 'object'}}],
  });
  is "$server", $before, 'same server object';
  is $server->version, '2.0.0', 'version updated';
  is scalar(@{$server->tools}), 1, 'one tool';
  is $server->tools->[0]{name} // $server->tools->[0]->name, 'other', 'tool replaced';
  is $server->instructions, undef, 'instructions cleared when absent';
};

done_testing;
