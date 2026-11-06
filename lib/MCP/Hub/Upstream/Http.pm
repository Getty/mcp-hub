package MCP::Hub::Upstream::Http;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Hub::Upstream', -signatures;

use MCP::Hub::Manifest;
use Mojo::IOLoop;
use Mojo::IOLoop::TLS;
use Mojo::JSON qw(from_json);
use Mojo::Promise;
use Mojo::SSE qw(parse_event);
use Mojo::URL;
use Mojo::UserAgent;

# ABSTRACT: An HTTP MCP server (Streamable HTTP or HTTP+SSE) mounted as an upstream

# The same crash-loop threshold as MCP::Hub::Upstream::Stdio (three exits within
# its fail_window of five seconds): a remote that refuses to connect three times
# within five seconds is marked `failed` rather than reconnected on every call.
use constant FAIL_THRESHOLD => 3;
use constant FAIL_WINDOW    => 5;

# The streaming user agent for the long-lived SSE GET stream (no timeout).
has ua => sub {
  my $ua = Mojo::UserAgent->new;
  $ua->inactivity_timeout(0);
  $ua->max_response_size(0);
  return $ua;
};

# A separate agent for POSTs, so its request timeout never cuts the SSE stream.
has req_ua => sub ($self) {
  my $ua = Mojo::UserAgent->new;
  $ua->request_timeout($self->request_timeout || 60);
  $ua->max_response_size(0);
  return $ua;
};

has cache_dir => sub ($self) { $self->hub ? $self->hub->hub_config->cache_dir : '.' };

sub new ($class, %args) {
  my $self = $class->SUPER::new(%args);
  my $c    = $self->config;

  if (my $reason = $self->_tls_missing($c->{url})) { die "$reason\n" }

  $self->{request_timeout} = $c->{request_timeout} if defined $c->{request_timeout};
  $self->{manifest}        = MCP::Hub::Manifest->new(cache_dir => $self->cache_dir);
  $self->{transport}       = ($c->{type} // '') eq 'sse' ? 'sse' : 'http';
  $self->{url}             = $c->{url};
  $self->{headers}         = $c->{headers} // {};
  $self->{id}              = 0;
  $self->{pending}         = {};
  $self->{failures}        = [];

  $self->_build_server;
  return $self;
}

sub transport ($self) { return $self->{transport} }

# An https remote needs TLS in this perl: IO::Socket::SSL 2.009+, unless
# MOJO_NO_TLS turns it off. Mojo::IOLoop::TLS settles that once, when it is
# compiled, so no retry, refresh or reload can cure it -- every connect would
# fail the same way. Returns the reason, with the fix, when $url is https and
# TLS is missing; the constructor dies with it, and the hub keeps the entry as a
# failed upstream that says so. A compose entry's url is checked with it too
# (MCP::Hub::Upstream::Compose), so both give the same reason.
sub _tls_missing ($self, $url) {
  return undef unless defined $url && (Mojo::URL->new($url)->protocol // '') eq 'https';
  return undef if Mojo::IOLoop::TLS->can_tls;
  return 'an https url needs TLS, which this perl does not have: install IO::Socket::SSL 2.009 or newer'
    . ' (cpanm IO::Socket::SSL), leave MOJO_NO_TLS unset, and restart the daemon';
}

# --- lifecycle -------------------------------------------------------------

sub start_p ($self) {
  return Mojo::Promise->resolve($self) if $self->state eq 'ready';

  # A start asked for after a stop is a fresh one. The start the stop called
  # off settles a few ticks after the stop (the catch below); the fresh one
  # begins once it has, so that two handshakes never run at once, and whoever
  # asks in the meantime shares it.
  return $self->{next_start} //= $self->_start_after_p($self->{start_promise})
    if $self->{start_promise} && $self->{stop_requested};
  return $self->{start_promise} if $self->{start_promise};

  # A dead remote is left only by an explicit refresh: an ordinary call against a
  # failed upstream reports why instead of reconnecting to it all over again.
  return Mojo::Promise->reject($self->_failed_message) if $self->state eq 'failed';

  $self->state('starting');
  my $done = Mojo::Promise->new;
  $self->{start_promise} = $done;
  delete @$self{qw(failure_reason stop_requested)};    # both belong to this attempt only

  # A start opens a new session: its initialize goes without the id of an
  # earlier one, and the remote assigns one.
  delete $self->{session_id};

  my $prep = $self->{transport} eq 'sse' ? $self->_open_sse_p : Mojo::Promise->resolve;
  $prep->then(sub { $self->_handshake_p })->then(sub ($manifest) {
    # A stop after the last request, or during a prompts/list or
    # resources/list -- whose failure the handshake takes for an empty list --
    # calls the start off all the same.
    die "stopped\n" if $self->{stop_requested};
    $self->_apply_manifest($manifest);
    delete $self->{failed};    # a live connection is never failed
    $self->error(undef);
    $self->state('ready');
    delete $self->{start_promise};
    $self->touch;
    $done->resolve($self);
  })->catch(sub ($err) {
    # A start that a stop called off did not fail: it is neither logged nor
    # counted as a connect failure, and it is rejected as stopped, whichever
    # step of it the stop cut short -- a request in flight, the next one, which
    # is not sent (_sse_request_p, _http_send_p), or none.
    my $stopped = delete $self->{stop_requested};
    $stopped
      ? $self->log->debug("[@{[$self->name]}] start called off by a stop")
      : $self->log->error("[@{[$self->name]}] handshake failed: $err");
    $self->_close_sse;
    # The session its initialize was given is ended as a stop ends one -- unless
    # the stop has ended it already, or the remote has (_session_gone). The next
    # start opens a new one.
    if (defined(my $sid = delete $self->{session_id})) { $self->_end_session($sid) }
    $self->_record_failure unless $stopped;
    $self->state($self->{failed} ? 'failed' : 'stopped');
    delete $self->{start_promise};
    $done->reject($stopped ? "upstream @{[$self->name]}: stopped" : "$err");
    return;    # never hand the rejected promise back into the chain
  });

  return $done;
}

# The start asked for after a stop: once the start the stop called off has
# settled, it begins -- unless a stop called it off as well in the meantime
# (stop). The last word counts: a start asked for after that stop is another
# one, and this one no longer begins.
sub _start_after_p ($self, $called_off) {
  my $next  = Mojo::Promise->new;
  my $begin = sub {
    my $current = $self->{next_start};
    return unless $current && $current == $next;
    delete $self->{next_start};
    $self->start_p->then(sub { $next->resolve(@_) }, sub { $next->reject(@_) });
  };
  $called_off->then($begin, $begin);
  return $next;
}

# A stop calls off what it finds under way, as stopped: a start (see start_p's
# catch), the start asked for after an earlier stop that waits for it
# (_start_after_p), a connect still waiting for its endpoint (_close_sse) and
# the requests in flight -- those first, before the closing stream fails them as
# closed. Over Streamable HTTP the requests in flight here are those of a start
# (_http_send_p); a call is left to finish. The stop also ends the session
# (_end_session).
sub stop ($self) {
  $self->{stop_requested} = 1 if $self->{start_promise};
  if (my $next = delete $self->{next_start}) { $next->reject("upstream @{[$self->name]}: stopped") }
  $self->_fail_pending("upstream @{[$self->name]}: stopped");
  $self->_close_sse;
  if (defined(my $sid = delete $self->{session_id})) { $self->_end_session($sid) }
  $self->state('stopped');
  return $self;
}

sub refresh_p ($self) {
  # In flight like a call (_held_p): a remote has no idle timer, but the
  # container behind a docker entry's engine has.
  if ($self->state eq 'ready') {
    return $self->_held_p($self->_list_all_p
      ->then(sub ($lists) { $self->_apply_manifest($self->_manifest_from($lists)); return $self }))
      ->catch(sub ($err) { $self->log->debug("[@{[$self->name]}] refresh failed: $err"); return $self });
  }
  $self->_clear_failure if $self->state eq 'failed';
  return $self->start_p;
}

sub apply_timeouts ($self, $timeouts) {
  $self->SUPER::apply_timeouts($timeouts);
  # req_ua baked the old request timeout into itself; drop it so the next
  # request builds one with the new value.
  delete $self->{req_ua};
  return $self;
}

sub _hash ($self) {
  my $c = $self->config;
  return $self->{manifest}->hash($c->{url}, [$c->{type} // 'http'], undef);
}

# --- transport: request / notify -------------------------------------------

sub _request_p ($self, $method, $params = {}, $of_start = 0) {
  return $self->{transport} eq 'sse'
    ? $self->_sse_request_p($method, $params)
    : $self->_http_request_p($method, $params, $of_start);
}

sub _notify ($self, $method, $params = {}) {
  my $obj = {jsonrpc => '2.0', method => $method, params => $params};
  return $self->{transport} eq 'sse' ? $self->_sse_post($obj) : $self->_http_post($obj);
}

# --- Streamable HTTP (single endpoint, response on the POST) ---------------

# A request is one of a start's when the start's handshake sends it
# ($of_start, MCP::Hub::Upstream::_handshake_p). Any other request that finds a
# start under way waits for it and goes out on the session it opens, as a call
# made while the upstream starts does (start_p). Such is a call let through just
# before a start began -- after a stop, or for the new session a 404 asks for
# (_session_gone) -- and the next page of a refresh that a stop and a start
# overtook. Sent at once, it would go out in the middle of the handshake, with
# no session id before the initialize is answered, as a request of the start: a
# stop would cut it off, and it would keep no session from the stop's DELETE
# (_http_send_p). A stop that calls the start off fails it as stopped.
#
# A request that comes back 404 because the remote has ended its session
# (_session_gone) is sent once more, on the new session -- not again after
# that. The 404 says it did not run on the old one, so it does not run twice.
# A request of a start is not sent again: the start fails.
sub _http_request_p ($self, $method, $params, $of_start, $again = 0) {
  return $self->{start_promise}->then(sub { $self->_http_request_p($method, $params, 0, $again) })
    if !$of_start && $self->{start_promise};

  my $renewed;
  return $self->_http_send_p($method, $params, $of_start, $again ? undef : \$renewed)->catch(sub ($err) {
    return Mojo::Promise->reject($err) unless $renewed;
    return $renewed->then(sub { $self->_http_request_p($method, $params, 0, 1) });
  });
}

sub _http_send_p ($self, $method, $params, $of_start, $renewed = undef) {
  # The next request of a start that a stop called off is not sent.
  return Mojo::Promise->reject("upstream @{[$self->name]}: stopped") if $self->{stop_requested};

  my $id  = ++$self->{id};
  my $req = {jsonrpc => '2.0', id => $id, method => $method, params => $params};

  # The response is either a JSON body or a text/event-stream. Mojo parses SSE
  # into events (leaving the body empty), so capture our reply from the sse
  # event stream; a plain JSON reply is read from the body once the tx is done.
  my $tx    = $self->req_ua->build_tx(POST => $self->{url} => $self->_http_headers($method) => json => $req);
  my $found;
  $tx->res->content->on(sse => sub ($content, $event = undef) {
    return unless $event && defined $event->{text};
    my $msg = eval { from_json($event->{text}) };
    $found = $msg if ref $msg eq 'HASH' && exists $msg->{id} && ($msg->{id} // '') eq $id;
  });

  # A request of a start is in {pending} while it runs, so that a stop calls it
  # off with the start, at once: _fail_pending rejects it and drops its
  # connection, and an answer that comes all the same is not taken -- nor the
  # session id on it. Any other request, a call on a ready upstream, is left
  # to finish: the remote may be carrying it out already.
  my $done = Mojo::Promise->new;
  $self->{pending}{$id} = {promise => $done, tx => $tx} if $of_start;

  # Such a call keeps the session it went out on, so that a stop ends the
  # session only once the call is through (_end_session).
  my $sent    = $self->{session_id};
  my $session = $of_start ? undef : $sent;
  $self->{calls_on}{$session}++ if defined $session;
  my $settled = sub {
    delete $self->{pending}{$id};
    return unless defined $session && !--$self->{calls_on}{$session};
    delete $self->{calls_on}{$session};
    $self->_end_session($session) if delete $self->{ending}{$session};
  };

  # A request that fails is rejected with its reason as it is -- as over
  # HTTP+SSE, with no newline at its end for the agent to read. One the remote
  # answers with a JSON-RPC error is rejected with that answer, which reads the
  # same (MCP::Hub::Upstream::_error_answer); an HTTP error status is no answer.
  my $fail = sub ($reason) { Mojo::Promise->reject("upstream @{[$self->name]}: $reason") };
  $self->req_ua->start_p($tx)->then(sub ($tx) {
    # Called off by a stop: the answer is turned away. An initialize the stop
    # found still connecting, or with its answer on the way, has opened a
    # session on the remote all the same, and that session is ended.
    if ($of_start && !$self->{pending}{$id}) {
      my $sid = $method eq 'initialize' && $tx->res->headers->header('Mcp-Session-Id');
      $self->_end_session($sid) if $sid;
      return undef;
    }
    if (my $err = $tx->error) {
      # The remote has ended the session this went out on (_session_gone).
      if (!$found && defined $sent && ($err->{code} // 0) == 404) {
        my $renew = $self->_session_gone($sent, $renewed && !$of_start);
        $$renewed = $renew if $renewed;
        return $fail->('the remote ended the session (' . $self->_error_message($err) . ')');
      }
      return $fail->($self->_error_message($err)) unless $found;
    }
    # The session is the one the answer to the initialize names. A later answer
    # that names one too -- the reference server names it on every answer --
    # never moves the upstream: a call left to finish past a stop would put it
    # back on the session the stop ended.
    if ($method eq 'initialize' && (my $sid = $tx->res->headers->header('Mcp-Session-Id'))) {
      $self->{session_id} = $sid;
    }

    # $found is set when Mojo parsed the SSE inline (non-chunked). Otherwise the
    # reply is a plain JSON body, or -- for a chunked event-stream, which Mojo
    # does not SSE-parse -- the de-chunked events sit in the body; parse those.
    my $res = $found // _reply_from_body($tx, $id);
    return $fail->("no response for $method") unless ref $res eq 'HASH';
    return Mojo::Promise->reject($self->_error_answer($res->{error})) if $res->{error};
    return $res->{result} // {};
  })->then(
    sub ($result) { $settled->(); $done->resolve($result); return },
    sub ($err)    { $settled->(); $done->reject($err);     return },
  );
  return $done;
}

# A session the hub is done with -- a stop forgot its id -- is ended on the
# remote, as the spec asks of a client that no longer needs one: one DELETE to
# the endpoint with its Mcp-Session-Id. A call still on it was left to finish
# (stop), and the remote may tear the session down with whatever runs in it,
# so the last call to settle sends the DELETE instead.
#
# It is sent and forgotten: nothing waits for it, and a remote that answers 405
# -- it does not let clients end sessions -- or cannot be reached is only
# logged at debug level. req_ua's connect and request timeouts bound it. The
# request holds the user agent, not the upstream: an upstream that a reload
# drops right after its stop goes at once, and its DELETE still goes out.
# Only Streamable HTTP has sessions.
sub _end_session ($self, $sid) {
  return $self unless $self->{transport} eq 'http';
  if ($self->{calls_on}{$sid}) { $self->{ending}{$sid} = 1; return $self }

  my ($ua, $name, $log) = ($self->req_ua, $self->name, $self->log);
  my $tx = $ua->build_tx(DELETE => $self->{url} => {
    %{$self->{headers}},
    'MCP-Protocol-Version' => $self->{server_protocol} // $self->protocol_version,
    'Mcp-Session-Id'       => $sid,
  });
  $ua->start($tx => sub ($held, $tx) {
    undef $ua;    # held until it is over, not longer
    my $err = $tx->error or return;
    $log->debug("[$name] the remote did not end the session: $err->{message}");
  });
  return $self;
}

# The remote answered 404 to a request on session $sid: it has ended the
# session -- it restarted, or timed the session out -- and the spec has the
# client open a new one. The upstream leaves it, and nothing ends it again: no
# DELETE goes out for it, not even the one a stop left to its last call.
#
# With $renew -- for a request that is no request of a start and goes out once
# more -- it returns the promise of the session to send it on: a new one if
# the upstream was still on $sid, opened by one start (start_p) that every
# request which lost $sid shares; the one it is on, or opening, if it has moved
# on since. None after a stop: a call left to finish does not start again what
# the stop stopped. Without $renew a request of a start fails its start, and
# any other request fails, leaving the upstream stopped: its next call opens a
# new session.
sub _session_gone ($self, $sid, $renew) {
  delete $self->{ending}{$sid};
  my $current = defined $self->{session_id} && $self->{session_id} eq $sid;
  if ($current) {
    delete $self->{session_id};
    $self->state('stopped') if $self->state eq 'ready';
  }
  return undef unless $renew;
  return $self->start_p
    if $current || $self->state eq 'ready' || ($self->{start_promise} && !$self->{stop_requested});
  return undef;
}

sub _http_post ($self, $obj) {
  my $tx = $self->req_ua->build_tx(POST => $self->{url} => $self->_http_headers($obj->{method}) => json => $obj);
  $self->req_ua->start($tx => sub { });
  return 1;
}

sub _reply_from_body ($tx, $id) {
  my $ct = $tx->res->headers->content_type // '';
  return $tx->res->json if $ct =~ m{application/json}i;
  return undef unless $ct =~ m{text/event-stream}i;

  my $buf = $tx->res->body // '';
  while (my $event = parse_event(\$buf)) {
    next unless defined $event->{text} && length $event->{text};
    my $msg = eval { from_json($event->{text}) };
    return $msg if ref $msg eq 'HASH' && exists $msg->{id} && ($msg->{id} // '') eq $id;
  }
  return undef;
}

# The protocol version goes on every request after the initialize, as the
# version the initialize negotiated -- not on the initialize itself, which
# negotiates it: the only one it could carry is that of the session before, of
# the cached manifest or the default, which need not be the one its body asks
# for, and a remote answers a version it does not support with 400.
sub _http_headers ($self, $method) {
  return {
    %{$self->{headers}},
    'Content-Type' => 'application/json',
    'Accept'       => 'application/json, text/event-stream',
    ($method eq 'initialize' ? () : ('MCP-Protocol-Version' => $self->{server_protocol} // $self->protocol_version)),
    (defined $self->{session_id} ? ('Mcp-Session-Id' => $self->{session_id}) : ()),
  };
}

# --- HTTP+SSE (GET stream for responses, POST endpoint for requests) -------
#
# Mojo::UserAgent only parses SSE when the response is not chunked, but the node
# servers in the wild send their SSE stream chunked. So the GET stream runs on a
# raw Mojo::IOLoop connection: we send the request, strip the HTTP response
# headers, de-chunk if needed, and parse events with Mojo::SSE.

sub _open_sse_p ($self) {
  my $done = Mojo::Promise->new;
  my $s    = $self->{sse} = {ready => 0, promise => $done, raw => '', body => '', events => '', headers_done => 0};

  my $url  = Mojo::URL->new($self->{url});
  my $tls  = ($url->protocol // '') eq 'https' ? 1 : 0;
  my $host = $url->host;
  my $port = $url->port // ($tls ? 443 : 80);
  my $path = $url->path_query;
  $path = "/$path" unless $path =~ m{^/};

  $self->{sse}{conn} = Mojo::IOLoop->client({address => $host, port => $port, tls => $tls} => sub ($loop, $err, $stream) {
    return $self->_sse_resolve(0, "connect failed: $err") if $err;
    $self->{sse}{stream} = $stream;
    $stream->timeout(0);

    my @head = ("GET $path HTTP/1.1", "Host: $host", 'Accept: text/event-stream', 'Connection: keep-alive');
    push @head, "$_: $self->{headers}{$_}" for sort keys %{$self->{headers}};
    $stream->write(join("\r\n", @head) . "\r\n\r\n");

    $stream->on(read  => sub ($s, $bytes) { $self->_sse_read($bytes) });
    $stream->on(close => sub ($s)         { $self->_sse_closed });
    $stream->on(error => sub ($s, $e)     { $self->log->debug("[@{[$self->name]}] sse error: $e"); $self->_sse_closed });
  });

  # The wait for the endpoint belongs to this connect: the timer settles only
  # it, and goes when it settles (_sse_resolve) -- a stop settles it too
  # (_close_sse). Left behind, it rejected whichever connect was current when
  # it fired, a later one still waiting for its endpoint, and held the
  # upstream until then.
  $s->{timer} = Mojo::IOLoop->timer($self->request_timeout || 30 => sub {
    $self->_sse_resolve(0, 'timed out waiting for the SSE endpoint', $s);
  });

  return $done;
}

sub _sse_read ($self, $bytes) {
  my $s = $self->{sse};
  $s->{raw} .= $bytes;

  unless ($s->{headers_done}) {
    my $i = index($s->{raw}, "\r\n\r\n");
    return if $i < 0;
    my $head = substr($s->{raw}, 0, $i, '');
    substr($s->{raw}, 0, 4, '');
    $s->{chunked}      = $head =~ /transfer-encoding:\s*chunked/i ? 1 : 0;
    $s->{headers_done} = 1;
  }

  $s->{events} .= $s->{chunked} ? $self->_sse_dechunk : do { my $d = $s->{raw}; $s->{raw} = ''; $d };
  while (my $event = parse_event(\$s->{events})) { $self->_on_sse_event($event) }
}

sub _sse_dechunk ($self) {
  my $s   = $self->{sse};
  my $out = '';
  while ($s->{raw} =~ /^([0-9a-fA-F]+)[^\r\n]*\r\n/) {
    my $len    = hex $1;
    my $prefix = length($&);
    last if length($s->{raw}) < $prefix + $len + 2;    # chunk not fully arrived
    substr($s->{raw}, 0, $prefix, '');
    $out .= substr($s->{raw}, 0, $len, '');
    substr($s->{raw}, 0, 2, '');                       # trailing CRLF
    last if $len == 0;
  }
  return $out;
}

sub _on_sse_event ($self, $event) {
  if (($event->{type} // '') eq 'endpoint') {
    my $endpoint = Mojo::URL->new($event->{text})->to_abs(Mojo::URL->new($self->{url}));

    # The endpoint event may not move the JSON-RPC traffic -- and with it the
    # configured headers, the Authorization bearer among them -- to another
    # origin. The reference clients refuse such an endpoint too.
    if (my $reason = $self->_foreign_origin($endpoint)) {
      $self->log->error("[@{[$self->name]}] $reason");
      $self->{failure_reason} = $reason;
      return $self->_sse_resolve(0, $reason);
    }

    $self->{endpoint} = $endpoint->to_string;
    return $self->_sse_resolve(1);
  }
  my $msg = eval { from_json($event->{text} // '') };
  $self->_on_message($msg) if ref $msg eq 'HASH';
}

# The scheme, the host and the port of the endpoint have to be the ones of the
# configured URL. Returns the reason when they are not, undef when they are.
sub _foreign_origin ($self, $endpoint) {
  my $base   = Mojo::URL->new($self->{url});
  my $scheme = lc($endpoint->scheme // '');
  my $host   = lc($endpoint->host // '');
  return "SSE endpoint $endpoint is not an absolute URL" if $scheme eq '' || $host eq '';

  my $port      = $endpoint->port // ($scheme eq 'https' ? 443 : 80);
  my $base_port = $base->port // (lc($base->scheme // '') eq 'https' ? 443 : 80);
  return "SSE endpoint $endpoint does not match the configured origin $base"
    if $scheme ne lc($base->scheme // '') || $host ne lc($base->host // '') || $port != $base_port;
  return undef;
}

# Settles a connect, once: the current one, or the one $s names.
sub _sse_resolve ($self, $ok, $err = undef, $s = $self->{sse}) {
  return unless $s;
  return if $s->{ready}++;
  if (my $timer = delete $s->{timer}) { Mojo::IOLoop->remove($timer) }
  $ok ? $s->{promise}->resolve : $s->{promise}->reject("upstream @{[$self->name]}: $err");
}

sub _sse_closed ($self) {
  $self->_fail_pending("upstream @{[$self->name]}: SSE stream closed");
  $self->_sse_resolve(0, 'SSE stream closed before endpoint');
  $self->state('stopped') if !$self->{stopping} && $self->state eq 'ready';
  delete $self->{sse}{stream};
  return $self;
}

sub _sse_request_p ($self, $method, $params) {
  # Its answer comes back on the stream, so a request without the stream, or
  # without the endpoint to post it to, would wait for an answer that cannot
  # come -- request_timeout long, and with request_timeout 0 for good. A stop
  # takes both away, a remote that drops the stream that one. A request after
  # that -- the next one of a handshake a stop called off, say -- is rejected
  # at once instead of holding its start, or its call, until then.
  return Mojo::Promise->reject("upstream @{[$self->name]}: not connected")
    unless $self->{endpoint} && $self->{sse} && $self->{sse}{stream};

  my $id      = ++$self->{id};
  my $promise = Mojo::Promise->new;

  my $timer;
  if ((my $timeout = $self->request_timeout) > 0) {
    $timer = Mojo::IOLoop->timer($timeout => sub {
      my $pending = delete $self->{pending}{$id} or return;
      $pending->{promise}->reject("upstream @{[$self->name]}: timed out after ${timeout}s");
    });
  }
  $self->{pending}{$id} = {promise => $promise, timer => $timer};
  $self->_sse_post({jsonrpc => '2.0', id => $id, method => $method, params => $params});
  return $promise;
}

sub _sse_post ($self, $obj) {
  my $endpoint = $self->{endpoint} or return undef;
  $self->req_ua->post($endpoint => {%{$self->{headers}}, 'Content-Type' => 'application/json'} => json => $obj => sub { });
  return 1;
}

sub _on_message ($self, $msg) {
  return unless ref $msg eq 'HASH';

  if (exists $msg->{id} && !exists $msg->{method}) {
    my $pending = delete $self->{pending}{$msg->{id}} or return;
    Mojo::IOLoop->remove($pending->{timer}) if $pending->{timer};
    if (my $err = $msg->{error}) {
      $pending->{promise}->reject($self->_error_answer($err));
    }
    else { $pending->{promise}->resolve($msg->{result} // {}) }
    return;
  }

  if (exists $msg->{method} && defined $msg->{id}) {
    my ($method, $rid) = ($msg->{method}, $msg->{id});
    return $self->_sse_post({jsonrpc => '2.0', id => $rid, result => {}})            if $method eq 'ping';
    return $self->_sse_post({jsonrpc => '2.0', id => $rid, result => {roots => []}}) if $method eq 'roots/list';
    return $self->_sse_post({jsonrpc => '2.0', id => $rid,
      error => {code => -32601, message => 'Method not supported by mcp-hub'}});
  }

  if (exists $msg->{method} && $msg->{method} =~ m{^notifications/(?:tools|prompts|resources)/list_changed$}) {
    $self->refresh_p->catch(sub { });
  }
  return;
}

# --- helpers ---------------------------------------------------------------

sub _fail_pending ($self, $reason) {
  for my $id (keys %{$self->{pending}}) {
    my $pending = delete $self->{pending}{$id};
    Mojo::IOLoop->remove($pending->{timer}) if $pending->{timer};
    $pending->{promise}->reject($reason);

    # A Streamable HTTP POST still running goes with its connection. One that
    # is still connecting has none yet: it runs to its end, and its answer is
    # turned away (_http_send_p).
    my $tx = $pending->{tx};
    Mojo::IOLoop->remove($tx->connection) if $tx && $tx->connection && !$tx->is_finished;
  }
  return $self;
}

# The stream emits its close event inside close(), so the stopping flag marks
# exactly this close as deliberate (_sse_closed reads it) and is gone when we
# return. Left set, it would make a stream the remote drops later -- after a
# stop or a failed start, and a good start -- look deliberate too, and leave the
# upstream `ready` over a dead stream.
#
# A connect still waiting for its endpoint is settled here, at once and as
# stopped -- before its stream goes, whose close would settle it as closed.
# Nothing else is left to: the stream is closed and the connect removed, and
# its endpoint timer goes with it (_sse_resolve) instead of rejecting it as
# timed out request_timeout later and holding the upstream until then. The
# cleanup of a failed start finds its connect settled already.
sub _close_sse ($self) {
  local $self->{stopping} = 1;
  $self->_sse_resolve(0, 'stopped');
  if (my $stream = $self->{sse}{stream}) { $stream->close }
  if (my $conn   = $self->{sse}{conn})   { Mojo::IOLoop->remove($conn) }
  delete $self->{sse};
  delete $self->{endpoint};
  return $self;
}

# A failed start (a refused connection or a handshake that never completed) marks
# the upstream `failed` once FAIL_THRESHOLD of them land within FAIL_WINDOW
# seconds -- the stdio child's crash-loop rule, over connect failures instead of
# process exits. The reason of the last attempt (an endpoint on a foreign
# origin, say) is part of the message, so `mcp-hub status` says why.
sub _record_failure ($self) {
  my $now = time;
  push @{$self->{failures}}, $now;
  @{$self->{failures}} = grep { $_ >= $now - FAIL_WINDOW } @{$self->{failures}};
  return $self unless @{$self->{failures}} >= FAIL_THRESHOLD;
  $self->{failed} = 1;
  $self->error(scalar(@{$self->{failures}}) . ' connect failures within ' . FAIL_WINDOW . 's'
    . (defined $self->{failure_reason} ? ': ' . $self->{failure_reason} : ''));
  return $self;
}

sub _clear_failure ($self) {
  delete $self->{failed};
  delete $self->{failure_reason};
  @{$self->{failures}} = ();
  $self->error(undef);
  $self->state('stopped');
  return $self;
}

1;

=encoding utf8

=head1 SYNOPSIS

  use MCP::Hub::Upstream::Http;

  # Streamable HTTP
  my $up = MCP::Hub::Upstream::Http->new(
    name      => 'remote',
    config    => {type => 'http', url => 'https://example.com/mcp', headers => {Authorization => 'Bearer x'}},
    cache_dir => '~/.cache/mcp-hub',
  );

  # HTTP+SSE (legacy two-endpoint transport)
  my $sse = MCP::Hub::Upstream::Http->new(
    name   => 'crawl4ai',
    config => {type => 'sse', url => 'http://host:11235/mcp/sse'},
  );

=head1 DESCRIPTION

L<MCP::Hub::Upstream::Http> mounts a remote MCP server reached over HTTP as an
upstream, so the hub can front it just like a stdio or in-process server. It
speaks both HTTP transports in the wild:

=over 2

=item Streamable HTTP (C<type: "http">, the default for a C<url> entry)

A single endpoint. Each JSON-RPC request is a POST whose response is either a
JSON body or a short C<text/event-stream>. An C<Mcp-Session-Id> returned by
C<initialize> is echoed on later requests, and so is the protocol version it
negotiated, as C<MCP-Protocol-Version>; the C<initialize> itself carries
neither.

=item HTTP+SSE (C<type: "sse">)

The older two-endpoint transport: a long-lived C<GET> stream delivers an
C<endpoint> event naming the URL to POST messages to, and every JSON-RPC
response comes back as a C<message> event on that stream. This is what servers
exposing a C<< …/sse >> URL (such as crawl4ai) speak.

The C<endpoint> event has to name a URL on the same origin -- the same scheme,
host and port -- as the configured C<url>. The hub sends every request, with the
configured headers, to that endpoint, so an endpoint on another origin would
hand the JSON-RPC traffic and the upstream credential to a foreign host. Such an
endpoint is refused: the connect fails with that reason, it counts as a connect
failure like any other, and it is reported in L<MCP::Hub::Upstream/error>.

=back

Configured C<headers> (for example an C<Authorization> bearer) are sent with
every request but never logged and never mixed into the manifest hash. The
handshake, manifest cache and facade are shared with the other upstreams through
L<MCP::Hub::Upstream>; there is no subprocess, so there is no idle-stop or
restart lifecycle. A remote that will not connect is retried until it does, but
three connect failures within five seconds mark the upstream C<failed> -- with
the reason in L<MCP::Hub::Upstream/error>, a C<503> from its endpoint and a row
in C<mcp-hub status> -- so a permanently dead remote is reported instead of
reconnected on every call. L<MCP::Hub::Upstream/refresh_p> (C<mcp-hub refresh
NAME>) clears the failure and tries once more, mirroring the crash-loop handling
of L<MCP::Hub::Upstream::Stdio>.

A stop -- a configuration reload that replaces or removes the entry, or the
daemon shutting down -- calls off a start under way, on both transports: the
request of the start in flight is cut off, the next one is not sent, and the
start is rejected as C<upstream NAME: stopped> without counting as a connect
failure. A start asked for after the stop is a fresh one. It begins once the
start the stop called off has settled, so that two handshakes never run at
once, and whatever asks in the meantime shares it; a stop before it begins
calls it off too.

What a stop does to a call in flight depends on the transport. Over HTTP+SSE
the call fails as stopped: its answer would come on the stream, and the stop
closes the stream. Over Streamable HTTP a call on a ready upstream is left to
finish: its answer comes on its own POST, and the remote may already be
carrying it out. Nor does a call, or the next page of a refresh, go out in the
middle of a start there: a request that comes upon a start under way, and is
not one the start's handshake sends, waits for it and goes out on the session
it opens, or fails with it.

Over Streamable HTTP a stop also ends the session. Once no call is left on it,
one C<DELETE> to the endpoint with its C<Mcp-Session-Id> tells the remote that
the session is no longer needed. Nothing waits for it: a remote that answers
C<405> -- it does not let clients end sessions -- or cannot be reached is only
logged at debug level, and the connect and request timeouts of L</req_ua> bound
it. One sent as the daemon shuts down may not get out before the process ends.
A start that fails after the remote gave it a session ends that session the
same way, and so does a start that a stop calls off: an answer to its
C<initialize> that comes after the stop is turned away, but the session it
names is ended. The next start opens a new session: its C<initialize> carries
no session id.

A remote that has ended a session -- it restarted, or timed the session out --
answers C<404> to a request on it. The upstream leaves that session and opens a
new one, and sends the request once more, on it: the C<404> says it did not run
on the old one. Requests that lose the same session share one new session, and
none goes out a third time -- one whose new session ends too fails, and the
next call opens another. A request of a start is not sent again: the start
fails. No C<DELETE> goes out for a session the remote has ended, and a call
left to finish past a stop opens no new session; it fails, saying the remote
ended the session. A C<404> on a request without a session id -- a remote that
gives none, or a wrong C<url> -- is an error like any other.

An C<https> C<url> needs TLS in the perl the hub runs on: L<IO::Socket::SSL>
2.009 or newer, which L<Mojolicious> speaks TLS with, and C<MOJO_NO_TLS> unset.
Without it the constructor dies with a reason that says so, and the hub keeps
the entry as a C<failed> upstream carrying that reason -- the C<503> from its
endpoint and the row in C<mcp-hub status> name the fix. A retry or a refresh
cannot help, because Mojolicious decides about TLS once, at load time: install
the module and restart the daemon.

=head1 ATTRIBUTES

L<MCP::Hub::Upstream::Http> inherits all attributes from L<MCP::Hub::Upstream>
and adds:

=attr cache_dir

Where the manifest cache lives.

=attr req_ua

The L<Mojo::UserAgent> used for POSTs, with L<MCP::Hub::Upstream/request_timeout>
applied.

=attr ua

The L<Mojo::UserAgent> used for the long-lived SSE stream.

=head1 METHODS

L<MCP::Hub::Upstream::Http> inherits all methods from L<MCP::Hub::Upstream> and
adds:

=method apply_timeouts

As L<MCP::Hub::Upstream/apply_timeouts>, and additionally discards L</req_ua>,
which carries the request timeout it was built with.

=method transport

  my $mode = $up->transport;

C<http> for Streamable HTTP, C<sse> for HTTP+SSE.

=head1 SEE ALSO

L<MCP::Hub::Upstream>, L<MCP::Hub::Upstream::Stdio>, L<MCP::Hub>.

=cut
