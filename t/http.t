use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojolicious;
use Mojo::File   qw(tempdir);
use Mojo::IOLoop;
use Mojo::Promise;
use Mojo::Server::Daemon;
use IO::Socket::INET;
use MCP::Server;
use MCP::Hub;
use MCP::Hub::Upstream::Http;
use MCP::Client;

# A real (in-process) Streamable HTTP MCP server on an ephemeral port. No npx,
# no network -- just the MCP server we depend on, served over real HTTP, so the
# http upstream client is exercised end to end.
my $mcp = MCP::Server->new(name => 'local-http', version => '3.2.1');
$mcp->instructions('A local streamable-http test server.');
$mcp->tool(
  name         => 'echo',
  description  => 'Echo the message',
  input_schema => {type => 'object', properties => {msg => {type => 'string'}}, required => ['msg']},
  code         => sub ($tool, $args) { $tool->text_result("echo: $args->{msg}") },
);
$mcp->tool(
  name         => 'slow',
  description  => 'Async result (exercises the SSE response path)',
  input_schema => {type => 'object'},
  code         => sub ($tool, $args) {
    my $p = Mojo::Promise->new;
    Mojo::IOLoop->timer(0.05 => sub { $p->resolve($tool->text_result('done')) });
    return $p;
  },
);

my $mojo = Mojolicious->new;
$mojo->log->level('warn');
$mojo->routes->post('/mcp' => $mcp->to_action({streaming => 1}));

my $daemon = Mojo::Server::Daemon->new(app => $mojo, listen => ['http://127.0.0.1'], silent => 1);
$daemon->start;
my $port = $daemon->ports->[0];
my $url  = "http://127.0.0.1:$port/mcp";

sub _await ($p) { my $o; $p->then(sub { $o = shift })->catch(sub { $o = {err => shift} })->wait; $o }

subtest 'streamable http upstream: handshake and calls' => sub {
  my $up = MCP::Hub::Upstream::Http->new(
    name      => 'remote',
    config    => {type => 'http', url => $url},
    cache_dir => tempdir->to_string,
  );
  is $up->transport, 'http', 'streamable http transport';

  my $start = _await($up->start_p);
  ok !(ref $start eq 'HASH' && $start->{err}), 'started' or diag $start->{err};
  is $up->state, 'ready', 'ready after handshake';

  my @tools = sort map { $_->name } @{$up->server->tools};
  is_deeply \@tools, [qw(echo slow)], 'tools discovered over http';

  my $echo = _await($up->call_tool('echo', {msg => 'hi'}));
  is $echo->{content}[0]{text}, 'echo: hi', 'sync tool call (JSON response) forwarded';

  my $slow = _await($up->call_tool('slow', {}));
  is $slow->{content}[0]{text}, 'done', 'async tool call (SSE response) forwarded';
};

subtest 'through the full hub' => sub {
  my $hub = MCP::Hub->new(hub_config_input => {
    mcpServers => {remote => {url => $url}},
    hub        => {cache_dir => tempdir->to_string},
  });
  $hub->start_background_fetches;
  # wait for the manifest
  my $deadline = time + 10;
  until (time > $deadline) {
    Mojo::Promise->timer(0.05)->wait;
    last if ($hub->upstreams->[0]->manifest_fetched_at);
  }

  my $t    = Test::Mojo->new($hub);
  my $base = $t->ua->server->url->to_string =~ s{/$}{}r;
  my $client = MCP::Client->new(ua => $t->ua, url => "$base/remote");

  my $tools = $client->list_tools;
  ok +(grep { $_->{name} eq 'echo' } @{$tools->{tools}}), 'http upstream listed through the hub';

  my $res = $client->call_tool('echo', {msg => 'via hub'});
  is $res->{content}[0]{text}, 'echo: via hub', 'http tool call works through the hub';
};

subtest 'connect failures mark it failed after N, refresh clears it' => sub {
  # A port with nothing listening: connect is refused, fast and deterministic --
  # no npx, no network. Probe for a free port, then close it so it refuses.
  my $probe = IO::Socket::INET->new(Listen => 5, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1)
    or plan skip_all => "cannot bind a probe socket: $!";
  my $dead_port = $probe->sockport;
  close $probe;
  my $dead_url = "http://127.0.0.1:$dead_port/mcp";

  my $up = MCP::Hub::Upstream::Http->new(
    name      => 'deadremote',
    config    => {type => 'http', url => $dead_url, request_timeout => 5},
    cache_dir => tempdir->to_string,
  );
  is $up->state, 'stopped', 'starts out stopped -- nothing connected at build time';

  # Two connect failures are not yet fatal: the threshold is three, the same N
  # as the stdio child's three-exits-in-five-seconds crash loop.
  for my $n (1 .. 2) {
    my $r = _await($up->start_p);
    ok +(ref $r eq 'HASH' && $r->{err}), "connect attempt $n rejected (nothing is listening)";
    is $up->state, 'stopped', "still retrying after $n failure(s) -- not yet failed";
  }

  # The third consecutive connect failure trips `failed`. Before this fix the
  # http upstream went back to `stopped` on every failure and reconnected to the
  # dead remote forever; it never reached `failed`, so `status` never showed it.
  my $r3 = _await($up->start_p);
  ok +(ref $r3 eq 'HASH' && $r3->{err}), 'third connect attempt rejected';
  is $up->state, 'failed', 'failed after the third consecutive connect failure';
  like $up->error, qr/connect failure/, 'failure reason names the connect failures';

  # While failed, a call reports the failure instead of re-attempting the dead
  # connection: the rejection is the "run refresh" message the failed guard
  # produces, which a fresh connect attempt would not.
  my $call = _await($up->call_tool('echo', {msg => 'hi'}));
  ok $call->{isError}, 'a call against a failed upstream is an error result';
  like $call->{content}[0]{text}, qr/refresh/, 'the call short-circuits on failed, it does not reconnect';
  is $up->state, 'failed', 'still failed after the call -- no fresh connection attempt';

  # Bring a real MCP server up on that very port; refresh clears the failure
  # (as it does for a crash-looped stdio child) and a successful handshake makes
  # the upstream ready again.
  my $mojo2 = Mojolicious->new;
  $mojo2->log->level('warn');
  $mojo2->routes->post('/mcp' => $mcp->to_action({streaming => 1}));
  my $daemon2 = Mojo::Server::Daemon->new(app => $mojo2, listen => ["http://127.0.0.1:$dead_port"], silent => 1);
  $daemon2->start;

  my $ref = _await($up->refresh_p);
  ok !(ref $ref eq 'HASH' && $ref->{err}), 'refresh recovered the upstream' or diag $ref->{err};
  is $up->state, 'ready',  'ready again after refresh cleared the failure';
  is $up->error, undef,    'failure reason cleared by refresh';
  my @tools = sort map { $_->name } @{$up->server->tools};
  is_deeply \@tools, [qw(echo slow)], 'tools discovered after recovery';

  $daemon2->stop;
};

done_testing;
