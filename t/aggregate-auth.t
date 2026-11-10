#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File qw(curfile tempdir);
use MCP::Constants qw(META_CLIENT_CAPABILITIES META_PROTOCOL_VERSION PROTOCOL_VERSION);
use MCP::Hub;
use MCP::Server::Context;

use lib curfile->sibling('lib')->to_string;

# /all under a profile that may see only one of two servers. Both are the
# in-process EchoServer -- tools echo, fail, ...; prompt greet -- so whatever
# /all shows of q, a profile limited to p must not see, list or reach.

sub hub ($hub = {}) {
  my $cache = tempdir;
  return MCP::Hub->new(hub_config_input => {
    mcpServers => {p => {class => 'EchoServer'}, q => {class => 'EchoServer'}},
    hub        => {
      cache_dir => "$cache",
      profiles  => {
        ponly => {servers => ['p']},
        pecho => {servers => ['p'], tools => {p => {allow => ['echo']}}},
        every => {servers => ['*']},
      },
      clients => {
        limited => {token => 'tok-limited', profile => 'ponly'},
        narrow  => {token => 'tok-narrow',  profile => 'pecho'},
        full    => {token => 'tok-full',    profile => 'every'},
      },
      %$hub,
    },
  });
}

# One JSON-RPC request, answered in full: the status and the body.
sub rpc ($t, $path, $token, $method, $params = {}) {
  my $headers = defined $token ? {Authorization => "Bearer $token"} : {};
  my $res = $t->post_ok($path => $headers => json => {jsonrpc => '2.0', id => 1, method => $method, params => $params})
    ->tx->res;
  return {status => $res->code, %{$res->json // {}}};
}

sub names ($result, $kind) { return [sort map { $_->{name} } @{$result->{result}{$kind} // []}] }

sub greet ($name) { return {name => $name, arguments => {who => 'agent'}} }
sub echo ($name)  { return {name => $name, arguments => {msg => 'hi'}} }

subtest 'control: the endpoint of a server outside the profile is 404' => sub {
  my $t = Test::Mojo->new(hub());
  is rpc($t, '/q', 'tok-limited', 'prompts/get', greet('greet'))->{status}, 404, 'prompts/get on /q';
  is rpc($t, '/q', 'tok-limited', 'tools/call',  echo('echo'))->{status},   404, 'tools/call on /q';
};

subtest '/all lists only the prompts of servers the profile allows' => sub {
  my $t = Test::Mojo->new(hub());

  is_deeply names(rpc($t, '/all', 'tok-full', 'prompts/list'), 'prompts'), [qw(p__greet q__greet)],
    'control: a profile that sees both lists both prompts';

  my $list = rpc($t, '/all', 'tok-limited', 'prompts/list');
  is_deeply names($list, 'prompts'), ['p__greet'], 'q__greet is not listed';
  is $list->{result}{cacheScope}, 'private', 'the list depends on the profile, so it is private';
};

subtest '/all answers prompts/get of a hidden prompt as not found' => sub {
  my $t = Test::Mojo->new(hub());

  my $own = rpc($t, '/all', 'tok-limited', 'prompts/get', greet('p__greet'));
  is $own->{result}{messages}[0]{content}{text}, 'Hello, agent!', 'control: the allowed prompt is served';

  my $hidden = rpc($t, '/all', 'tok-limited', 'prompts/get', greet('q__greet'));
  ok !exists $hidden->{result}, 'q__greet is not run';
  is_deeply $hidden->{error}, {code => -32602, message => "Prompt 'q__greet' not found"}, 'it is not found';

  my $unknown = rpc($t, '/all', 'tok-limited', 'prompts/get', greet('r__greet'));
  is $hidden->{status}, $unknown->{status}, 'same status as a prompt that does not exist';
  is $hidden->{error}{code}, $unknown->{error}{code}, 'same error code as a prompt that does not exist';
};

subtest '/all lists and calls only the tools of servers the profile allows' => sub {
  my $t = Test::Mojo->new(hub());

  my $tools = names(rpc($t, '/all', 'tok-limited', 'tools/list'), 'tools');
  ok scalar(@$tools), 'p has tools on /all';
  is_deeply [grep { !/^p__/ } @$tools], [], 'only tools of p are listed';

  is rpc($t, '/all', 'tok-limited', 'tools/call', echo('p__echo'))->{result}{content}[0]{text}, 'hi',
    'control: a tool of p is called';
  my $hidden = rpc($t, '/all', 'tok-limited', 'tools/call', echo('q__echo'));
  ok !exists $hidden->{result}, 'q__echo is not run';
  is_deeply $hidden->{error}, {code => -32602, message => "Tool 'q__echo' not found"}, 'it is not found';
};

subtest 'a tools rule holds for tools/call on /all, and leaves prompts alone' => sub {
  my $t = Test::Mojo->new(hub());

  is_deeply names(rpc($t, '/all', 'tok-narrow', 'tools/list'), 'tools'), ['p__echo'], 'only the allowed tool is listed';
  is rpc($t, '/all', 'tok-narrow', 'tools/call', echo('p__echo'))->{result}{content}[0]{text}, 'hi',
    'control: the allowed tool is called';

  my $own = rpc($t, '/p', 'tok-narrow', 'tools/call', {name => 'fail', arguments => {}});
  is_deeply $own->{error}, {code => -32602, message => "Tool 'fail' not found"},
    'control: on its own endpoint the denied tool is not found';
  my $denied = rpc($t, '/all', 'tok-narrow', 'tools/call', {name => 'p__fail', arguments => {}});
  ok !exists $denied->{result}, 'p__fail is not run';
  is_deeply $denied->{error}, {code => -32602, message => "Tool 'p__fail' not found"}, 'on /all it is not found either';

  # Prompts follow servers alone (MCP::Hub::Auth): a tools rule does not touch them.
  is_deeply names(rpc($t, '/all', 'tok-narrow', 'prompts/list'), 'prompts'), ['p__greet'], 'the prompt of p is listed';
  is rpc($t, '/all', 'tok-narrow', 'prompts/get', greet('p__greet'))->{result}{messages}[0]{content}{text},
    'Hello, agent!', 'and served';
};

subtest 'public_profile: a request without a token is filtered alike' => sub {
  my $t = Test::Mojo->new(hub({public_profile => 'ponly'}));

  is_deeply names(rpc($t, '/all', undef, 'prompts/list'), 'prompts'), ['p__greet'], 'q__greet is not listed';
  my $hidden = rpc($t, '/all', undef, 'prompts/get', greet('q__greet'));
  ok !exists $hidden->{result}, 'q__greet is not run';
  is_deeply $hidden->{error}, {code => -32602, message => "Prompt 'q__greet' not found"}, 'it is not found';
  is_deeply rpc($t, '/all', undef, 'tools/call', echo('q__echo'))->{error},
    {code => -32602, message => "Tool 'q__echo' not found"}, 'q__echo is not found';
};

# The /all filters read the profile the auth bridge stashed. A request that
# comes to /all without one -- with no controller, or with one that never went
# through the bridge -- must not see everything for it: in clients mode it sees
# nothing, and in open mode what every request there sees, everything.
subtest 'without a stashed profile, /all shows nothing in clients mode, everything in open mode' => sub {
  my $open = MCP::Hub->new(hub_config_input => {
    mcpServers => {p => {class => 'EchoServer'}, q => {class => 'EchoServer'}},
    hub        => {cache_dir => tempdir->to_string},
  });
  my $meta = {META_PROTOCOL_VERSION() => PROTOCOL_VERSION, META_CLIENT_CAPABILITIES() => {}};
  my $ask  = sub ($hub, $ctx, $method, $params = {}) {
    my $res = $hub->aggregate->handle(
      {jsonrpc => '2.0', id => 1, method => $method, params => {%$params, _meta => $meta}}, $ctx);
    $res->then(sub { $res = shift })->wait if ref $res ne 'HASH';    # a tool call in flight
    return $res;
  };

  for my $case (['clients', hub()], ['open', $open]) {
    my ($mode, $hub) = @$case;
    is $hub->hub_config->mode, $mode, "a hub in $mode mode";
    for my $without (['no controller', sub { MCP::Server::Context->new }],
      ['a controller without a profile', sub { MCP::Server::Context->new(controller => $hub->build_controller) }])
    {
      my ($what, $ctx) = @$without;
      my $tools    = $ask->($hub, $ctx->(), 'tools/list')->{result}{tools};
      my $prompts  = $ask->($hub, $ctx->(), 'prompts/list')->{result}{prompts};
      my $discover = $ask->($hub, $ctx->(), 'server/discover')->{result};
      my $call     = $ask->($hub, $ctx->(), 'tools/call', echo('p__echo'));

      if ($mode eq 'clients') {
        is_deeply $tools,   [], "$mode mode, $what: no tools";
        is_deeply $prompts, [], '...no prompts';
        ok !exists $discover->{instructions}, '...no instructions';
        ok !exists $discover->{capabilities}{$_}, "...and no $_ capability" for qw(tools prompts);
        is_deeply $call->{error}, {code => -32602, message => "Tool 'p__echo' not found"}, '...and no tool is run';
      }
      else {
        my @every = sort map {
          my $srv = $_;
          map { "${srv}__" . $_->name } @{$hub->upstreams_by_name->{$srv}->server->tools};
        } qw(p q);
        is_deeply [sort map { $_->{name} } @$tools], \@every, "$mode mode, $what: every tool";
        is_deeply [sort map { $_->{name} } @$prompts], [qw(p__greet q__greet)], '...every prompt';
        is $discover->{instructions}, "## p\nEcho things back.\n\n## q\nEcho things back.", '...every instruction';
        is $call->{result}{content}[0]{text}, 'hi', '...and its tools are run';
      }
    }
  }
};

done_testing;
