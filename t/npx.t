use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File    qw(tempdir);
use Mojo::Promise;
use MCP::Hub;
use MCP::Client;

# Integration test against a *real* classic npx MCP server -- the official
# @modelcontextprotocol/server-everything reference server -- to prove the hub
# talks to the node servers in the wild, not just the Perl echo server. It only
# runs when npx and a recent enough node are on PATH; otherwise it skips, so it
# never fails a build on a machine without node or without network.

plan skip_all => 'set MCP_HUB_TEST_NPX=1 to run the live npx integration test'
  unless $ENV{MCP_HUB_TEST_NPX} || $ENV{AUTHOR_TESTING} || $ENV{RELEASE_TESTING};

my $npx = _which('npx');
plan skip_all => 'npx not found on PATH' unless $npx;

my $node_major = _node_major();
plan skip_all => 'node not found on PATH' unless defined $node_major;
plan skip_all => "node $node_major is too old (need >= 18)" if $node_major < 18;

diag "using npx=$npx, node major=$node_major (first run may download the server)";

my $SERVER = '@modelcontextprotocol/server-everything';

my $app = MCP::Hub->new(hub_config_input => {
  mcpServers => {everything => {command => 'npx', args => ['-y', $SERVER]}},
  hub        => {cache_dir => tempdir->to_string, request_timeout => 120},
});
my ($up) = @{$app->upstreams};

# Bring it up once; if it cannot start (offline, registry down), skip rather
# than fail -- the point of this test is the wiring, not the network.
my $start = _await($up->start_p);
plan skip_all => "could not start $SERVER (offline?): $start->{err}"
  if ref $start eq 'HASH' && $start->{err};

my $t    = Test::Mojo->new($app);
my $base = $t->ua->server->url->to_string =~ s{/$}{}r;

subtest 'discovery through the hub' => sub {
  my $client = MCP::Client->new(ua => $t->ua, url => "$base/everything");
  my $tools  = $client->list_tools;
  my %names  = map { $_->{name} => 1 } @{$tools->{tools}};
  ok scalar(keys %names) >= 1, 'the real server reports tools';
  ok $names{echo}, 'the stable "echo" tool is present' or diag "tools: @{[join ', ', sort keys %names]}";
};

subtest 'a real tool call round-trips' => sub {
  my $client = MCP::Client->new(ua => $t->ua, url => "$base/everything");
  my $result = $client->call_tool('echo', {message => 'hello from the hub'});
  ok !${$result->{isError} // \0}, 'not an error';
  like $result->{content}[0]{text}, qr/hello from the hub/, 'echo returned our message';
};

subtest 'the real server appears in the aggregate' => sub {
  my $client = MCP::Client->new(ua => $t->ua, url => "$base/all");
  my $tools  = $client->list_tools;
  ok +(grep { $_->{name} eq 'everything__echo' } @{$tools->{tools}}),
    'echo is prefixed as everything__echo in /all';
};

$up->stop;
Mojo::Promise->timer(0.5)->wait;

done_testing;

# --- helpers ---------------------------------------------------------------

sub _which ($program) {
  for my $dir (split /:/, $ENV{PATH} // '') {
    my $path = "$dir/$program";
    return $path if -x $path && !-d $path;
  }
  return undef;
}

sub _node_major {
  my $node = _which('node') or return undef;
  my $version = `"$node" --version 2>/dev/null`;
  return $version =~ /^v(\d+)\./ ? $1 : undef;
}

sub _await ($promise) {
  my $out;
  $promise->then(sub { $out = shift })->catch(sub { $out = {err => shift} })->wait;
  return $out;
}
