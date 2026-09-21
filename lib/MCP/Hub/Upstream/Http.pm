package MCP::Hub::Upstream::Http;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Hub::Upstream', -signatures;

use MCP::Hub::Manifest;
use Mojo::IOLoop;
use Mojo::JSON qw(from_json);
use Mojo::Promise;
use Mojo::SSE qw(parse_event);
use Mojo::URL;
use Mojo::UserAgent;

# ABSTRACT: An HTTP MCP server (Streamable HTTP or HTTP+SSE) mounted as an upstream

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

  $self->{request_timeout} = $c->{request_timeout} if defined $c->{request_timeout};
  $self->{manifest}        = MCP::Hub::Manifest->new(cache_dir => $self->cache_dir);
  $self->{transport}       = ($c->{type} // '') eq 'sse' ? 'sse' : 'http';
  $self->{url}             = $c->{url};
  $self->{headers}         = $c->{headers} // {};
  $self->{id}              = 0;
  $self->{pending}         = {};

  $self->_build_server;
  return $self;
}

sub transport ($self) { return $self->{transport} }

# --- lifecycle -------------------------------------------------------------

sub start_p ($self) {
  return Mojo::Promise->resolve($self) if $self->state eq 'ready';
  return $self->{start_promise} if $self->{start_promise};

  $self->state('starting');
  my $done = Mojo::Promise->new;
  $self->{start_promise} = $done;

  my $prep = $self->{transport} eq 'sse' ? $self->_open_sse_p : Mojo::Promise->resolve;
  $prep->then(sub { $self->_handshake_p })->then(sub ($manifest) {
    $self->_apply_manifest($manifest);
    $self->state('ready');
    delete $self->{start_promise};
    $self->touch;
    $done->resolve($self);
  })->catch(sub ($err) {
    $self->log->error("[@{[$self->name]}] handshake failed: $err");
    $self->_close_sse;
    $self->state('stopped');
    delete $self->{start_promise};
    $done->reject("$err");
    return;    # never hand the rejected promise back into the chain
  });

  return $done;
}

sub stop ($self) {
  $self->_close_sse;
  $self->_fail_pending("upstream @{[$self->name]}: stopped");
  $self->state('stopped');
  return $self;
}

sub refresh_p ($self) {
  return $self->start_p unless $self->state eq 'ready';
  return $self->_list_all_p
    ->then(sub ($lists) { $self->_apply_manifest($self->_manifest_from($lists)); return $self })
    ->catch(sub ($err) { $self->log->debug("[@{[$self->name]}] refresh failed: $err"); return $self });
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

sub _request_p ($self, $method, $params = {}) {
  return $self->{transport} eq 'sse'
    ? $self->_sse_request_p($method, $params)
    : $self->_http_request_p($method, $params);
}

sub _notify ($self, $method, $params = {}) {
  my $obj = {jsonrpc => '2.0', method => $method, params => $params};
  return $self->{transport} eq 'sse' ? $self->_sse_post($obj) : $self->_http_post($obj);
}

# --- Streamable HTTP (single endpoint, response on the POST) ---------------

sub _http_request_p ($self, $method, $params) {
  my $id  = ++$self->{id};
  my $req = {jsonrpc => '2.0', id => $id, method => $method, params => $params};

  # The response is either a JSON body or a text/event-stream. Mojo parses SSE
  # into events (leaving the body empty), so capture our reply from the sse
  # event stream; a plain JSON reply is read from the body once the tx is done.
  my $tx    = $self->req_ua->build_tx(POST => $self->{url} => $self->_http_headers => json => $req);
  my $found;
  $tx->res->content->on(sse => sub ($content, $event = undef) {
    return unless $event && defined $event->{text};
    my $msg = eval { from_json($event->{text}) };
    $found = $msg if ref $msg eq 'HASH' && exists $msg->{id} && ($msg->{id} // '') eq $id;
  });

  return $self->req_ua->start_p($tx)->then(sub ($tx) {
    if (my $err = $tx->error) {
      die "upstream @{[$self->name]}: " . ($err->{message} // 'error') . "\n" unless $found;
    }
    if (my $sid = $tx->res->headers->header('Mcp-Session-Id')) { $self->{session_id} = $sid }

    # $found is set when Mojo parsed the SSE inline (non-chunked). Otherwise the
    # reply is a plain JSON body, or -- for a chunked event-stream, which Mojo
    # does not SSE-parse -- the de-chunked events sit in the body; parse those.
    my $res = $found // _reply_from_body($tx, $id);
    die "upstream @{[$self->name]}: no response for $method\n" unless ref $res eq 'HASH';
    die "upstream @{[$self->name]}: " . ($res->{error}{message} // 'error') . "\n" if $res->{error};
    return $res->{result} // {};
  });
}

sub _http_post ($self, $obj) {
  $self->req_ua->start($self->req_ua->build_tx(POST => $self->{url} => $self->_http_headers => json => $obj) => sub { });
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

sub _http_headers ($self) {
  return {
    %{$self->{headers}},
    'Content-Type'         => 'application/json',
    'Accept'               => 'application/json, text/event-stream',
    'MCP-Protocol-Version' => $self->{server_protocol} // $self->protocol_version,
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
  $self->{sse}          = {ready => 0, promise => $done, raw => '', body => '', events => '', headers_done => 0};

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

  Mojo::IOLoop->timer($self->request_timeout || 30 => sub {
    $self->_sse_resolve(0, 'timed out waiting for the SSE endpoint');
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
    $self->{endpoint} = Mojo::URL->new($event->{text})->to_abs(Mojo::URL->new($self->{url}))->to_string;
    return $self->_sse_resolve(1);
  }
  my $msg = eval { from_json($event->{text} // '') };
  $self->_on_message($msg) if ref $msg eq 'HASH';
}

sub _sse_resolve ($self, $ok, $err = undef) {
  my $s = $self->{sse} or return;
  return if $s->{ready}++;
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
      $pending->{promise}->reject("upstream @{[$self->name]}: " . ($err->{message} // 'error'));
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
  }
  return $self;
}

sub _close_sse ($self) {
  $self->{stopping} = 1;
  if (my $stream = $self->{sse}{stream}) { $stream->close }
  if (my $conn   = $self->{sse}{conn})   { Mojo::IOLoop->remove($conn) }
  delete $self->{sse};
  delete $self->{endpoint};
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
C<initialize> is echoed on later requests.

=item HTTP+SSE (C<type: "sse">)

The older two-endpoint transport: a long-lived C<GET> stream delivers an
C<endpoint> event naming the URL to POST messages to, and every JSON-RPC
response comes back as a C<message> event on that stream. This is what servers
exposing a C<< …/sse >> URL (such as crawl4ai) speak.

=back

Configured C<headers> (for example an C<Authorization> bearer) are sent with
every request but never logged and never mixed into the manifest hash. The
handshake, manifest cache and facade are shared with the other upstreams through
L<MCP::Hub::Upstream>; there is no subprocess, so there is no idle-stop, crash or
restart lifecycle.

=head1 ATTRIBUTES

L<MCP::Hub::Upstream::Http> inherits all attributes from L<MCP::Hub::Upstream>
and adds:

=head2 cache_dir

Where the manifest cache lives.

=head2 req_ua

The L<Mojo::UserAgent> used for POSTs, with L<MCP::Hub::Upstream/request_timeout>
applied.

=head2 ua

The L<Mojo::UserAgent> used for the long-lived SSE stream.

=head1 METHODS

L<MCP::Hub::Upstream::Http> inherits all methods from L<MCP::Hub::Upstream> and
adds:

=head2 apply_timeouts

As L<MCP::Hub::Upstream/apply_timeouts>, and additionally discards L</req_ua>,
which carries the request timeout it was built with.

=head2 transport

  my $mode = $up->transport;

C<http> for Streamable HTTP, C<sse> for HTTP+SSE.

=head1 SEE ALSO

L<MCP::Hub::Upstream>, L<MCP::Hub::Upstream::Stdio>, L<MCP::Hub>.

=cut
