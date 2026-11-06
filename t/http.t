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

# A fake Streamable HTTP MCP server: every JSON-RPC request is a POST and its
# answer the response. It records every POST it receives, with the session id
# it carries (`session`) and its MCP-Protocol-Version header (`version`), and
# gives every initialize a new session; every other answer names the session
# of its request, as the reference server's do. The
# answer callback returns the response, or a promise of it: one that never settles
# holds the request, as a remote that takes its time does. `answered` counts
# the answers, `cut` the POSTs whose connection went before they were answered.
# A DELETE ends a session: `deletes` records the session ids they carry, and
# each is answered with `delete_status` (200), or with no answer at all, its
# connection dropped, for `drop`.
#
# The sessions it knows are in `live`; a test forgets one by deleting it there,
# as a remote that restarted, or timed the session out, does -- `volatile`
# forgets each one as soon as it is given. A POST on a session it does not know
# is answered 404 and counted in `gone`, at once, or -- when it forgot the
# session while it held the request -- once the answer is ready. `stateless`
# gives no session ids, and an answer {http_status => N} is a bare status N.
sub fake_http (%opt) {
  my $app = Mojolicious->new;
  $app->log->level('warn');
  my $state = {posts => [], answered => 0, cut => 0, sessions => 0, deletes => [], live => {}, gone => 0};

  $app->routes->delete('/mcp' => sub ($c) {
    push @{$state->{deletes}}, $c->req->headers->header('Mcp-Session-Id');
    my $status = $state->{delete_status} // 200;
    return Mojo::IOLoop->stream($c->tx->connection)->close if $status eq 'drop';
    $c->rendered($status);
  });

  $app->routes->post('/mcp' => sub ($c) {
    my $req = eval { $c->req->json } // {};
    my $sid = $c->req->headers->header('Mcp-Session-Id');
    push @{$state->{posts}}, {%$req, session => $sid, version => $c->req->headers->header('MCP-Protocol-Version')};
    my $gone = sub { defined $sid && !$state->{live}{$sid} && ++$state->{gone} };
    return $c->rendered(404) if $gone->();
    return $c->rendered(202) unless defined $req->{id};    # a notification
    my $answered;
    $c->on(finish => sub { $state->{cut}++ unless $answered });
    $c->render_later;
    Mojo::Promise->resolve($opt{answer}->($req))->then(sub ($res) {
      return unless $c->tx;
      $answered = ++$state->{answered};
      return $c->rendered(404) if $gone->();
      return $c->rendered($res->{http_status}) if ref $res eq 'HASH' && $res->{http_status};
      my $session = ($req->{method} // '') ne 'initialize' ? $sid
        : $state->{stateless}                             ? undef
        :                                                   's' . ++$state->{sessions};
      $state->{live}{$session} = 1 if defined $session && !$state->{volatile};
      $c->res->headers->header('Mcp-Session-Id' => $session) if defined $session;
      $c->render(json => $res);
    });
  });

  my $daemon = Mojo::Server::Daemon->new(app => $app, listen => ['http://127.0.0.1'], silent => 1);
  $daemon->start;
  $state->{url}    = "http://127.0.0.1:@{[$daemon->ports->[0]]}/mcp";
  $state->{daemon} = $daemon;
  return $state;
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
  #
  # A stop between two requests of the handshake -- the initialize answered,
  # the tools/list not sent yet -- took the endpoint away, and the tools/list
  # went nowhere: it waited request_timeout for an answer that could not come,
  # with request_timeout 0 for good, and the start with it, which every later
  # start then waited on too. A request without an endpoint is rejected at once.
  #
  # A stop during a prompts/list failed it, and the handshake takes a failed
  # prompts/list (or resources/list) for an empty one: the upstream went
  # `ready` after the stop, over the stream the stop had closed.
  my @when = ('before it is connected', 'before the endpoint', 'during the handshake', 'between two requests',
    'during a prompts/list');
  for my $case (map { my $timeout = $_; map { [$_, $timeout] } @when } 5, 0) {
    my ($when, $timeout) = @$case;
    my $phase = $timeout ? $when : "$when, request_timeout 0";
    # The request the remote does not answer -- none between two requests.
    my $hold = {'between two requests' => '', 'during a prompts/list' => 'prompts/list'}->{$when} // 'initialize';
    my $handshake = mcp_answer('unused');
    my $fake      = fake_sse(answer => sub ($req) {
      my $method = $req->{method} // '';
      return undef if $method eq $hold;
      # Empty lists: what a start lists plays no part in its stop.
      return {jsonrpc => '2.0', id => $req->{id}, result => {tools => []}}   if $method eq 'tools/list';
      return {jsonrpc => '2.0', id => $req->{id}, result => {prompts => []}} if $method eq 'prompts/list';
      my $res = $handshake->($req);
      $res->{result}{capabilities} = {prompts => {}} if $method eq 'initialize';    # a prompts/list follows
      return $res;
    });
    $fake->{endpoint_delay} = 30 if $when eq 'before the endpoint';

    my $up = MCP::Hub::Upstream::Http->new(
      name      => 'fake',
      config    => {type => 'sse', url => $fake->{url}, request_timeout => $timeout},
      cache_dir => tempdir->to_string,
    );
    my @logged;
    my $log = Mojo::Log->new;
    $log->unsubscribe('message')->on(message => sub ($l, $level, @lines) { push @logged, "$level: @lines" });
    $up->log($log);

    # Every POST the hub sends, as it goes out. Between two requests the stop
    # lands as the notifications/initialized does: the initialize is answered,
    # the tools/list not sent yet.
    my ($stop_at, @sent) = ($when eq 'between two requests' ? 'notifications/initialized' : '');
    weaken(my $weak = $up);
    $up->req_ua->on(start => sub ($ua, $tx) {
      push @sent, my $method = eval { $tx->req->json->{method} } // '';
      $weak->stop if $stop_at && $method eq $stop_at;
    });

    my $until = sub ($cond) {
      my $deadline = time + 5;
      Mojo::Promise->timer(0.01)->wait until $cond->() || time > $deadline;
      return $cond->();
    };

    # Three in a row: within the five seconds in which three connect failures
    # mark the upstream failed.
    for my $n (1 .. 3) {
      $fake->{tx} = undef;
      @{$fake->{posts}} = @sent = ();
      my $start = $up->start_p;
      ok $until->(sub { $fake->{tx} }), "$phase, start $n: the stream is open"
        if $when eq 'before the endpoint';
      ok $until->(sub { grep { ($_->{method} // '') eq $hold } @{$fake->{posts}} }),
        "$phase, start $n: the $hold is on its way"
        if $when =~ /^during /;
      $up->stop unless $stop_at;

      # Well inside the request_timeout of 5 s, and the endpoint wait of 30 s
      # without one.
      my $r = _await_bounded($start, 2);
      is $r->{err}, 'upstream fake: stopped', "$phase, start $n: rejected at once, as stopped"
        or diag explain $r;
      is_deeply \@sent, ['initialize', 'notifications/initialized'],
        "$phase, start $n: the stop came after the initialize was answered, nothing went out after it"
        if $stop_at;
    }
    is $up->state, 'stopped', "$phase: stopped, not failed";
    is $up->error, undef, "$phase: no failure reason";
    is_deeply [grep { !/^(?:trace|debug|info):/ } @logged], [], "$phase: nothing logged as a failure"
      or diag explain \@logged;
    ok !(grep {/timed out waiting for the SSE endpoint/} @logged), "$phase: no endpoint timeout";

    # Nor did they lock it out: the next start connects.
    ($hold, $stop_at, $fake->{endpoint_delay}) = ('', '', 0);
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

subtest 'sse upstream: a request without the stream to answer on is rejected at once' => sub {
  # A remote that drops the stream between two requests of a handshake took the
  # way back for every answer, but left the endpoint: the next request was
  # posted to it and waited for an answer that could not come -- with
  # request_timeout 0 for good, and the start with it.
  my $handshake = mcp_answer('unused');
  my $fake      = fake_sse(answer => sub ($req) {
    return {jsonrpc => '2.0', id => $req->{id}, result => {tools => []}} if ($req->{method} // '') eq 'tools/list';
    return $handshake->($req);
  });
  my $up = MCP::Hub::Upstream::Http->new(
    name      => 'fake',
    config    => {type => 'sse', url => $fake->{url}, request_timeout => 0},
    cache_dir => tempdir->to_string,
  );
  $up->log->level('fatal');

  # The stream goes as the notifications/initialized goes out: the initialize
  # is answered, the tools/list not sent yet. (Closed on the hub's side, so it
  # is gone before the next request, as the hub sees a remote drop it.)
  my ($drop, @sent) = (1);
  weaken(my $weak = $up);
  $up->req_ua->on(start => sub ($ua, $tx) {
    push @sent, my $method = eval { $tx->req->json->{method} } // '';
    $weak->{sse}{stream}->close if $drop && $method eq 'notifications/initialized';
  });

  my $r = _await_bounded($up->start_p, 2);
  is $r->{err}, 'upstream fake: not connected', 'the start fails at once' or diag explain $r;
  is_deeply \@sent, ['initialize', 'notifications/initialized'],
    'the stream went after the initialize was answered, nothing went out after it';
  is $up->state, 'stopped', 'stopped';

  $drop = 0;
  my $again = _await_bounded($up->start_p->then(sub { 'started' }), 5);
  is $again, 'started', 'the next start connects' or diag explain $again;
  $up->stop;
  $fake->{daemon}->stop;
};

subtest 'streamable http upstream: a stop while it starts calls the start off, it does not fail it' => sub {
  # A stop did not reach a Streamable HTTP start: its requests were not in
  # {pending}, and nothing between them asked whether the start was still
  # wanted. The handshake went on, and the upstream went `ready` after the
  # stop -- or, with a request in flight that the remote took its time over,
  # stayed `starting` until request_timeout, and every start in between joined
  # the one the stop had called off. The stop calls the start off, at once, as
  # stopped: the request in flight is cut off, and the next is not sent.
  #
  # As the initialize goes out it is not connected yet, and there is nothing
  # to cut off: it goes out all the same, and its answer is turned away -- the
  # session id on it too, which the next start would have sent on.
  my @when = ('before the first request', 'as the initialize goes out', 'during the initialize', 'between two requests',
    'during a prompts/list');
  for my $when (@when) {
    # The request the remote does not answer, if any.
    my $hold = {'during the initialize' => 'initialize', 'during a prompts/list' => 'prompts/list'}->{$when} // '';
    my $fake = fake_http(answer => sub ($req) {
      my ($id, $method) = ($req->{id}, $req->{method} // '');
      return Mojo::Promise->new if $method eq $hold;    # never settles
      return {jsonrpc => '2.0', id => $id, result => {
        protocolVersion => '2025-06-18',
        capabilities    => {prompts => {}},             # a prompts/list follows the tools/list
        serverInfo      => {name => 'fake-http', version => '0.0.1'},
      }} if $method eq 'initialize';
      return {jsonrpc => '2.0', id => $id, result => {tools   => []}} if $method eq 'tools/list';
      return {jsonrpc => '2.0', id => $id, result => {prompts => []}} if $method eq 'prompts/list';
      return {jsonrpc => '2.0', id => $id, error => {code => -32601, message => "no $method"}};
    });

    my $up = MCP::Hub::Upstream::Http->new(
      name      => 'fake',
      config    => {type => 'http', url => $fake->{url}, request_timeout => 5},
      cache_dir => tempdir->to_string,
    );
    my @logged;
    my $log = Mojo::Log->new;
    $log->unsubscribe('message')->on(message => sub ($l, $level, @lines) { push @logged, "$level: @lines" });
    $up->log($log);

    my $until = sub ($cond, $within = 5) {
      my $deadline = time + $within;
      Mojo::Promise->timer(0.01)->wait until $cond->() || time > $deadline;
      return $cond->();
    };

    # Every POST the hub sends, as it goes out. A stop lands as one of them
    # does: as the initialize, before it is connected, or between two
    # requests, as the notifications/initialized -- the initialize is answered,
    # the tools/list not sent yet.
    my $stop_at = {'as the initialize goes out' => 'initialize', 'between two requests' => 'notifications/initialized'}
      ->{$when} // '';
    my (@sent, %tx);
    weaken(my $weak = $up);
    $up->req_ua->on(start => sub ($ua, $tx) {
      return unless $tx->req->method eq 'POST';    # the DELETE that ends a session: below
      push @sent, my $method = eval { $tx->req->json->{method} } // '';
      $tx{$method} = $tx;
      $weak->stop if $stop_at && $method eq $stop_at;
    });
    my %sent = (
      'before the first request'   => [],
      'as the initialize goes out' => ['initialize'],
      'during the initialize'      => ['initialize'],
      'between two requests'       => ['initialize', 'notifications/initialized'],
      'during a prompts/list'      => ['initialize', 'notifications/initialized', 'tools/list', 'prompts/list'],
    );

    # Three in a row: within the five seconds in which three connect failures
    # mark the upstream failed.
    for my $n (1 .. 3) {
      @{$fake->{posts}} = @{$fake->{deletes}} = @sent = ();
      my ($cut, $answered) = @$fake{qw(cut answered)};
      my $start = $up->start_p;
      ok $until->(sub { grep { ($_->{method} // '') eq $hold } @{$fake->{posts}} }),
        "$when, start $n: the $hold is on its way"
        if $hold;
      $up->stop unless $stop_at;

      # Well inside the request_timeout of 5 s.
      my $r = _await_bounded($start, 2);
      is $r->{err}, 'upstream fake: stopped', "$when, start $n: rejected at once, as stopped" or diag explain $r;
      is $up->state, 'stopped', "$when, start $n: stopped";
      is_deeply \@sent, $sent{$when}, "$when, start $n: no request of the start went out after the stop"
        or diag explain \@sent;
      # At once, too: well before request_timeout would cut it.
      ok $until->(sub { $fake->{cut} > $cut }, 1), "$when, start $n: the $hold is cut off, not left to run"
        if $hold;
      # A stop after the initialize was answered ends the session it opened.
      if ($when eq 'between two requests' || $when eq 'during a prompts/list') {
        ok $until->(sub { @{$fake->{deletes}} }), "$when, start $n: the stop ends the session";
        is_deeply $fake->{deletes}, ["s$fake->{sessions}"], "$when, start $n: with one DELETE carrying its id";
      }
      next unless $when eq 'as the initialize goes out';
      ok $until->(sub { $fake->{answered} > $answered }), "$when, start $n: the initialize is answered all the same";
      # The hub has read the answer, and what it does with it is done.
      ok $until->(sub { $tx{initialize}->is_finished }), "$when, start $n: the answer is read";
      Mojo::Promise->timer(0.01)->wait;
      is $up->state, 'stopped', "$when, start $n: and it changes nothing";
      is_deeply $fake->{deletes}, [], "$when, start $n: nor does it leave a session id to end";
    }
    is $up->error, undef, "$when: no failure reason";
    is_deeply [grep { !/^(?:trace|debug|info):/ } @logged], [], "$when: nothing logged as a failure"
      or diag explain \@logged;

    # Nor did they lock it out: the next start connects.
    ($hold, $stop_at) = ('', '');
    @{$fake->{posts}} = ();
    # (Resolved to a string: the upstream it resolves with would be held here.)
    my $again = _await_bounded($up->start_p->then(sub { 'started' }), 5);
    is $again, 'started', "$when: the next start connects" or diag explain $again;
    is $up->state, 'ready', "$when: ready";
    is $fake->{posts}[0]{session}, undef, "$when: with no session id of an answer that was turned away"
      if $when eq 'as the initialize goes out';
    $up->stop;

    # And they left nothing behind: no POST a stop called off holds the
    # upstream until request_timeout.
    weaken(my $gone = $up);
    undef $up;
    is $gone, undef, "$when: nothing holds the upstream";

    $fake->{daemon}->stop;
  }
};

subtest 'streamable http upstream: a stop leaves a call in flight to finish' => sub {
  # A stop calls off a start, not a call. Over Streamable HTTP a call does not
  # need anything the stop takes down -- its answer comes on its own POST --
  # and the remote may be carrying it out already: the call is left to finish,
  # and its answer is the caller's. Nor is the session ended under it -- a
  # remote tears down what runs in a session it ends: it goes once the call is
  # through. And the session its answer names, the one the stop ended, is not
  # the upstream's any more: a start in the meantime opened a new one.
  my $fake = fake_http(answer => sub ($req) {
    my ($id, $method) = ($req->{id}, $req->{method} // '');
    return Mojo::Promise->timer(0.3)->then(sub {
      {jsonrpc => '2.0', id => $id, result => {content => [{type => 'text', text => 'pong'}]}};
    }) if $method eq 'tools/call';
    return {jsonrpc => '2.0', id => $id, result => {
      protocolVersion => '2025-06-18',
      capabilities    => {},
      serverInfo      => {name => 'fake-http', version => '0.0.1'},
    }} if $method eq 'initialize';
    return {jsonrpc => '2.0', id => $id, result => {tools => []}};
  });
  my $up = MCP::Hub::Upstream::Http->new(
    name      => 'fake',
    config    => {type => 'http', url => $fake->{url}, request_timeout => 5},
    cache_dir => tempdir->to_string,
  );
  $up->log->level('fatal');
  is _await_bounded($up->start_p->then(sub { 'started' }), 5), 'started', 'started';

  my $call     = $up->call_tool('ping', {});
  my $deadline = time + 5;
  Mojo::Promise->timer(0.01)->wait
    until (grep { ($_->{method} // '') eq 'tools/call' } @{$fake->{posts}}) || time > $deadline;
  ok +(grep { ($_->{method} // '') eq 'tools/call' } @{$fake->{posts}}), 'the call is on its way';
  $up->stop;
  is $up->state, 'stopped', 'stopped';
  Mojo::Promise->timer(0.1)->wait;
  is_deeply $fake->{deletes}, [], 'its session is not ended under it';
  is _await_bounded($up->start_p->then(sub { 'started' }), 5), 'started', 'started again while it runs';

  is _error_text(_await_bounded($call, 5)), 'pong', 'the stop leaves it to finish: it is answered';
  is $fake->{cut}, 0, 'its POST was not cut off';
  $deadline = time + 5;
  Mojo::Promise->timer(0.01)->wait until @{$fake->{deletes}} || time > $deadline;
  is_deeply $fake->{deletes}, ['s1'], 'then its session is ended, with one DELETE carrying its id';

  splice @{$fake->{posts}};
  is _error_text(_await_bounded($up->call_tool('ping', {}), 5)), 'pong', 'the next call is answered';
  is_deeply [map { $_->{session} } @{$fake->{posts}}], ['s2'],
    'on the new session, not on the ended one the old answer named';
  $up->stop;
  $fake->{daemon}->stop;
};

subtest 'streamable http upstream: a start opens a new session, a stop ends the old one' => sub {
  # A start sent its initialize with the Mcp-Session-Id of the session before
  # it -- of a stopped upstream, or of a start that failed after its
  # initialize -- though a new session goes without one, and the remote
  # assigns it. Nor did a stop end the session it was done with: the remote
  # kept it until its own timeout. A stop ends it with a DELETE, sent and
  # forgotten, and the next start opens a new one.
  my $fail_list;
  my $fake = fake_http(answer => sub ($req) {
    my ($id, $method) = ($req->{id}, $req->{method} // '');
    return {jsonrpc => '2.0', id => $id, result => {
      protocolVersion => '2025-06-18',
      capabilities    => {},
      serverInfo      => {name => 'fake-http', version => '0.0.1'},
    }} if $method eq 'initialize';
    return {jsonrpc => '2.0', id => $id, error => {code => -32603, message => 'not now'}} if $fail_list;
    return {jsonrpc => '2.0', id => $id, result => {tools => []}};
  });
  my $up = MCP::Hub::Upstream::Http->new(
    name      => 'fake',
    config    => {type => 'http', url => $fake->{url}, request_timeout => 5},
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
  # (Resolved to a string: the upstream it resolves with would be held here.)
  my $start    = sub { _await_bounded($up->start_p->then(sub { 'started' }), 5) };
  # (Sorted: the notifications/initialized goes on a connection of its own, and
  # may arrive after the tools/list.)
  my $sessions = sub { [sort map { "$_->{method}: " . ($_->{session} // 'none') } splice @{$fake->{posts}}] };

  is $start->(), 'started', 'started';
  is_deeply $sessions->(), ['initialize: none', 'notifications/initialized: s1', 'tools/list: s1'],
    'the remote gives the first start session s1';

  $up->stop;
  ok $until->(sub { @{$fake->{deletes}} }), 'the stop ends the session';
  is_deeply $fake->{deletes}, ['s1'], 'with one DELETE carrying its id';
  $up->stop;
  Mojo::Promise->timer(0.05)->wait;
  is_deeply $fake->{deletes}, ['s1'], 'a second stop has no session left to end';

  is $start->(), 'started', 'the next start';
  is_deeply $sessions->(), ['initialize: none', 'notifications/initialized: s2', 'tools/list: s2'],
    'opens a new session: its initialize carries no id';

  # A start that fails after its initialize keeps the session id the remote
  # gave it; the next start does not send it on.
  $up->stop;
  ok $until->(sub { @{$fake->{deletes}} == 2 }), 'the stop ends s2';
  $fail_list = 1;
  like _await_bounded($up->start_p, 5)->{err}, qr/not now/, 'a start fails after its initialize';
  is_deeply [map { $_->{session} // 'none' } @{$fake->{posts}}], ['none', 's3', 's3'], 'with session s3';
  splice @{$fake->{posts}};
  $fail_list = 0;
  is $start->(), 'started', 'the next start';
  is_deeply $sessions->(), ['initialize: none', 'notifications/initialized: s4', 'tools/list: s4'],
    'goes without the id of the failed one';

  # A remote that does not let clients end sessions answers 405; one that
  # drops the DELETE answers nothing. Neither is a failure of the stop.
  for my $status (405, 'drop') {
    is $start->(), 'started', "$status: started" unless $up->state eq 'ready';
    @logged = ();
    $fake->{delete_status} = $status;
    my $before = @{$fake->{deletes}};
    $up->stop;
    is $up->state, 'stopped', "$status: the stop is done at once";
    ok $until->(sub { grep {/did not end the session/} @logged }), "$status: the DELETE is over";
    is scalar @{$fake->{deletes}}, $before + 1, "$status: it was sent once";
    is_deeply [grep { !/^(?:trace|debug|info):/ } @logged], [], "$status: logged at debug level only"
      or diag explain \@logged;
  }
  delete $fake->{delete_status};

  # An upstream a reload drops right after its stop goes at once, and its
  # session is ended all the same.
  is $start->(), 'started', 'started once more';
  my $sid = "s$fake->{sessions}";
  $up->stop;
  weaken(my $gone = $up);
  undef $up;
  is $gone, undef, 'the DELETE in flight does not hold the upstream';
  ok $until->(sub { grep { $_ eq $sid } @{$fake->{deletes}} }), 'and it still ends the session';

  $fake->{daemon}->stop;
};

subtest 'a start after a stop is a fresh one, though the stopped start has not settled yet' => sub {
  # A stop calls a start off, and the start settles a few ticks later. A start
  # asked for in between was handed the start the stop had called off, and was
  # rejected as stopped with it, though it came after the stop. It is a fresh
  # start: it begins once the stopped one has settled -- never alongside it --
  # and whoever asks in the meantime shares it. A stop before it begins calls
  # it off as well: the last word counts.
  for my $case (map { my $t = $_; map { [$t, $_] } 'at once', 'during the initialize' } qw(http sse)) {
    my ($transport, $when) = @$case;
    my $phase = "$transport, stopped $when";
    my $hold  = '';
    my $fake;
    my $handshake = mcp_answer('unused');
    if ($transport eq 'sse') {
      $fake = fake_sse(answer => sub ($req) { ($req->{method} // '') eq $hold ? undef : $handshake->($req) });
    }
    else {
      # (A held request never settles.)
      $fake = fake_http(answer => sub ($req) { ($req->{method} // '') eq $hold ? Mojo::Promise->new : $handshake->($req) });
    }
    my $up = MCP::Hub::Upstream::Http->new(
      name      => 'fake',
      config    => {type => $transport, url => $fake->{url}, request_timeout => 5},
      cache_dir => tempdir->to_string,
    );
    $up->log->level('fatal');

    my $initializes = sub { scalar grep { ($_->{method} // '') eq 'initialize' } @{$fake->{posts}} };
    my $until       = sub ($cond) {
      my $deadline = time + 5;
      Mojo::Promise->timer(0.01)->wait until $cond->() || time > $deadline;
      return $cond->();
    };
    # A start that a stop calls off: at once, or with its initialize on the way.
    my $stopped_start = sub {
      $hold = $when eq 'at once' ? '' : 'initialize';
      @{$fake->{posts}} = ();
      my $start = $up->start_p;
      ok $until->($initializes), "$phase: the initialize is on its way" if $hold;
      $up->stop;
      $hold = '';
      @{$fake->{posts}} = ();
      return $start;
    };
    my @order;
    $up->req_ua->on(start => sub ($ua, $tx) {
      push @order, 'initialize' if (eval { $tx->req->json->{method} } // '') eq 'initialize';
    });

    # (A block each: a start resolves with the upstream, which its promise
    # would hold past the weak reference below.)
    {    # Stop, and start again in the same tick.
      my $old = $stopped_start->();
      @order = ();
      $old->catch(sub { push @order, 'stopped' });
      my $new  = $up->start_p;
      my $also = $up->start_p;
      is $also, $new, "$phase: a second start in the meantime shares it";
      is _await_bounded($old, 2)->{err}, 'upstream fake: stopped', "$phase: the start the stop called off is rejected";
      is _await_bounded($new->then(sub { 'started' }), 5), 'started', "$phase: the fresh start connects";
      is $up->state, 'ready', "$phase: ready";
      is $initializes->(), 1, "$phase: with one handshake";
      is_deeply \@order, ['stopped', 'initialize'], "$phase: which began once the stopped start had settled";
      $up->stop;
    }

    {    # Stop, start, stop: the second stop calls the fresh start off before it begins.
      my $old        = $stopped_start->();
      my $called_off = $up->start_p;
      $up->stop;
      is _await_bounded($old, 2)->{err}, 'upstream fake: stopped', "$phase, stopped twice: the first start is rejected";
      is _await_bounded($called_off, 2)->{err}, 'upstream fake: stopped', "$phase, stopped twice: so is the fresh one";
      Mojo::Promise->timer(0.2)->wait;
      is $initializes->(), 0, "$phase, stopped twice: which never began";
      is $up->state, 'stopped', "$phase, stopped twice: stopped";
    }

    {    # Stop, start, stop, start: the start after the last stop is the one.
      my $old   = $stopped_start->();
      my $first = $up->start_p;
      $up->stop;
      my $last = $up->start_p;
      isnt $last, $first, "$phase, stopped twice, started again: a new fresh start";
      is _await_bounded($first, 2)->{err}, 'upstream fake: stopped',
        "$phase, stopped twice, started again: the first is called off";
      is _await_bounded($last->then(sub { 'started' }), 5), 'started',
        "$phase, stopped twice, started again: the last connects";
      Mojo::Promise->timer(0.1)->wait;
      is $initializes->(), 1, "$phase, stopped twice, started again: with one handshake";
      is $up->state, 'ready', "$phase, stopped twice, started again: ready";
      $up->stop;
    }

    weaken(my $gone = $up);
    undef $up;
    is $gone, undef, "$phase: nothing holds the upstream";
    $fake->{daemon}->stop;
  }
};

# The MCP conversation of a fake Streamable HTTP server: a handshake that lists
# one tool, and a tools/call answered `pong` -- or by $call, when it returns
# something.
sub pong_answer ($call = sub { undef }) {
  return sub ($req) {
    my ($id, $method) = ($req->{id}, $req->{method} // '');
    return {jsonrpc => '2.0', id => $id, result => {
      protocolVersion => '2025-06-18',
      capabilities    => {},
      serverInfo      => {name => 'fake-http', version => '0.0.1'},
    }} if $method eq 'initialize';
    return {jsonrpc => '2.0', id => $id, result => {tools => [{name => 'ping', inputSchema => {type => 'object'}}]}}
      if $method eq 'tools/list';
    return $call->($req) // {jsonrpc => '2.0', id => $id, result => {content => [{type => 'text', text => 'pong'}]}};
  };
}

# Every POST a fake Streamable HTTP server received since the last look, as
# "method: session" -- without the notifications/initialized, which goes on a
# connection of its own and may arrive after the requests that follow it.
sub posts_on ($fake) {
  return [map { "$_->{method}: " . ($_->{session} // 'none') }
    grep { ($_->{method} // '') ne 'notifications/initialized' } splice @{$fake->{posts}}];
}

sub until_true ($cond, $within = 5) {
  my $deadline = time + $within;
  Mojo::Promise->timer(0.01)->wait until $cond->() || time > $deadline;
  return $cond->();
}

subtest 'streamable http upstream: a session the remote ended is replaced, and the request goes out again on the new one' => sub {
  # A remote that has ended a session -- it restarted, or timed the session
  # out -- answers 404 to every request on it, and the spec has the client open
  # a new session then, with an initialize that carries no session id. The
  # upstream stayed `ready` on the dead session instead: the call failed with
  # "Not Found", and so did every later one, and a refresh, which listed again
  # over the same session, until a reload or a restart. The session goes, a new
  # one opens, and the request is sent once more, on it: the 404 says that it
  # did not run on the old one.
  my $calls = 0;
  my $fake  = fake_http(answer => pong_answer(sub ($req) { $calls++; undef }));
  my $up    = MCP::Hub::Upstream::Http->new(
    name      => 'fake',
    config    => {type => 'http', url => $fake->{url}, request_timeout => 5},
    cache_dir => tempdir->to_string,
  );
  my @logged;
  my $log = Mojo::Log->new;
  $log->unsubscribe('message')->on(message => sub ($l, $level, @lines) { push @logged, "$level: @lines" });
  $up->log($log);

  is _await_bounded($up->start_p->then(sub { 'started' }), 5), 'started', 'started';
  is _error_text(_await_bounded($up->call_tool('ping', {}), 5)), 'pong', 'a call is answered';
  is_deeply posts_on($fake), ['initialize: none', 'tools/list: s1', 'tools/call: s1'], 'on session s1';

  delete $fake->{live}{s1};
  my $r = _await_bounded($up->call_tool('ping', {}), 5);
  is _error_text($r), 'pong', 'the remote ended s1: the next call is answered all the same' or diag explain $r;
  ok !$r->{isError}, 'as a result, not an error';
  is_deeply posts_on($fake), ['tools/call: s1', 'initialize: none', 'tools/list: s2', 'tools/call: s2'],
    'after its 404 on s1, a new session -- its initialize without a session id -- and the call once more, on s2';
  is $calls, 2, 'the tool ran once for each call';
  is $up->state, 'ready', 'ready';

  is _error_text(_await_bounded($up->call_tool('ping', {}), 5)), 'pong', 'the next call';
  is_deeply posts_on($fake), ['tools/call: s2'], 'goes out on s2 at once';

  # A refresh lists over the session the upstream is on, and the same holds.
  delete $fake->{live}{s2};
  my $refreshed = _await_bounded($up->refresh_p->then(sub { 'refreshed' }), 5);
  is $refreshed, 'refreshed', 'the remote ended s2: a refresh goes through all the same' or diag explain $refreshed;
  is_deeply posts_on($fake), ['tools/list: s2', 'initialize: none', 'tools/list: s3', 'tools/list: s3'],
    'on a new session, s3';
  is _error_text(_await_bounded($up->call_tool('ping', {}), 5)), 'pong', 'and the next call';
  is_deeply posts_on($fake), ['tools/call: s3'], 'goes out on s3';

  # The sessions the remote ended are not ended again; the one it knows is.
  Mojo::Promise->timer(0.05)->wait;
  is_deeply $fake->{deletes}, [], 'no DELETE for a session the remote ended';
  $up->stop;
  ok until_true(sub { @{$fake->{deletes}} }), 'a stop ends the session';
  is_deeply $fake->{deletes}, ['s3'], 'the one the upstream is on, and only that one';
  is $up->error, undef, 'no failure reason';
  is_deeply [grep { !/^(?:trace|debug|info):/ } @logged], [], 'nothing logged as a failure' or diag explain \@logged;

  $fake->{daemon}->stop;
};

subtest 'streamable http upstream: a request goes out once more at most, a request of a start not again' => sub {
  # A new session for a request that lost its session, and the request once
  # more on it -- once: a remote that ends that session too fails the request.
  # A request of a start is never sent again: the start fails. The upstream
  # never stays on a session the remote has ended, and never ends it itself.
  my ($forget, $fake);
  $fake = fake_http(answer => pong_answer(sub ($req) {
    %{$fake->{live}} = () if $forget;    # it ends the session while the call runs
    undef;
  }));
  my $up = MCP::Hub::Upstream::Http->new(
    name      => 'fake',
    config    => {type => 'http', url => $fake->{url}, request_timeout => 5},
    cache_dir => tempdir->to_string,
  );
  $up->log->level('fatal');
  is _await_bounded($up->start_p->then(sub { 'started' }), 5), 'started', 'started';
  posts_on($fake);

  # The remote ends s1, and the new session s2 while the call runs on it.
  delete $fake->{live}{s1};
  $forget = 1;
  my $r = _await_bounded($up->call_tool('ping', {}), 5);
  ok $r->{isError}, 'a call whose new session ends too is an error result' or diag explain $r;
  like _error_text($r), qr/^upstream fake: the remote ended the session \(Not Found\)$/, 'that says why';
  is_deeply posts_on($fake), ['tools/call: s1', 'initialize: none', 'tools/list: s2', 'tools/call: s2'],
    'it went out once more, on s2, and not again';
  is $up->state, 'stopped', 'the upstream is not left on s2';
  $forget = 0;

  is _error_text(_await_bounded($up->call_tool('ping', {}), 5)), 'pong', 'the next call is answered';
  is_deeply posts_on($fake), ['initialize: none', 'tools/list: s3', 'tools/call: s3'], 'on a new session';

  # A remote that ends every session as soon as it gives it: the tools/list of
  # the next start 404s.
  $up->stop;
  ok until_true(sub { @{$fake->{deletes}} }), 'a stop ends s3';
  $fake->{volatile} = 1;
  my $s = _await_bounded($up->start_p, 5);
  like $s->{err}, qr/^upstream fake: the remote ended the session \(Not Found\)$/, 'a start whose session ends fails'
    or diag explain $s;
  is_deeply posts_on($fake), ['initialize: none', 'tools/list: s4'], 'its tools/list is not sent again';
  $up->stop;
  Mojo::Promise->timer(0.1)->wait;
  is_deeply $fake->{deletes}, ['s3'], 'and a stop does not end s4, which the remote ended';

  $fake->{daemon}->stop;
};

subtest 'streamable http upstream: a 404 on a request without a session id is only an error' => sub {
  # A 404 means the remote ended the session only on a request that carried
  # one: a remote that gives no session ids, or a URL that is wrong, answers
  # 404 for its own reasons. That is an error, and opens no new session.
  my $fake = fake_http(answer => pong_answer(sub ($req) {
    $req->{params}{name} eq 'missing' ? {http_status => 404} : undef;
  }));
  $fake->{stateless} = 1;
  my $up = MCP::Hub::Upstream::Http->new(
    name      => 'fake',
    config    => {type => 'http', url => $fake->{url}, request_timeout => 5},
    cache_dir => tempdir->to_string,
  );
  $up->log->level('fatal');
  is _await_bounded($up->start_p->then(sub { 'started' }), 5), 'started', 'started';
  is_deeply posts_on($fake), ['initialize: none', 'tools/list: none'], 'a remote that gives no session id';

  for my $n (1 .. 2) {
    my $r = _await_bounded($up->call_tool('missing', {}), 5);
    ok $r->{isError}, "call $n: a 404 is an error result";
    like _error_text($r), qr/^upstream fake: Not Found$/, "call $n: Not Found";
    is_deeply posts_on($fake), ['tools/call: none'], "call $n: sent once, and no new session";
    is $up->state, 'ready', "call $n: still ready";
  }
  is _error_text(_await_bounded($up->call_tool('ping', {}), 5)), 'pong', 'a call it knows is answered';

  (my $wrong = $fake->{url}) =~ s{/mcp$}{/wrong};
  my $other = MCP::Hub::Upstream::Http->new(
    name      => 'fake',
    config    => {type => 'http', url => $wrong, request_timeout => 5},
    cache_dir => tempdir->to_string,
  );
  $other->log->level('fatal');
  my $s = _await_bounded($other->start_p, 5);
  like $s->{err}, qr/^upstream fake: Not Found$/, 'a wrong url: the start fails with Not Found' or diag explain $s;
  is $other->state, 'stopped', 'stopped';

  $up->stop;
  $fake->{daemon}->stop;
};

subtest 'streamable http upstream: requests that lose the same session share one new session' => sub {
  # Calls in flight when the remote ends their session all come back 404. One
  # new session serves them all -- with one handshake, which those that come
  # back while it runs wait for. One that comes back after it went out on it at
  # once.
  my ($hold_init, $hold_call);
  my $fake = fake_http(answer => sub ($req) {
    my $answer = pong_answer()->($req);
    my $hold   = ($req->{method} // '') eq 'initialize' ? $hold_init
      : ($req->{params}{name} // '') eq 'held'         ? $hold_call
      :                                                  undef;
    return $hold ? $hold->then(sub { $answer }) : $answer;
  });
  my $up = MCP::Hub::Upstream::Http->new(
    name      => 'fake',
    config    => {type => 'http', url => $fake->{url}, request_timeout => 5},
    cache_dir => tempdir->to_string,
  );
  $up->log->level('fatal');
  is _await_bounded($up->start_p->then(sub { 'started' }), 5), 'started', 'started';
  posts_on($fake);

  # Every 404 the upstream has read.
  my $not_found = 0;
  $up->req_ua->on(start => sub ($ua, $tx) {
    $tx->on(finish => sub ($tx) { $not_found++ if ($tx->res->code // 0) == 404 });
  });

  # One call the remote holds on s1 until the new session is up.
  $hold_call = Mojo::Promise->new;
  my $late = $up->call_tool('held', {});
  ok until_true(sub { grep { ($_->{params}{name} // '') eq 'held' } @{$fake->{posts}} }), 'one call runs on s1';

  # The remote ends s1; three calls go out on it, and the new session's
  # initialize waits until all three have come back.
  delete $fake->{live}{s1};
  $hold_init = Mojo::Promise->new;
  my @calls = map { $up->call_tool('ping', {}) } 1 .. 3;
  ok until_true(sub { $not_found == 3 && grep { ($_->{method} // '') eq 'initialize' } @{$fake->{posts}} }),
    'three calls come back 404 while the new session opens';
  Mojo::Promise->timer(0.05)->wait;
  $hold_init->resolve;
  undef $hold_init;

  is _error_text(_await_bounded($_, 5)), 'pong', 'a call that came back 404 is answered' for @calls;
  my $posts = posts_on($fake);
  is scalar(grep { $_ eq 'initialize: none' } @$posts), 1, 'one new session for all of them';
  is scalar(grep { $_ eq 'tools/call: s2' } @$posts), 3, 'each went out once more, on it';

  # The held call comes back 404 now, with s2 up.
  $hold_call->resolve;
  is _error_text(_await_bounded($late, 5)), 'pong', 'the call held on s1 is answered too';
  is_deeply posts_on($fake), ['tools/call: s2'], 'it went out once more, on s2 -- no new session for it';
  is $up->state, 'ready', 'ready';
  is_deeply $fake->{deletes}, [], 'no DELETE for s1';

  $up->stop;
  $fake->{daemon}->stop;
};

subtest 'streamable http upstream: a stop calls off the new session, and opens none' => sub {
  # A stop while the new session opens calls that start off, as any start: the
  # request waiting for it fails as stopped. A stop before the 404 came back
  # opens no new session at all -- what was stopped is not started again by a
  # call that was left to finish. Neither ends the session the remote ended;
  # the stop ends the new one if its initialize was answered.
  for my $when ('during the initialize', 'during the tools/list', 'before the 404') {
    my $hold = Mojo::Promise->new;
    my $held = '';
    my $fake = fake_http(answer => sub ($req) {
      my $answer = pong_answer()->($req);
      my $name   = ($req->{method} // '') eq 'tools/call' ? $req->{params}{name} : $req->{method};
      return $name eq $held ? $hold->then(sub { $answer }) : $answer;
    });
    my $up = MCP::Hub::Upstream::Http->new(
      name      => 'fake',
      config    => {type => 'http', url => $fake->{url}, request_timeout => 5},
      cache_dir => tempdir->to_string,
    );
    my @logged;
    my $log = Mojo::Log->new;
    $log->unsubscribe('message')->on(message => sub ($l, $level, @lines) { push @logged, "$level: @lines" });
    $up->log($log);
    is _await_bounded($up->start_p->then(sub { 'started' }), 5), 'started', "$when: started";
    posts_on($fake);

    my ($call, $cut);
    if ($when eq 'before the 404') {
      # The call runs on s1 when the stop comes; the remote ends s1 after it.
      $held = 'held';
      $call = $up->call_tool('held', {});
      ok until_true(sub { grep { ($_->{params}{name} // '') eq 'held' } @{$fake->{posts}} }), "$when: the call runs";
      $up->stop;
      delete $fake->{live}{s1};
      $hold->resolve;
    }
    else {
      $held = $when eq 'during the initialize' ? 'initialize' : 'tools/list';
      delete $fake->{live}{s1};
      $cut  = $fake->{cut};
      $call = $up->call_tool('ping', {});
      ok until_true(sub { grep { ($_->{method} // '') eq $held } @{$fake->{posts}} }),
        "$when: the call came back 404, the new session opens";
      $up->stop;
    }

    my $r = _await_bounded($call, 2);
    ok $r->{isError}, "$when: the call is an error result" or diag explain $r;
    like _error_text($r),
      $when eq 'before the 404' ? qr/^upstream fake: the remote ended the session \(Not Found\)$/ : qr/^upstream fake: stopped$/,
      "$when: that says why";
    is $up->state, 'stopped', "$when: stopped";
    ok until_true(sub { $fake->{cut} > $cut }, 1), "$when: the $held is cut off" if defined $cut;
    my %sent = (
      'during the initialize' => ['tools/call: s1', 'initialize: none'],
      'during the tools/list' => ['tools/call: s1', 'initialize: none', 'tools/list: s2'],
      'before the 404'        => ['tools/call: s1'],
    );
    Mojo::Promise->timer(0.1)->wait;
    is_deeply posts_on($fake), $sent{$when}, "$when: nothing went out after the stop" ;
    ok until_true(sub { @{$fake->{deletes}} }), "$when: the stop ends s2" if $when eq 'during the tools/list';
    is_deeply $fake->{deletes}, $when eq 'during the tools/list' ? ['s2'] : [], "$when: and never s1";
    is $up->error, undef, "$when: no failure reason";
    is_deeply [grep { !/^(?:trace|debug|info):/ } @logged], [], "$when: nothing logged as a failure"
      or diag explain \@logged;

    # Nor is it stuck: the next start opens a new session.
    $held = '';
    is _error_text(_await_bounded($up->call_tool('ping', {}), 5)), 'pong', "$when: the next call is answered";
    my $posts = posts_on($fake);
    is $posts->[0], 'initialize: none', "$when: on a new session" or diag explain $posts;
    $up->stop;

    weaken(my $gone = $up);
    undef $up;
    is $gone, undef, "$when: nothing holds the upstream";
    $fake->{daemon}->stop;
  }
};

subtest 'streamable http upstream: a call let through just before a start goes out on the session it opens' => sub {
  # A call is let through by start_p and sent a tick later. A start that began
  # in between -- after a stop, or for the new session a 404 asks for -- took it
  # for a request of its own: it went out in the middle of the handshake, with
  # no session id before the initialize was answered (a stateful remote answers
  # that 400), a stop cut it off as a request of the start, and it held no
  # session against the stop's DELETE. It waits for the start, and goes out on
  # the session the start opens, as a call made while it starts does.
  for my $when ('a stop and a start', 'a new session after a 404') {
    my $hold = Mojo::Promise->new;
    my $fake = fake_http(answer => pong_answer(sub ($req) {
      return undef unless $req->{params}{name} eq 'held';
      my $id = $req->{id};
      return $hold->then(sub { {jsonrpc => '2.0', id => $id, result => {content => [{type => 'text', text => 'pong'}]}} });
    }));
    my $up = MCP::Hub::Upstream::Http->new(
      name      => 'fake',
      config    => {type => 'http', url => $fake->{url}, request_timeout => 5},
      cache_dir => tempdir->to_string,
    );
    my @logged;
    my $log = Mojo::Log->new;
    $log->unsubscribe('message')->on(message => sub ($l, $level, @lines) { push @logged, "$level: @lines" });
    $up->log($log);
    is _await_bounded($up->start_p->then(sub { 'started' }), 5), 'started', "$when: started";
    posts_on($fake);

    # The state the call is let through in, and the call.
    my ($let_through, $call, $other);
    if ($when eq 'a stop and a start') {
      # In the running loop, as in the daemon: outside it, the stop's DELETE
      # has Mojo::UserAgent run one tick, and the call would go out in the
      # middle of the stop, before the start.
      Mojo::IOLoop->next_tick(sub {
        $let_through = $up->state;
        $call        = $up->call_tool('held', {});
        $up->stop;
        $up->start_p;
      });
      ok until_true(sub { @{$fake->{deletes}} }), "$when: the stop ends s1";
    }
    else {
      # The remote has ended s1. The call is let through as the 404 of another
      # comes back: once the hub has read it, before it acts on it -- a tick
      # before the new session's start begins.
      delete $fake->{live}{s1};
      weaken(my $weak = $up);
      my $hooked;
      $up->req_ua->on(start => sub ($ua, $tx) {
        return if $hooked++;
        $tx->on(finish => sub ($tx) {
          Mojo::IOLoop->next_tick(sub { $let_through = $weak->state; $call = $weak->call_tool('held', {}) });
        });
      });
      $other = $up->call_tool('ping', {});
    }
    ok until_true(sub {
      $call && $up->state eq 'ready' && grep { ($_->{params}{name} // '') eq 'held' } @{$fake->{posts}};
    }), "$when: the start is through, and the call sent";
    is $let_through, 'ready', "$when: the call was let through on the ready upstream";
    is _error_text(_await_bounded($other, 5)), 'pong', "$when: the call that came back 404 is answered" if $other;
    is_deeply posts_on($fake),
      $when eq 'a stop and a start'
      ? ['initialize: none', 'tools/list: s2', 'tools/call: s2']
      : ['tools/call: s1', 'initialize: none', 'tools/list: s2', 'tools/call: s2', 'tools/call: s2'],
      "$when: the call went out once the start was through, on the session it opened";

    # A call on the session the upstream is on: a stop leaves it to finish,
    # and ends the session once it is through.
    my ($cut, $deleted) = ($fake->{cut}, scalar @{$fake->{deletes}});
    $up->stop;
    Mojo::Promise->timer(0.1)->wait;
    is scalar @{$fake->{deletes}}, $deleted, "$when: a stop does not end s2 under the call";
    $hold->resolve;
    is _error_text(_await_bounded($call, 5)), 'pong', "$when: the call is answered";
    is $fake->{cut}, $cut, "$when: its POST was not cut off";
    ok until_true(sub { @{$fake->{deletes}} > $deleted }), "$when: then s2 is ended";
    is_deeply $fake->{deletes}, $when eq 'a stop and a start' ? ['s1', 's2'] : ['s2'],
      "$when: with one DELETE carrying its id";
    is $up->error, undef, "$when: no failure reason";
    is_deeply [grep { !/^(?:trace|debug|info):/ } @logged], [], "$when: nothing logged as a failure"
      or diag explain \@logged;

    weaken(my $gone = $up);
    undef $up;
    is $gone, undef, "$when: nothing holds the upstream";
    $fake->{daemon}->stop;
  }
};

subtest 'an error reads the same over both transports: no trailing newline' => sub {
  # Over Streamable HTTP the reason of a failed request ended in a newline --
  # "upstream fake: nope\n" -- and the agent read it in the text of the error
  # result; over HTTP+SSE it did not.
  my $fake = fake_http(answer => pong_answer(sub ($req) {
    my $name = $req->{params}{name};
    return $name eq 'rpc'    ? {jsonrpc => '2.0', id => $req->{id}, error => {code => -32000, message => 'nope'}}
      :    $name eq 'status' ? {http_status => 500}
      :                        undef;
  }));
  my $up = MCP::Hub::Upstream::Http->new(
    name      => 'fake',
    config    => {type => 'http', url => $fake->{url}, request_timeout => 5},
    cache_dir => tempdir->to_string,
  );
  $up->log->level('fatal');
  is _error_text(_await_bounded($up->call_tool('rpc', {}), 5)), 'upstream fake: nope', 'http: a JSON-RPC error';
  is _error_text(_await_bounded($up->call_tool('status', {}), 5)), 'upstream fake: Internal Server Error',
    'http: an HTTP error status';

  # A remote that ends every session as soon as it gives it: the start fails.
  $up->stop;
  $fake->{volatile} = 1;
  is _error_text(_await_bounded($up->call_tool('ping', {}), 5)),
    'upstream fake: the remote ended the session (Not Found)', 'http: a session the remote ended';
  $up->stop;

  (my $wrong = $fake->{url}) =~ s{/mcp$}{/wrong};
  my $other = MCP::Hub::Upstream::Http->new(
    name      => 'fake',
    config    => {type => 'http', url => $wrong, request_timeout => 5},
    cache_dir => tempdir->to_string,
  );
  $other->log->level('fatal');
  is _await_bounded($other->start_p, 5)->{err}, 'upstream fake: Not Found', 'http: a start that fails';

  my $sse = fake_sse(answer => mcp_answer({code => -32000, message => 'nope'}));
  my $sup = MCP::Hub::Upstream::Http->new(
    name      => 'fake',
    config    => {type => 'sse', url => $sse->{url}, request_timeout => 5},
    cache_dir => tempdir->to_string,
  );
  is _error_text(_await_bounded($sup->call_tool('boom', {}), 10)), 'upstream fake: nope', 'sse: a JSON-RPC error';

  $sup->stop;
  $sse->{daemon}->stop;
  $fake->{daemon}->stop;
};

subtest 'streamable http upstream: the initialize carries no MCP-Protocol-Version, the requests after it the one it negotiated' => sub {
  # The version goes on the requests after the initialize, which negotiates
  # it. The initialize carried one too -- the one of the session before, of
  # the cached manifest, or the default -- which may not be the one it asks for
  # in its body, and a remote answers a version it does not support with 400.
  my $version = '2025-03-26';
  my $answer  = pong_answer();
  my $fake    = fake_http(answer => sub ($req) {
    my $res = $answer->($req);
    $res->{result}{protocolVersion} = $version if ($req->{method} // '') eq 'initialize';
    return $res;
  });
  my $cache    = tempdir;
  my $versions = sub { [sort map { "$_->{method}: " . ($_->{version} // 'none') } splice @{$fake->{posts}}] };
  my $build    = sub {
    my $up = MCP::Hub::Upstream::Http->new(
      name      => 'fake',
      config    => {type => 'http', url => $fake->{url}, request_timeout => 5},
      cache_dir => "$cache",
    );
    $up->log->level('fatal');
    return $up;
  };

  my $up = $build->();
  is _await_bounded($up->start_p->then(sub { 'started' }), 5), 'started', 'started, with no manifest yet';
  is_deeply $versions->(),
    ['initialize: none', 'notifications/initialized: 2025-03-26', 'tools/list: 2025-03-26'],
    'the initialize carries none, the requests after it the version the remote answered';

  $up->stop;
  $version = '2025-06-18';
  is _await_bounded($up->start_p->then(sub { 'started' }), 5), 'started', 'started again';
  is_deeply $versions->(),
    ['initialize: none', 'notifications/initialized: 2025-06-18', 'tools/list: 2025-06-18'],
    'the initialize carries none of the session before, the requests after it the new one';
  $up->stop;

  $version = '2025-03-26';
  my $cached = $build->();
  is $cached->manifest_fetched_at ? 'cached' : 'none', 'cached', 'an upstream built over the cached manifest';
  is _await_bounded($cached->start_p->then(sub { 'started' }), 5), 'started', 'started';
  is_deeply $versions->(),
    ['initialize: none', 'notifications/initialized: 2025-03-26', 'tools/list: 2025-03-26'],
    'its initialize carries none of the manifest';
  $cached->stop;

  $fake->{daemon}->stop;
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
