#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File qw(path tempdir);
use Mojo::Promise;
use MCP::Hub;
use MCP::Client;

# Integration test against a *real* Docker daemon and a real MCP server image --
# mcp/time from Docker Hub's mcp/ namespace, a stdio server -- to prove the hub
# drives the docker CLI in the wild, not just t/upstream/fake-docker.pl. Like
# t/npx.t it needs an explicit opt-in or a genuine release run, and it skips
# when there is no docker CLI, no daemon, or no way to get the image.
#
# It only ever touches the one container it starts, mcp-hub-k21-live-time,
# through the hub, which removes it again.

plan skip_all => 'set MCP_HUB_TEST_DOCKER=1 (or run under RELEASE_TESTING) to run the live Docker integration test'
  unless $ENV{MCP_HUB_TEST_DOCKER} || $ENV{RELEASE_TESTING};

my $docker = _which('docker');
plan skip_all => 'docker not found on PATH' unless $docker;
plan skip_all => 'the Docker daemon cannot be reached' unless system("$docker info >/dev/null 2>&1") == 0;

my $IMAGE = $ENV{MCP_HUB_TEST_DOCKER_IMAGE} // 'mcp/time';
my $NAME  = 'k21-live-time';

diag "using $docker with $IMAGE (the first run may pull it)";

my $app = MCP::Hub->new(hub_config_input => {
  mcpServers => {$NAME => {docker => $IMAGE}},
  hub        => {cache_dir => tempdir->to_string, request_timeout => 120},
});
my ($up) = @{$app->upstreams};

my $start = _await($up->start_p);
plan skip_all => "could not start $IMAGE (offline?): $start->{err}" if ref $start eq 'HASH' && $start->{err};

my $t    = Test::Mojo->new($app);
my $base = $t->ua->server->url->to_string =~ s{/$}{}r;

subtest 'a real container behind the hub' => sub {
  is $up->mode, 'stdio', 'an image without EXPOSE is spoken to over stdio';
  is _containers(), 1, 'its container runs';

  my $client = MCP::Client->new(ua => $t->ua, url => "$base/$NAME");
  my %names  = map { $_->{name} => 1 } @{$client->list_tools->{tools}};
  ok $names{get_current_time}, 'the real server reports its tools' or diag "tools: @{[sort keys %names]}";

  my $result = $client->call_tool('get_current_time', {timezone => 'UTC'});
  my $text   = $result->{content}[0]{text} // '';
  like $text, qr/UTC/, 'a real tool call round-trips' or diag $text;
};

subtest 'stopped and removed' => sub {
  $up->stop;
  _await($up->stopped_p);
  my $deadline = time + 30;
  Mojo::Promise->timer(0.5)->wait while _containers() && time < $deadline;
  is _containers(), 0, 'no container of it is left';
  is $up->state, 'stopped', 'and the upstream is stopped';
};

_await($app->shutdown_p);
done_testing;

# How many containers of this test's server exist, running or not: by name,
# read-only.
sub _containers {
  my @ids = grep {/\S/} split /\n/, qx{$docker ps -a -q --filter name=^mcp-hub-$NAME\$ 2>/dev/null};
  return scalar @ids;
}

sub _await ($p) {
  my $o;
  $p->then(sub { $o = shift }, sub { $o = {err => shift} })->wait;
  return $o;
}

sub _which ($cmd) {
  for my $dir (split /:/, $ENV{PATH} // '') {
    my $file = path($dir, $cmd);
    return "$file" if -x $file && !-d $file;
  }
  return undef;
}
