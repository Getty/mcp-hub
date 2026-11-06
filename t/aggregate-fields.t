#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File qw(tempdir);
use MCP::Hub;

# An in-process class whose tools and prompts declare what MCP::Primitive keeps
# besides the wire fields: scopes, cache_ttl and cache_scope. Every tool and
# every prompt has a cache_ttl, so the list's ttlMs (the smallest one listed)
# is not 0 on its own endpoint.
package ScopedEcho {
  use Mojo::Base 'MCP::Server', -signatures;

  sub new ($class, @args) {
    my $self = $class->SUPER::new(name => 'scoped-echo', version => '1.0.0', @args);

    $self->tool(
      name        => 'echo',
      description => 'Echo, unscoped',
      cache_ttl   => 60_000,
      cache_scope => 'private',
      code        => sub ($tool, $args) { return $tool->text_result('echo') },
    );
    $self->tool(
      name        => 'guarded',
      description => 'Echo, scoped',
      scopes      => ['echo:guarded'],
      cache_ttl   => 60_000,
      code        => sub ($tool, $args) { return $tool->text_result('guarded') },
    );

    $self->prompt(
      name        => 'greet',
      description => 'Greeting, unscoped',
      cache_ttl   => 30_000,
      cache_scope => 'private',
      code        => sub ($prompt, $args) { return $prompt->text_prompt('hello') },
    );
    $self->prompt(
      name        => 'guarded_greet',
      description => 'Greeting, scoped',
      scopes      => ['echo:guarded'],
      cache_ttl   => 30_000,
      code        => sub ($prompt, $args) { return $prompt->text_prompt('hello, guarded') },
    );

    return $self;
  }
}

sub hub ($hub = {}) {
  my $cache = tempdir;
  return MCP::Hub->new(hub_config_input => {
    mcpServers => {scoped => {class => 'ScopedEcho'}},
    hub        => {cache_dir => "$cache", %$hub},
  });
}

# One JSON-RPC request, answered in full: the status, the WWW-Authenticate
# header and the body.
sub rpc ($t, $path, $method, $params = {}, $headers = {}) {
  my $res = $t->post_ok($path => $headers => json => {jsonrpc => '2.0', id => 1, method => $method, params => $params})
    ->tx->res;
  return {status => $res->code, challenge => $res->headers->www_authenticate // '', %{$res->json // {}}};
}

sub names ($result, $kind) { return [sort map { $_->{name} } @{$result->{result}{$kind} // []}] }

# What MCP 0.15's HTTP transport does once it has an `auth` callback: the
# callback's `scopes` become Context->scopes, and every scoped primitive is
# checked against them. The hub sets no callback, so no scope is checked
# anywhere today; this sets the same one on the server's own endpoint and on
# /all, so the two are compared under the same conditions.
sub enforce_scopes ($hub, $name, @granted) {
  my ($up) = grep { $_->name eq $name } @{$hub->upstreams};
  $up->action;    # builds the endpoint, and with it the server's transport
  $_->auth(sub ($c) { return {scopes => [@granted]} }) for $up->server->transport, $hub->aggregate->transport;
  return;
}

subtest 'today the hub enforces no scopes: own endpoint and /all serve a scoped tool alike' => sub {
  my %mode = (
    open    => [{}, {}],
    clients => [{
      profiles => {worker => {servers => ['*']}},
      clients  => {worker => {token => 'tok-worker', profile => 'worker'}},
    }, {Authorization => 'Bearer tok-worker'}],
  );
  for my $mode (sort keys %mode) {
    my ($config, $auth) = @{$mode{$mode}};
    my $t = Test::Mojo->new(hub($config));

    my $own = rpc($t, '/scoped', 'tools/call', {name => 'guarded'}, $auth);
    my $all = rpc($t, '/all', 'tools/call', {name => 'scoped__guarded'}, $auth);
    is $own->{status}, 200, "$mode: the own endpoint serves the scoped tool";
    is $all->{status}, 200, "$mode: so does /all";
    is_deeply $all->{result}{content}, $own->{result}{content}, "$mode: with the same result";
  }
};

subtest 'scopes: /all refuses a scoped tool where its own endpoint does' => sub {
  my $hub = hub();
  my $t   = Test::Mojo->new($hub);
  enforce_scopes($hub, 'scoped');

  my $own = rpc($t, '/scoped', 'tools/call', {name => 'guarded'});
  is $own->{status}, 403, 'control: the own endpoint refuses the call';
  is $own->{error}{code}, -32003, 'control: as insufficient scope';
  is_deeply names(rpc($t, '/scoped', 'tools/list'), 'tools'), ['echo'], 'control: and does not list it';

  my $all = rpc($t, '/all', 'tools/call', {name => 'scoped__guarded'});
  is $all->{status}, 403, '/all refuses the call too';
  is $all->{error}{code}, -32003, 'as insufficient scope';
  like $all->{challenge}, qr/scope="echo:guarded"/, 'naming the scope it needs';
  is_deeply names(rpc($t, '/all', 'tools/list'), 'tools'), ['scoped__echo'], '/all does not list it either';
  is rpc($t, '/all', 'tools/call', {name => 'scoped__echo'})->{status}, 200, 'an unscoped tool is still served';

  enforce_scopes($hub, 'scoped', 'echo:guarded');
  is rpc($t, '/scoped', 'tools/call', {name => 'guarded'})->{status}, 200, 'control: granted, the own endpoint serves it';
  is rpc($t, '/all', 'tools/call', {name => 'scoped__guarded'})->{status}, 200, 'granted, /all serves it';
};

subtest 'scopes: /all refuses a scoped prompt where its own endpoint does' => sub {
  my $hub = hub();
  my $t   = Test::Mojo->new($hub);

  # Visible without any enforcement: a scoped prompt makes a list private.
  is rpc($t, '/scoped', 'prompts/list')->{result}{cacheScope}, 'private', 'control: own prompt list is private';
  is rpc($t, '/all', 'prompts/list')->{result}{cacheScope}, 'private', '/all prompt list is private as well';

  enforce_scopes($hub, 'scoped');
  my $own = rpc($t, '/scoped', 'prompts/get', {name => 'guarded_greet'});
  is $own->{status}, 403, 'control: the own endpoint refuses the prompt';
  is $own->{error}{code}, -32003, 'control: as insufficient scope';
  is_deeply names(rpc($t, '/scoped', 'prompts/list'), 'prompts'), ['greet'], 'control: and does not list it';

  my $all = rpc($t, '/all', 'prompts/get', {name => 'scoped__guarded_greet'});
  is $all->{status}, 403, '/all refuses the prompt too';
  is $all->{error}{code}, -32003, 'as insufficient scope';
  is_deeply names(rpc($t, '/all', 'prompts/list'), 'prompts'), ['scoped__greet'], '/all does not list it either';

  enforce_scopes($hub, 'scoped', 'echo:guarded');
  is rpc($t, '/all', 'prompts/get', {name => 'scoped__guarded_greet'})->{status}, 200, 'granted, /all serves it';
};

subtest 'cache_ttl: /all advertises the ttl of what it lists' => sub {
  my $t = Test::Mojo->new(hub());

  is rpc($t, '/scoped', 'tools/list')->{result}{ttlMs}, 60_000, 'control: own tool list ttl';
  is rpc($t, '/all', 'tools/list')->{result}{ttlMs}, 60_000, '/all tool list ttl';
  is rpc($t, '/scoped', 'prompts/list')->{result}{ttlMs}, 30_000, 'control: own prompt list ttl';
  is rpc($t, '/all', 'prompts/list')->{result}{ttlMs}, 30_000, '/all prompt list ttl';
};

# MCP 0.15 reads a primitive's cache_scope only for resources/read, which /all
# does not aggregate, so for tools and prompts it is checked on the objects.
subtest 'cache_scope: the /all wrappers keep the cache_scope' => sub {
  my $all = hub()->aggregate;
  my %tool   = map { $_->name => $_ } @{$all->tools};
  my %prompt = map { $_->name => $_ } @{$all->prompts};

  is $tool{scoped__echo}->cache_scope,     'private', 'the tool keeps its cache_scope';
  is $tool{scoped__guarded}->cache_scope,  'public',  'and the default stays the default';
  is $prompt{scoped__greet}->cache_scope,  'private', 'the prompt keeps its cache_scope';
  is $prompt{scoped__guarded_greet}->cache_scope, 'public', 'and the default stays the default';
};

done_testing;
