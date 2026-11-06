#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(tempdir);
use Mojo::Log;
use MCP::Hub::Upstream::Docker;
use MCP::Hub::Upstream::Http;
use MCP::Hub::Upstream::Stdio;

# What a call to a failed upstream is told: why it failed, and how to try
# again. The three kinds that can fail -- a stdio child, a remote, a container
# -- say it the same way, and a reason that ends in a question mark (the hint
# for a command that cannot be executed) is not followed by a comma. Nothing
# here starts a process or connects anywhere: a failed upstream does neither.

my %entry = (
  docker => {class => 'MCP::Hub::Upstream::Docker', type => 'docker', image => 'mcp-hub-test/no-such-image'},
  http   => {class => 'MCP::Hub::Upstream::Http',   type => 'http',   url   => 'http://127.0.0.1:9/mcp'},
  stdio  => {class => 'MCP::Hub::Upstream::Stdio',  type => 'stdio',  command => 'mcp-hub-test-no-such-command'},
);

sub quiet () { my $log = Mojo::Log->new; $log->unsubscribe('message'); return $log }

sub rejection ($promise) {
  my $err;
  $promise->then(sub { $err = 'resolved' }, sub { $err = shift })->wait;
  return $err;
}

for my $type (sort keys %entry) {
  subtest $type => sub {
    my %config = %{$entry{$type}};
    my $class  = delete $config{class};
    my $up     = $class->new(name => 'x', config => {name => 'x', %config}, cache_dir => tempdir->to_string, log => quiet());

    $up->fail("upstream x: exited (code 127) while starting 'nope' -- is it installed and executable?");
    is rejection($up->start_p),
      "upstream x: exited (code 127) while starting 'nope' -- is it installed and executable?"
      . " Run 'mcp-hub refresh x' to try again",
      'a reason that ends in a question mark is followed by a sentence of its own';

    $up->fail('3 exits within 5s');
    is rejection($up->start_p), "upstream x: 3 exits within 5s, run 'mcp-hub refresh x' to try again",
      'any other reason by a comma';
  };
}

done_testing;
