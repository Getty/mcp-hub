#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File qw(curfile tempdir);
use MCP::Hub;

use lib curfile->sibling('lib')->to_string;

# /all names an entry "<server>__<name>", and a server name may itself contain
# "__": entries p and p__x both put "p__x__..." names on /all. What a profile
# lets through must be decided by the server an entry came from, not by
# reading everything before the first "__" as the server.

# One tool and one prompt, both named by `name`, both answering `reply` -- so a
# test can tell which server a call reached. Both are listed with the title,
# icons and _meta in `extra`, as a real upstream lists them, and need the
# `scopes`, if any.
package OneTool {
  use Mojo::Base 'MCP::Server', -signatures;

  has listed_extra => sub { {} };

  sub new ($class, %args) {
    my $self = $class->SUPER::new(name => 'one-tool', listed_extra => $args{extra} // {});
    $self->tool(
      name         => $args{name},
      description  => 'Answer with the reply',
      input_schema => {type => 'object'},
      scopes       => $args{scopes} // [],
      code         => sub ($tool, $in) { return $tool->text_result($args{reply}) },
    );
    $self->prompt(
      name        => $args{name},
      description => 'Answer with the reply',
      scopes      => $args{scopes} // [],
      code        => sub ($prompt, $in) { return $prompt->text_prompt($args{reply}) },
    );
    return $self;
  }

  sub _handle_tools_list ($self, $context) {
    my ($result, @hints) = $self->SUPER::_handle_tools_list($context);
    %$_ = (%$_, %{$self->listed_extra}) for @{$result->{tools}};
    return ($result, @hints);
  }

  sub _handle_prompts_list ($self, $context) {
    my ($result, @hints) = $self->SUPER::_handle_prompts_list($context);
    %$_ = (%$_, %{$self->listed_extra}) for @{$result->{prompts}};
    return ($result, @hints);
  }
}

package main;

my @ECHO_TOOLS = qw(die echo exit fail notify sleep);

sub hub ($servers) {
  my $cache = tempdir;
  return MCP::Hub->new(hub_config_input => {
    mcpServers => $servers,
    hub        => {
      cache_dir => "$cache",
      profiles  => {
        ponly => {servers => ['p']},
        xonly => {servers => ['p__x']},
        xecho => {servers => ['p__x'], tools => {p__x => {allow => ['echo']}}},
        pecho => {servers => ['p', 'p__x'], tools => {p => {allow => ['echo']}}},
        every => {servers => ['*']},
      },
      clients => {
        p     => {token => 'tok-p',     profile => 'ponly'},
        x     => {token => 'tok-x',     profile => 'xonly'},
        xecho => {token => 'tok-xecho', profile => 'xecho'},
        pecho => {token => 'tok-pecho', profile => 'pecho'},
        every => {token => 'tok-every', profile => 'every'},
      },
    },
  });
}

sub echo_hub () { return hub({p => {class => 'EchoServer'}, p__x => {class => 'EchoServer'}}) }

# One JSON-RPC request, answered in full: the status and the body.
sub rpc ($t, $path, $token, $method, $params = {}) {
  my $res = $t->post_ok($path => {Authorization => "Bearer $token"}
      => json => {jsonrpc => '2.0', id => 1, method => $method, params => $params})->tx->res;
  return {status => $res->code, %{$res->json // {}}};
}

sub names ($t, $token, $kind) {
  return [sort map { $_->{name} } @{rpc($t, '/all', $token, "$kind/list")->{result}{$kind} // []}];
}

# Each entry of a list as its name and the display fields it carries, in list
# order.
sub shown ($t, $token, $kind) {
  return [map {
    my $entry = $_;
    +{map { exists $entry->{$_} ? ($_ => $entry->{$_}) : () } qw(name title icons _meta)}
  } @{rpc($t, '/all', $token, "$kind/list")->{result}{$kind} // []}];
}

sub call ($t, $token, $name) {
  return rpc($t, '/all', $token, 'tools/call', {name => $name, arguments => {msg => 'hi'}});
}

sub get ($t, $token, $name) {
  return rpc($t, '/all', $token, 'prompts/get', {name => $name, arguments => {who => 'agent'}});
}

sub not_found ($res, $kind, $name) {
  return !exists $res->{result} && ($res->{error}{message} // '') eq "$kind '$name' not found";
}

subtest 'a profile allowing p does not reach the tools and prompts of p__x' => sub {
  my $t = Test::Mojo->new(echo_hub());

  is_deeply names($t, 'tok-every', 'tools'), [sort map { ("p__$_", "p__x__$_") } @ECHO_TOOLS],
    'control: a profile that sees both lists the tools of both';

  is_deeply names($t, 'tok-p', 'tools'), [map {"p__$_"} @ECHO_TOOLS], 'only the tools of p are listed';
  is call($t, 'tok-p', 'p__echo')->{result}{content}[0]{text}, 'hi', 'control: a tool of p is called';
  ok not_found(call($t, 'tok-p', 'p__x__echo'), 'Tool', 'p__x__echo'), 'p__x__echo is not found';

  is_deeply names($t, 'tok-p', 'prompts'), ['p__greet'], 'only the prompt of p is listed';
  is get($t, 'tok-p', 'p__greet')->{result}{messages}[0]{content}{text}, 'Hello, agent!',
    'control: the prompt of p is served';
  ok not_found(get($t, 'tok-p', 'p__x__greet'), 'Prompt', 'p__x__greet'), 'p__x__greet is not found';
};

subtest 'a profile allowing p__x sees and reaches its own, and nothing of p' => sub {
  my $t = Test::Mojo->new(echo_hub());

  is_deeply names($t, 'tok-x', 'tools'), [map {"p__x__$_"} @ECHO_TOOLS], 'the tools of p__x are listed';
  is call($t, 'tok-x', 'p__x__echo')->{result}{content}[0]{text}, 'hi', 'and called';
  ok not_found(call($t, 'tok-x', 'p__echo'), 'Tool', 'p__echo'), 'p__echo is not found';

  is_deeply names($t, 'tok-x', 'prompts'), ['p__x__greet'], 'the prompt of p__x is listed';
  is get($t, 'tok-x', 'p__x__greet')->{result}{messages}[0]{content}{text}, 'Hello, agent!', 'and served';
  ok not_found(get($t, 'tok-x', 'p__greet'), 'Prompt', 'p__greet'), 'p__greet is not found';
};

subtest 'a tools rule applies to the server an entry came from' => sub {
  my $t = Test::Mojo->new(echo_hub());

  is_deeply names($t, 'tok-xecho', 'tools'), ['p__x__echo'], 'a rule on p__x leaves only its echo';
  is call($t, 'tok-xecho', 'p__x__echo')->{result}{content}[0]{text}, 'hi', 'which is called';
  ok not_found(call($t, 'tok-xecho', 'p__x__fail'), 'Tool', 'p__x__fail'), 'p__x__fail is not found';
  is_deeply names($t, 'tok-xecho', 'prompts'), ['p__x__greet'], 'the rule leaves the prompt alone';

  is_deeply names($t, 'tok-pecho', 'tools'), [sort 'p__echo', map {"p__x__$_"} @ECHO_TOOLS],
    'a rule on p leaves only its echo, and every tool of p__x';
  is call($t, 'tok-pecho', 'p__x__fail')->{result}{content}[0]{text}, 'deliberate failure',
    'a tool of p__x the rule on p does not name is called';
  ok not_found(call($t, 'tok-pecho', 'p__fail'), 'Tool', 'p__fail'), 'p__fail is not found';
};

# A known limit, pinned rather than fixed: p's tool x__echo and p__x's tool echo
# are both "p__x__echo" on /all. Both are listed; a call reaches the first, in
# server-name order -- p's. Refusing "__" in server names would end this; that
# is the maintainer's call (k69).
subtest 'two servers can produce the same /all name: the first wins' => sub {
  my $t = Test::Mojo->new(hub({
    p    => {class => 'OneTool', args => {name => 'x__echo', reply => 'from p'}},
    p__x => {class => 'OneTool', args => {name => 'echo',    reply => 'from p__x'}},
  }));

  is_deeply names($t, 'tok-every', 'tools'),   [qw(p__x__echo p__x__echo)], 'both tools are listed by one name';
  is_deeply names($t, 'tok-every', 'prompts'), [qw(p__x__echo p__x__echo)], 'both prompts are listed by one name';
  is call($t, 'tok-every', 'p__x__echo')->{result}{content}[0]{text}, 'from p', 'a call reaches the tool of p';
  is get($t, 'tok-every', 'p__x__echo')->{result}{messages}[0]{content}{text}, 'from p', 'a get, the prompt of p';

  # Under a profile that sees only one of them, the name means that one.
  is_deeply names($t, 'tok-x', 'tools'), ['p__x__echo'], 'p__x alone: one tool listed';
  is call($t, 'tok-x', 'p__x__echo')->{result}{content}[0]{text}, 'from p__x', 'the call reaches p__x';
  is get($t, 'tok-x', 'p__x__echo')->{result}{messages}[0]{content}{text}, 'from p__x', 'the get too';
  is_deeply names($t, 'tok-p', 'tools'), ['p__x__echo'], 'p alone: one tool listed';
  is call($t, 'tok-p', 'p__x__echo')->{result}{content}[0]{text}, 'from p', 'the call reaches p';
};

# What each of the two lists for its entry: p a title only, p__x all three.
my $P_EXTRA  = {title => 'Echo of p'};
my $PX_EXTRA = {title => 'Echo of p__x', icons => [{src => 'file://p__x.png'}], _meta => {from => 'p__x'}};

# A shared name must not share the display fields: each entry shows the title,
# icons and _meta of its own server, and a profile that sees one of them none
# of the other's -- not even a field its own entry lacks.
subtest 'two servers can produce the same /all name: each entry keeps its own fields' => sub {
  my $t = Test::Mojo->new(hub({
    p    => {class => 'OneTool', args => {name => 'x__echo', reply => 'from p',    extra => $P_EXTRA}},
    p__x => {class => 'OneTool', args => {name => 'echo',    reply => 'from p__x', extra => $PX_EXTRA}},
  }));

  for my $kind (qw(tools prompts)) {
    is_deeply shown($t, 'tok-p', $kind), [{name => 'p__x__echo', %$P_EXTRA}],
      "$kind: p alone shows the fields of p, none of p__x";
    is_deeply shown($t, 'tok-x', $kind), [{name => 'p__x__echo', %$PX_EXTRA}],
      "$kind: p__x alone shows the fields of p__x";
    is_deeply shown($t, 'tok-every', $kind), [{name => 'p__x__echo', %$P_EXTRA}, {name => 'p__x__echo', %$PX_EXTRA}],
      "$kind: both listed, each with the fields of its own server";
  }
};

# A list leaves out what the request's scopes do not cover, so the entries
# after one left out move up by one: an entry hidden by its scope lends nothing
# to the next one of its name either.
subtest 'two servers can produce the same /all name: one hidden by its scope lends no fields' => sub {
  my $hub = hub({
    p    => {class => 'OneTool', args => {name => 'x__echo', reply => 'from p', extra => $P_EXTRA, scopes => ['p:echo']}},
    p__x => {class => 'OneTool', args => {name => 'echo', reply => 'from p__x', extra => $PX_EXTRA}},
  });
  my $t = Test::Mojo->new($hub);

  # What MCP 0.15's HTTP transport does with an `auth` callback (see
  # t/aggregate-fields.t): its scopes are checked; this one grants none.
  $hub->aggregate->transport->auth(sub ($c) { return {scopes => []} });

  for my $kind (qw(tools prompts)) {
    is_deeply shown($t, 'tok-every', $kind), [{name => 'p__x__echo', %$PX_EXTRA}],
      "$kind: only p__x is listed, with its own fields";
  }
};

done_testing;
