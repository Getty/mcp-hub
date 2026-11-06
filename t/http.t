#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojolicious;
use Mojo::File   qw(tempdir);
use Mojo::IOLoop;
use Mojo::JSON qw(encode_json);
use Mojo::Log;
use Mojo::Promise;
use Mojo::Server::Daemon;
use IO::Socket::INET;
use Scalar::Util qw(weaken);
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

# A request that is never settled must fail the test instead of hanging it: the
# promise is raced against a timeout.
sub _await_bounded ($promise, $seconds = 5) {
  my $out;
  Mojo::Promise->race(Mojo::Promise->timeout($seconds), $promise)
    ->then(sub { $out = shift })->catch(sub { $out = {err => shift} })->wait;
  return $out;
}

# The text of an error result -- or '' when the call did not answer at all.
sub _error_text ($result) {
  return '' unless ref $result eq 'HASH';
  return '' unless ref $result->{content} eq 'ARRAY';
  return '' unless ref $result->{content}[0] eq 'HASH';
  return $result->{content}[0]{text} // '';
}

# A fake HTTP+SSE MCP server: the GET stream announces an endpoint, every
# JSON-RPC response comes back as a "message" event on that stream -- the way
# the servers the hub's SSE transport talks to behave. It records every POST it
# receives, so a test can prove that a request did not reach it. With
# endpoint_delay set it holds the endpoint event back that many seconds, as a
# slow remote does.
sub fake_sse (%opt) {
  my $app = Mojolicious->new;
  $app->log->level('warn');
  my $state = {tx => undef, posts => [], endpoint => $opt{endpoint} // '/messages'};

  $app->routes->get('/sse' => sub ($c) {
    $c->render_later;
    $c->res->headers->content_type('text/event-stream');
    $state->{tx} = $c->tx;
    my $announce = sub {
      return unless $c->tx;    # the client hung up while the event was held back
      $c->write_sse({type => 'endpoint', text => $state->{endpoint}});
      $c->tx->resume;
    };
    my $delay = $state->{endpoint_delay};
    $delay ? Mojo::IOLoop->timer($delay => $announce) : $announce->();
  });

  $app->routes->post('/messages' => sub ($c) {
    my $req = eval { $c->req->json } // {};
    push @{$state->{posts}}, $req;
    my $res = $opt{answer} ? $opt{answer}->($req) : undef;
    if ($res && defined $res->{id}) {
      my $content = $state->{tx}->res->content;
      $content->write_sse({type => 'message', text => encode_json($res)});
      $state->{tx}->resume;
    }
    $c->render(text => 'ok', status => 202);
  });

  my $daemon = Mojo::Server::Daemon->new(app => $app, listen => ['http://127.0.0.1'], silent => 1);
  $daemon->start;
  $state->{port}   = $daemon->ports->[0];
  $state->{url}    = "http://127.0.0.1:$state->{port}/sse";
  $state->{daemon} = $daemon;
  return $state;
}

# The MCP conversation of the fake server: a proper handshake, and a tools/call
# that answers with the given error.
sub mcp_answer ($error) {
  return sub ($req) {
    my $id = $req->{id};
    return undef unless defined $id;    # a notification gets no answer
    my $method = $req->{method} // '';
    if ($method eq 'initialize') {
      return {jsonrpc => '2.0', id => $id, result => {
        protocolVersion => '2025-06-18',
        capabilities    => {},
        serverInfo      => {name => 'fake-sse', version => '0.0.1'},
      }};
    }
    if ($method eq 'tools/list') {
      return {jsonrpc => '2.0', id => $id, result => {tools => [
        {name => 'boom', description => 'Answers with an error', inputSchema => {type => 'object'}},
      ]}};
    }
    return {jsonrpc => '2.0', id => $id, error => $error};
  };
}

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

subtest 'sse upstream: a non-object error is reported, not swallowed' => sub {
  # "error": "text" and "error": [..] -- shapes that are out there in the wild.
  # Reading ->{message} from them dies under strict refs, and the request it
  # belongs to then stays pending forever.
  for my $shape (qw(string array)) {
    my $error = $shape eq 'string' ? 'nope' : ['nope', 'still nope'];
    my $fake  = fake_sse(answer => mcp_answer($error));
    my $up    = MCP::Hub::Upstream::Http->new(
      name      => 'fake',
      config    => {type => 'sse', url => $fake->{url}, request_timeout => 5},
      cache_dir => tempdir->to_string,
    );

    my $r = _await_bounded($up->call_tool('boom', {}), 10);
    ok $r->{isError}, "$shape error is an error result" or diag explain $r;
    like _error_text($r), qr/^upstream fake:/, "$shape error names the upstream";
    like _error_text($r), qr/nope/, "$shape error carries the upstream message";

    $up->stop;
    $fake->{daemon}->stop;
  }
};

subtest 'sse upstream: an endpoint on another origin is refused' => sub {
  # The endpoint event may not move the JSON-RPC traffic -- and with it the
  # configured Authorization header -- to a foreign host.
  my $foreign = fake_sse();
  my $fake    = fake_sse(endpoint => "http://127.0.0.1:$foreign->{port}/messages");

  my $up = MCP::Hub::Upstream::Http->new(
    name      => 'fake',
    config    => {
      type            => 'sse',
      url             => $fake->{url},
      request_timeout => 5,
      headers         => {Authorization => 'Bearer secret'},
    },
    cache_dir => tempdir->to_string,
  );

  my $r = _await_bounded($up->start_p, 10);
  ok $r->{err}, 'the connect fails' or diag explain $r;
  like $r->{err}, qr/origin/, 'the reason names the origin mismatch';
  is scalar @{$foreign->{posts}}, 0, 'the foreign origin received no POST';
  is $up->state, 'stopped', 'one connect failure is not fatal yet';

  # Three connect failures within five seconds mark the upstream failed, and
  # the reason shows up in the status row.
  _await_bounded($up->start_p, 10) for 2 .. 3;
  is $up->state, 'failed', 'failed after the third connect failure';
  like $up->status_row->{error}, qr/connect failure/, 'the failure count is reported';
  like $up->status_row->{error}, qr/origin/, 'and so is the reason';

  $fake->{daemon}->stop;
  $foreign->{daemon}->stop;
};

subtest 'sse upstream: a stream the remote drops is never taken for a stop' => sub {
  # Closing the stream on purpose -- a stop, or the cleanup of a start that
  # failed -- marks that close as deliberate. The mark used to stay on the
  # object, so after either of them and a good start, a stream the remote really
  # dropped left the upstream `ready` over a dead stream: every call posted to
  # the old endpoint and timed out, and a refresh of a `ready` upstream only
  # listed again over that stream, so nothing ever reconnected.
  for my $before ('a failed start', 'a stop') {
    my $fake;
    my $handshake = mcp_answer('unused');
    $fake = fake_sse(answer => sub ($req) {
      return $handshake->($req) unless ($req->{method} // '') eq 'tools/call';
      # The remote goes away while it handles this call: its end of the
      # stream is closed and the call never answered.
      if ($req->{params}{name} eq 'drop') {
        Mojo::IOLoop->stream($fake->{tx}->connection)->close;
        return undef;
      }
      return {jsonrpc => '2.0', id => $req->{id}, result => {content => [{type => 'text', text => 'pong'}]}};
    });

    my $up = MCP::Hub::Upstream::Http->new(
      name      => 'fake',
      config    => {type => 'sse', url => $fake->{url}, request_timeout => 3},
      cache_dir => tempdir->to_string,
    );
    $up->log->level('fatal');

    if ($before eq 'a stop') {
      my $s = _await_bounded($up->start_p, 10);
      ok !$s->{err}, "$before: the first start succeeds" or diag $s->{err};
      $up->stop;
    }
    else {
      # An endpoint on another origin fails the start after the stream is
      # open, so the failed start closes it itself; it is never contacted.
      $fake->{endpoint} = 'http://127.0.0.1:1/messages';
      my $s = _await_bounded($up->start_p, 10);
      like $s->{err}, qr/origin/, "$before: the first start fails";
      $fake->{endpoint} = '/messages';
    }
    is $up->state, 'stopped', "$before: stopped";

    my $s = _await_bounded($up->start_p, 10);
    ok !$s->{err}, "$before: then a start succeeds" or diag $s->{err};
    is $up->state, 'ready', "$before: ready";

    my $dropped = _await_bounded($up->call_tool('drop', {}), 10);
    like _error_text($dropped), qr/SSE stream closed/, "$before: the call in flight fails with the stream";
    is $up->state, 'stopped', "$before: a dropped stream leaves the upstream stopped, not ready";

    my $again = _await_bounded($up->call_tool('ping', {}), 10);
    is _error_text($again), 'pong', "$before: the next call connects again and is answered" or diag explain $again;
    is $up->state, 'ready', "$before: ready again";

    $up->stop;
    $fake->{daemon}->stop;
  }
};

subtest 'sse upstream: the endpoint wait of one connect never rejects a later one' => sub {
  # Every connect waits request_timeout seconds for the endpoint event. That
  # timer stayed behind when its connect was over, and when it fired it
  # rejected whichever connect was current then: a later one, still well inside
  # its own wait, failed with "timed out waiting for the SSE endpoint".
  my $fake = fake_sse(answer => mcp_answer('unused'));
  my $up   = MCP::Hub::Upstream::Http->new(
    name      => 'fake',
    config    => {type => 'sse', url => $fake->{url}, request_timeout => 2},
    cache_dir => tempdir->to_string,
  );
  $up->log->level('fatal');

  # The first connect is over at once: its endpoint is on another origin.
  $fake->{endpoint} = 'http://127.0.0.1:1/messages';
  my $first = _await_bounded($up->start_p, 10);
  like $first->{err}, qr/origin/, 'the first connect fails at once';

  # The second starts a second later and gets its endpoint 1.5 s after that:
  # past the end of the first connect's wait (2 s), inside its own (3 s).
  @$fake{qw(endpoint endpoint_delay)} = ('/messages', 1.5);
  Mojo::Promise->timer(1)->wait;
  my $second = _await_bounded($up->start_p, 10);
  ok !$second->{err}, 'the second connect waits for its endpoint and starts' or diag $second->{err};
  is $up->state, 'ready', 'ready';

  $up->stop;
  $fake->{daemon}->stop;
};

subtest 'sse upstream: a connect that is over leaves no timer holding the upstream' => sub {
  # The endpoint timer held the upstream until it fired -- request_timeout
  # after the connect, a minute by default -- though the connect it waited for
  # was long over. An upstream a reload replaced lived on that long.
  my $fake = fake_sse(endpoint => 'http://127.0.0.1:1/messages');
  my $up   = MCP::Hub::Upstream::Http->new(
    name      => 'fake',
    config    => {type => 'sse', url => $fake->{url}, request_timeout => 30},
    cache_dir => tempdir->to_string,
  );
  $up->log->level('fatal');
  like _await_bounded($up->start_p, 10)->{err}, qr/origin/, 'the connect fails at once';

  weaken(my $gone = $up);
  undef $up;
  is $gone, undef, 'the upstream goes with its last reference';

  $fake->{daemon}->stop;
};

subtest 'sse upstream: a stop while it starts calls the start off, it does not fail it' => sub {
  # A stop calls a start off before it is through. It left the start to
  # whatever came next: the endpoint timer, request_timeout later, or the close
  # of the stream the stop had just closed itself. Both rejected the start as a
  # failed connect -- logged as one, "timed out waiting for the SSE endpoint"
  # among them, and counted, so three stops in a row marked the upstream
  # `failed`. The stop settles the start itself, at once, as stopped.
  for my $phase ('before it is connected', 'before the endpoint', 'during the handshake') {
    my $hold      = 1;    # the remote does not answer the initialize
    my $handshake = mcp_answer('unused');
    my $fake      = fake_sse(answer => sub ($req) {
      my $method = $req->{method} // '';
      return undef if $hold && $method eq 'initialize';
      # No tools: the code of a façade tool holds its upstream, which would
      # outlive the weak reference below whatever the stops left behind.
      return {jsonrpc => '2.0', id => $req->{id}, result => {tools => []}} if $method eq 'tools/list';
      return $handshake->($req);
    });
    $fake->{endpoint_delay} = 30 if $phase eq 'before the endpoint';

    my $up = MCP::Hub::Upstream::Http->new(
      name      => 'fake',
      config    => {type => 'sse', url => $fake->{url}, request_timeout => 5},
      cache_dir => tempdir->to_string,
    );
    my @logged;
    my $log = Mojo::Log->new;
    $log->unsubscribe('message')->on(message => sub ($l, $level, @lines) { push @logged, "$level: @lines" });
    $up->log($log);

    my $until = sub ($cond) {
      my $deadline = time + 5;
      Mojo::Promise->timer(0.01)->wait until $cond->() || time > $deadline;
      return $cond->();
    };

    # Three in a row: within the five seconds in which three connect failures
    # mark the upstream failed.
    for my $n (1 .. 3) {
      $fake->{tx} = undef;
      @{$fake->{posts}} = ();
      my $start = $up->start_p;
      ok $until->(sub { $fake->{tx} }), "$phase, start $n: the stream is open"
        if $phase eq 'before the endpoint';
      ok $until->(sub { grep { ($_->{method} // '') eq 'initialize' } @{$fake->{posts}} }),
        "$phase, start $n: the initialize is on its way"
        if $phase eq 'during the handshake';
      $up->stop;

      # Well inside request_timeout, which the endpoint timer waits.
      my $r = _await_bounded($start, 2);
      is $r->{err}, 'upstream fake: stopped', "$phase, start $n: rejected at once, as stopped"
        or diag explain $r;
    }
    is $up->state, 'stopped', "$phase: stopped, not failed";
    is $up->error, undef, "$phase: no failure reason";
    is_deeply [grep { !/^(?:trace|debug|info):/ } @logged], [], "$phase: nothing logged as a failure"
      or diag explain \@logged;
    ok !(grep {/timed out waiting for the SSE endpoint/} @logged), "$phase: no endpoint timeout";

    # Nor did they lock it out: the next start connects.
    ($hold, $fake->{endpoint_delay}) = (0, 0);
    # (Resolved to a string: the upstream it resolves with would be held here.)
    my $again = _await_bounded($up->start_p->then(sub { 'started' }), 5);
    is $again, 'started', "$phase: the next start connects" or diag explain $again;
    is $up->state, 'ready', "$phase: ready";
    $up->stop;

    # And they left nothing behind: the endpoint timer of each start went with
    # it, instead of holding the upstream for request_timeout.
    weaken(my $gone = $up);
    undef $up;
    is $gone, undef, "$phase: no timer holds the upstream";

    $fake->{daemon}->stop;
  }
};

subtest 'an https url without TLS is a failed upstream that names the fix' => sub {
  # A perl without IO::Socket::SSL 2.009+ (or with MOJO_NO_TLS) cannot speak
  # https. Before the fix the warming fetch failed once, the upstream went back
  # to `stopped`, and its endpoint answered 503 "not ready yet" for good -- the
  # still-fetching meaning, for an upstream that could never fetch anything.
  # Nothing is contacted here: an upstream that cannot be built never connects.
  no warnings 'redefine';
  local *Mojo::IOLoop::TLS::can_tls = sub { 0 };

  my $https = 'https://127.0.0.1:9/mcp';
  my $built = eval {
    MCP::Hub::Upstream::Http->new(name => 'remote', config => {type => 'http', url => $https},
      cache_dir => tempdir->to_string);
  };
  is $built, undef, 'the upstream is not built';
  like $@, qr/^an https url needs TLS\b.*IO::Socket::SSL 2\.009.*cpanm IO::Socket::SSL.*restart the daemon\n\z/,
    'the reason says what is missing and how to fix it';

  ok eval {
    MCP::Hub::Upstream::Http->new(name => 'plain', config => {type => 'http', url => $url},
      cache_dir => tempdir->to_string);
  }, 'an http url needs no TLS and is built as before' or diag $@;

  my $hub = MCP::Hub->new(hub_config_input => {
    mcpServers => {remote => {url => $https}, sse => {type => 'sse', url => $https}},
    hub        => {cache_dir => tempdir->to_string},
  });
  $hub->log->level('fatal');
  $hub->start_background_fetches;

  for my $name (qw(remote sse)) {
    my $up = $hub->upstreams_by_name->{$name};
    is $up->state, 'failed', "$name: failed, not stopped";
    my $row = $up->status_row;
    is $row->{type}, $name eq 'sse' ? 'sse' : 'http', "$name: the status row keeps its type";
    like $row->{error}, qr/IO::Socket::SSL 2\.009/, "$name: the status row names the missing module";
  }

  my $t = Test::Mojo->new($hub);
  for my $n (1 .. 2) {
    $t->post_ok('/remote' => json => {jsonrpc => '2.0', id => $n, method => 'tools/list', params => {}})
      ->status_is(503, "request $n: 503")
      ->json_like('/error', qr/^upstream 'remote' failed: an https url needs TLS\b.*restart the daemon$/,
        "request $n: the failed meaning, with the reason")
      ->json_unlike('/error', qr/not ready yet/, "request $n: not the still-fetching meaning");
  }

  my $refreshed = _await($hub->refresh_p('remote'));
  is $refreshed->{remote}{state}, 'failed', 'a refresh cannot cure it: still failed';
  like $refreshed->{remote}{error}, qr/IO::Socket::SSL/, 'and the refresh result says why';

  # The check keys on TLS, not on the scheme alone: with TLS present the same
  # https entry is an ordinary upstream that waits for its first call.
  no warnings 'redefine';
  local *Mojo::IOLoop::TLS::can_tls = sub { 1 };
  my $up = MCP::Hub::Upstream::Http->new(name => 'remote', config => {type => 'http', url => $https},
    cache_dir => tempdir->to_string);
  is $up->state, 'stopped', 'with TLS an https url is built and nothing is connected yet';
  ok !$up->placeholder, 'and it is no placeholder';
};

subtest 'a warming fetch that cannot connect is failed, with the reason, until a refresh' => sub {
  # One failed warming fetch used to leave the upstream `stopped` with no
  # error, its endpoint answering 503 "not ready yet" -- still fetching -- for
  # good, though nothing was fetching any more.
  my $probe = IO::Socket::INET->new(Listen => 5, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1)
    or plan skip_all => "cannot bind a probe socket: $!";
  my $dead_port = $probe->sockport;
  close $probe;

  my $cache = tempdir;
  my $hub   = MCP::Hub->new(hub_config_input => {
    mcpServers => {
      remote => {url => "http://127.0.0.1:$dead_port/mcp"},
      sse    => {type => 'sse', url => "http://127.0.0.1:$dead_port/sse"},
    },
    hub => {cache_dir => "$cache"},
  });
  $hub->log->level('fatal');
  my %up = %{$hub->upstreams_by_name};

  $hub->start_background_fetches;
  my $deadline = time + 10;
  Mojo::Promise->timer(0.05)->wait until !(grep { $_->state ne 'failed' } values %up) || time > $deadline;
  is $up{$_}->state, 'failed', "$_: failed, not stopped" for qw(remote sse);
  like $up{remote}->error, qr/^Connection refused/, 'http: with the reason';
  like $up{sse}->error, qr/^connect failed: Connection refused/, 'sse: with the reason';

  my $t = Test::Mojo->new($hub);
  for my $name (qw(remote sse)) {
    $t->post_ok("/$name" => json => {jsonrpc => '2.0', id => 1, method => 'tools/list', params => {}})
      ->status_is(503, "$name: 503")
      ->json_like('/error', qr/^upstream '$name' failed: \Q@{[$up{$name}->error]}\E$/, "$name: the failed meaning")
      ->json_unlike('/error', qr/not ready yet/, "$name: not the still-fetching one");
  }

  my $again = _await($hub->refresh_p('sse'));
  is $again->{sse}{state}, 'failed', 'a refresh that cannot connect either leaves it failed';
  like $again->{sse}{error}, qr/Connection refused/, 'and says why';

  # A server on that port: a refresh clears the failure and lists the tools.
  my $mojo2 = Mojolicious->new;
  $mojo2->log->level('warn');
  $mojo2->routes->post('/mcp' => $mcp->to_action({streaming => 1}));
  my $daemon2 = Mojo::Server::Daemon->new(app => $mojo2, listen => ["http://127.0.0.1:$dead_port"], silent => 1);
  $daemon2->start;

  my $back = _await($hub->refresh_p('remote'));
  is $back->{remote}{state}, 'ready', 'a refresh brings it back' or diag explain $back;
  is $back->{remote}{count}, 2, 'with its tools';
  is $up{remote}->error, undef, 'and no reason any more';
  $t->post_ok('/remote' => json => {jsonrpc => '2.0', id => 1, method => 'tools/list', params => {}})->status_is(200);

  $daemon2->stop;
};

done_testing;
