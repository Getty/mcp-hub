#!/usr/bin/env perl
# A call to an in-process class that holds the hub's loop longer than the
# inactivity timeout keeps its answer, on the class's own endpoint and through
# /all. The server answered such a call there and then, and the transport
# rendered it directly: under Mojo::Reactor::EV the connection's inactivity
# timer, re-armed with the loop's time from before the call, fired as soon as
# the loop went on, and closed the connection before the answer was written --
# the agent saw "Premature connection close". Every call is now streamed, as the
# answer of an upstream outside the hub always was, which turns that timer off
# (MCP::Hub::Endpoint). Under Mojo::Reactor::Poll the timer is re-armed with
# the time after the call and the answer got through even before; there the
# event-stream content type is what tells the streamed answer from the rendered
# one. Lists, and errors the server answers with, go out as they did.
use Mojo::Base -strict, -signatures;

BEGIN { $ENV{MOJO_INACTIVITY_TIMEOUT} = 1 }

use Test::More;
use Test::Mojo;
use Mojo::File qw(tempdir);
use MCP::Client;
use MCP::Hub;

# How long each call holds the loop: longer than the inactivity timeout above.
my $BLOCK = 1.5;

# An in-process class whose every tool, prompt and resource blocks the loop --
# a long git walk, a big file read -- before it answers.
package Blocking {
  use Mojo::Base 'MCP::Server', -signatures;

  sub block () { select undef, undef, undef, $BLOCK }

  sub new ($class, @args) {
    my $self = $class->SUPER::new(name => 'blocking', @args);
    $self->tool(
      name          => 'count',
      description   => 'Count, slowly',
      input_schema  => {type => 'object'},
      output_schema => {type => 'object', properties => {n => {type => 'integer'}}, required => ['n']},
      code          => sub ($tool, $args) { block(); return $tool->structured_result({n => 3}) },
    );
    $self->tool(
      name         => 'fail',
      description  => 'Fail, slowly',
      input_schema => {type => 'object'},
      code         => sub ($tool, $args) { block(); return $tool->text_result('it failed', 1) },
    );
    $self->prompt(
      name => 'slow',
      code => sub ($prompt, $args) { block(); return $prompt->text_prompt('a slow prompt') },
    );
    $self->resource(
      uri  => 'slow://it',
      name => 'it',
      code => sub ($resource) { block(); return $resource->text_resource('a slow resource') },
    );
    return $self;
  }
}

my $dir = tempdir;
my $app = MCP::Hub->new(hub_config_input => {
  mcpServers => {slow => {class => 'Blocking'}},
  hub        => {cache_dir => "$dir/cache"},
});
$app->log->level('fatal');
my $t = Test::Mojo->new($app);

# The client waits as long as it takes; only the hub's side has the short timeout.
$t->ua->inactivity_timeout(30);
my $tx;
$t->ua->on(start => sub ($ua, $started) { $tx = $started });

sub client ($path) {
  my $base = $t->ua->server->url->to_string =~ s{/$}{}r;
  return MCP::Client->new(ua => $t->ua, url => "$base$path");
}

# Make a call; what it answered (or the error as {err => ...}), and the content
# type the hub answered with.
sub answer ($call) {
  undef $tx;
  my $out  = eval { $call->() } // {err => $@ || 'no answer'};
  my $type = $tx ? $tx->res->headers->content_type // '' : '';
  return ($out, $type);
}

for my $path ('/slow', '/all') {
  subtest "$path: a call that blocks past the inactivity timeout keeps its answer" => sub {
    my $client = client($path);
    my $prefix = $path eq '/all' ? 'slow__' : '';

    my ($count, $type) = answer(sub { $client->call_tool("${prefix}count") });
    is_deeply $count->{structuredContent}, {n => 3}, 'tools/call: structuredContent as the tool gave it'
      or diag explain $count;
    is $count->{content}[0]{text}, '{"n":3}', 'tools/call: and its content';
    ok defined $count->{isError} && !$count->{isError}, 'tools/call: not an error';
    like $type, qr{^text/event-stream}, 'tools/call: streamed';

    my ($fail, $fail_type) = answer(sub { $client->call_tool("${prefix}fail") });
    is $fail->{content}[0]{text}, 'it failed', 'an error result: its content' or diag explain $fail;
    ok $fail->{isError}, 'an error result: still an error';
    like $fail_type, qr{^text/event-stream}, 'an error result: streamed';

    my ($prompt, $prompt_type) = answer(sub { $client->get_prompt("${prefix}slow") });
    is $prompt->{messages}[0]{content}{text}, 'a slow prompt', 'prompts/get: answered' or diag explain $prompt;
    like $prompt_type, qr{^text/event-stream}, 'prompts/get: streamed';

    # /all does not aggregate resources.
    if ($path eq '/slow') {
      my ($read, $read_type) = answer(sub { $client->read_resource('slow://it') });
      is $read->{contents}[0]{text}, 'a slow resource', 'resources/read: answered' or diag explain $read;
      like $read_type, qr{^text/event-stream}, 'resources/read: streamed';
    }
  };
}

subtest 'lists, and errors the server answers with, are rendered as before' => sub {
  for my $path ('/slow', '/all') {
    my $client = client($path);
    my ($list, $type) = answer(sub { $client->list_tools });
    is scalar @{$list->{tools} // []}, 2, "$path tools/list: both tools" or diag explain $list;
    like $type, qr{^application/json}, "$path tools/list: rendered";

    my ($missing, $missing_type) = answer(sub { $client->call_tool('nope') });
    like $missing->{err}, qr/Tool 'nope' not found/, "$path an unknown tool: the server's error";
    like $missing_type, qr{^application/json}, "$path an unknown tool: rendered";
  }
};

done_testing;
