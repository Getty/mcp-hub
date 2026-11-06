#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File qw(curfile tempdir);
use MCP::Client;
use MCP::Hub;

use lib curfile->sibling('lib')->to_string;

# What /all says about itself -- server/discover's instructions and
# capabilities, the legacy initialize's capabilities -- must follow the
# caller's profile like its lists do. The instructions are headed "## <name>":
# shown unfiltered, they name servers the profile is meant to hide (their own
# endpoint answers 404 for exactly that reason).

# Instructions and a tool, no prompt.
package Toolbox {
  use Mojo::Base 'MCP::Server', -signatures;

  sub new ($class, @args) {
    my $self = $class->SUPER::new(name => 'toolbox', @args);
    $self->instructions('Toolbox things.');
    $self->tool(
      name         => 'probe',
      description  => 'Answer ok',
      input_schema => {type => 'object'},
      code         => sub ($tool, $in) { return $tool->text_result('ok') },
    );
    return $self;
  }
}

# A tool and nothing else.
package Bare {
  use Mojo::Base 'MCP::Server', -signatures;

  sub new ($class, @args) {
    my $self = $class->SUPER::new(name => 'bare', @args);
    $self->tool(
      name         => 'probe',
      description  => 'Answer ok',
      input_schema => {type => 'object'},
      code         => sub ($tool, $in) { return $tool->text_result('ok') },
    );
    return $self;
  }
}

package main;

sub hub () {
  my $cache = tempdir;
  return MCP::Hub->new(hub_config_input => {
    mcpServers => {box => {class => 'Toolbox'}, bare => {class => 'Bare'}, echo => {class => 'EchoServer'}},
    hub        => {
      cache_dir => "$cache",
      profiles  => {
        echoonly => {servers => ['echo']},
        boxonly  => {servers => ['box']},
        bareonly => {servers => ['bare']},
        notools  => {servers => ['bare'], tools => {bare => {allow => []}}},
        every    => {servers => ['*']},
      },
      clients => {
        echo  => {token => 'tok-echo',  profile => 'echoonly'},
        box   => {token => 'tok-box',   profile => 'boxonly'},
        bare  => {token => 'tok-bare',  profile => 'bareonly'},
        none  => {token => 'tok-none',  profile => 'notools'},
        every => {token => 'tok-every', profile => 'every'},
      },
    },
  });
}

sub discover ($t, $token) {
  my $base = $t->ua->server->url->to_string;
  $base =~ s{/$}{};
  return MCP::Client->new(ua => $t->ua, url => "$base/all", headers => {Authorization => "Bearer $token"})->discover;
}

# The handshake of a client speaking a protocol revision before server/discover.
sub initialize ($t, $token) {
  my $params = {protocolVersion => '2025-06-18', capabilities => {}, clientInfo => {name => 't', version => '1'}};
  return $t->post_ok('/all' => {Authorization => "Bearer $token"}
      => json => {jsonrpc => '2.0', id => 1, method => 'initialize', params => $params})->tx->res->json->{result};
}

subtest 'server/discover on /all carries only the instructions of servers the profile allows' => sub {
  my $t = Test::Mojo->new(hub());

  is discover($t, 'tok-every')->{instructions}, "## box\nToolbox things.\n\n## echo\nEcho things back.",
    'control: a profile that sees every server gets every section';

  is discover($t, 'tok-echo')->{instructions}, "## echo\nEcho things back.", 'echo alone: only its section';
  is discover($t, 'tok-box')->{instructions},  "## box\nToolbox things.",    'box alone: only its section';
  ok !exists discover($t, 'tok-bare')->{instructions}, 'bare alone, which has none: no instructions at all';
};

subtest 'the answer depends on the caller, so it is not public' => sub {
  my $t = Test::Mojo->new(hub());
  is discover($t, 'tok-box')->{cacheScope}, 'private', 'cacheScope is private';
};

subtest 'server/discover on /all advertises prompts and tools only when the profile sees some' => sub {
  my $t = Test::Mojo->new(hub());

  my $every = discover($t, 'tok-every')->{capabilities};
  ok exists $every->{prompts}, 'control: a profile that sees echo is offered prompts';
  ok exists $every->{tools},   'and tools';

  my $box = discover($t, 'tok-box')->{capabilities};
  ok !exists $box->{prompts}, 'box alone has no prompt: none offered';
  ok exists $box->{tools},    'its tools are';
  ok !exists $box->{resources}, '/all aggregates no resources';

  ok !exists discover($t, 'tok-none')->{capabilities}{tools}, 'a profile whose rule hides every tool: no tools offered';
};

subtest 'so does the legacy initialize' => sub {
  my $t = Test::Mojo->new(hub());

  ok exists initialize($t, 'tok-every')->{capabilities}{prompts}, 'control: prompts offered to a profile that sees echo';
  my $box = initialize($t, 'tok-box')->{capabilities};
  ok !exists $box->{prompts}, 'box alone: no prompts offered';
  ok exists $box->{tools},    'tools are';
};

done_testing;
