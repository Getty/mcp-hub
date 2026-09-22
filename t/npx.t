use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File    qw(path tempdir);
use Mojo::Promise;
use POSIX         qw(WNOHANG);
use Time::HiRes   ();
use MCP::Hub;
use MCP::Client;

# Integration test against a *real* classic npx MCP server -- the official
# @modelcontextprotocol/server-everything reference server -- to prove the hub
# talks to the node servers in the wild, not just the Perl echo server. It only
# runs when npx and a recent enough node are on PATH; otherwise it skips, so it
# never fails a build on a machine without node or without network. A plain
# `dzil test` (AUTHOR_TESTING) must NOT hit npm/network on its own -- this needs
# an explicit opt-in or a genuine release run (RELEASE_TESTING, e.g.
# `dzil release` / `dzil test --release`).

plan skip_all => 'set MCP_HUB_TEST_NPX=1 (or run under RELEASE_TESTING) to run the live npx integration test'
  unless $ENV{MCP_HUB_TEST_NPX} || $ENV{RELEASE_TESTING};

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

subtest 'live HTTP+SSE upstream via npx server-everything sse' => sub {
  my ($pid, $sse_port) = _spawn_sse_server();
  plan skip_all => 'could not start server-everything in sse mode' unless $sse_port;

  # Drive the upstream directly (as the hub does internally): the raw-socket SSE
  # transport is what we are proving here.
  my $ok = eval {
    my $up = MCP::Hub::Upstream::Http->new(
      name      => 'remote',
      config    => {type => 'sse', url => "http://127.0.0.1:$sse_port/sse"},
      cache_dir => tempdir->to_string,
      request_timeout => 30,
    );
    is $up->transport, 'sse', 'sse transport';

    my $start = _await($up->start_p);
    die "start failed: $start->{err}\n" if ref $start eq 'HASH' && $start->{err};
    ok +(grep { $_->name eq 'echo' } @{$up->server->tools}), 'tools discovered over the SSE transport';

    my $res = _await($up->call_tool('echo', {message => 'over sse'}));
    ok !${$res->{isError} // \0}, 'not an error';
    like $res->{content}[0]{text}, qr/over sse/, 'sse tool call round-trips';

    $up->stop;
    1;
  };
  my $err = $@;
  kill 'TERM', $pid;
  waitpid $pid, 0;
  die $err unless $ok;
};

done_testing;

# --- helpers ---------------------------------------------------------------

sub _spawn_sse_server {
  my $port = _free_port() or return;
  # Keep the tempdir object alive for the whole sub: Mojo's tempdir removes the
  # directory when its object is dropped, and the child must be able to open the
  # log in it before we return.
  my $dir = tempdir;
  my $log = $dir->child('sse.log')->to_string;
  my $pid = fork // return;
  if (!$pid) {
    $ENV{PORT} = $port;    # server-everything sse honours PORT -- avoids a fixed-port clash
    open STDOUT, '>',  $log or POSIX::_exit(127);
    open STDERR, '>&', STDOUT;
    { exec 'npx', '-y', $SERVER, 'sse' }
    POSIX::_exit(127);
  }
  my $deadline = time + 30;
  while (time < $deadline) {
    Time::HiRes::sleep(0.2);
    last if waitpid($pid, WNOHANG) > 0;    # child died
    my $content = eval { path($log)->slurp } // '';
    return ($pid, $port) if $content =~ /running on port \Q$port\E/;
  }
  kill 'TERM', $pid;
  waitpid $pid, 0;
  return;
}

sub _free_port {
  require IO::Socket::INET;
  my $s = IO::Socket::INET->new(Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp') or return;
  my $port = $s->sockport;
  $s->close;
  return $port;
}

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
