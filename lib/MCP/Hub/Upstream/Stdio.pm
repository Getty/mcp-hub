package MCP::Hub::Upstream::Stdio;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Hub::Upstream', -signatures;

use MCP::Hub::Facade;
use MCP::Hub::Facade::Server;
use MCP::Hub::Manifest;
use Mojo::IOLoop;
use Mojo::IOLoop::Stream;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Promise;
use POSIX ();
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

# ABSTRACT: A stdio MCP child process mounted as an upstream

use constant MAX_LINE_BUFFER => 16 * 1024 * 1024;
use constant KILL_GRACE      => 5;

has cache_dir    => sub ($self) { $self->hub ? $self->hub->hub_config->cache_dir : '.' };

# The crash-loop window: three exits within it -- crashes or failed starts, not
# a deliberate stop -- mark the upstream `failed`. It has nothing to do with
# KILL_GRACE, the SIGTERM -> SIGKILL grace of stop; both are five seconds.
has fail_window  => 5;
has idle_timeout => 300;

sub new ($class, %args) {
  my $self = $class->SUPER::new(%args);
  my $c    = $self->config;

  $self->{manifest}         = MCP::Hub::Manifest->new(cache_dir => $self->cache_dir);
  $self->{idle_timeout}     = $c->{idle_timeout}    if defined $c->{idle_timeout};
  $self->{request_timeout}  = $c->{request_timeout} if defined $c->{request_timeout};
  $self->{id}               = 0;
  $self->{pending}          = {};
  $self->{inbuf}            = '';
  $self->{exits}            = [];

  $self->_build_server;
  return $self;
}

# --- public lifecycle ------------------------------------------------------

sub start_p ($self) {
  return Mojo::Promise->resolve($self) if $self->state eq 'ready' && $self->{pid};
  return $self->{start_promise} if $self->{start_promise};

  # A crash loop is left only by an explicit refresh: an ordinary call against a
  # failed upstream reports why instead of spawning the loop all over again.
  return Mojo::Promise->reject("upstream @{[$self->name]}: "
      . ($self->error // 'failed')
      . ", run 'mcp-hub refresh @{[$self->name]}' to try again")
    if $self->state eq 'failed';

  $self->state('starting');
  my $done = Mojo::Promise->new;
  $self->{start_promise} = $done;

  my $pid;
  unless (eval { $pid = $self->_spawn; 1 }) {
    my $err = $@ =~ s/\n\z//r;
    # A start refused before there is a child counts only if _spawn recorded
    # it (a forked worker refused for threads); then it may end a crash loop.
    $self->state($self->{failed} ? 'failed' : 'stopped');
    delete $self->{start_promise};
    $done->reject("upstream @{[$self->name]}: cannot start ($err)");
    return $done;
  }

  $self->_handshake_p->then(sub ($manifest) {
    $self->_apply_manifest($manifest);
    delete $self->{failed};    # a running child is never failed
    $self->error(undef);
    $self->state('ready');
    delete $self->{start_promise};
    $self->touch;
    $done->resolve($self);
  })->catch(sub ($err) {
    $self->log->error("[@{[$self->name]}] handshake failed: $err");

    # A child that died during the handshake was already counted by _on_close.
    # Counting it a second time here would lock the upstream out after two
    # attempts instead of three. The exit is only ours to record when the child
    # is still there -- a handshake timeout, say, which we kill ourselves.
    $self->_record_exit unless ($self->{exited_pid} // 0) == $pid;

    # The stopping flag means "this exit is deliberate" -- it may only be set
    # while there is a child to stop. Set for a child that is already gone, it
    # would make the next unexpected exit look deliberate: no warning, no
    # exit recorded.
    $self->{stopping} = 1 if $self->{pid};

    $self->_kill_now;
    $self->state($self->{failed} ? 'failed' : 'stopped');
    delete $self->{start_promise};
    $done->reject("$err");
    return;    # never hand the rejected promise back into the chain
  });

  return $done;
}

sub stop ($self) {
  return $self unless $self->{pid};
  $self->{stopping} = 1;
  $self->_clear_idle_timer;
  shutdown($self->{socket}, 1) if $self->{socket};    # SHUT_WR -> EOF on child stdin
  kill 'TERM', $self->{pid};
  $self->{kill_timer} = Mojo::IOLoop->timer(KILL_GRACE, sub {
    kill 'KILL', $self->{pid} if $self->{pid};
  });
  return $self;
}

sub refresh_p ($self) {
  if ($self->state eq 'ready' && $self->{pid}) {
    return $self->_list_all_p->then(sub ($lists) {
      $self->_apply_manifest($self->_manifest_from($lists));
      return $self;
    });
  }
  $self->_clear_failure if $self->state eq 'failed';
  return $self->start_p;
}

sub _clear_failure ($self) {
  delete $self->{failed};
  @{$self->{exits}} = ();
  $self->error(undef);
  $self->state('stopped');
  return $self;
}

sub touch ($self) {
  $self->last_used(time);
  $self->_arm_idle_timer if $self->state eq 'ready';
  return $self;
}

sub apply_timeouts ($self, $timeouts) {
  $self->SUPER::apply_timeouts($timeouts);
  return $self unless defined(my $idle = $timeouts->{idle_timeout});
  $self->idle_timeout($idle);
  # A running child is already counting down against the old value: drop that
  # timer and arm a fresh one, so the new timeout takes effect without waiting
  # for the next request -- and a timeout of 0 really does stop the countdown.
  return $self unless $self->state eq 'ready' && $self->{pid};
  $self->_clear_idle_timer;
  $self->_arm_idle_timer;
  return $self;
}

# --- manifest hash ---------------------------------------------------------

sub _hash ($self) {
  my $c = $self->config;
  return $self->{manifest}->hash($c->{command}, $c->{args}, $c->{cwd});
}

# --- JSON-RPC over the socket ----------------------------------------------

sub _request_p ($self, $method, $params = {}) {
  my $id      = ++$self->{id};
  my $promise = Mojo::Promise->new;

  my $timer;
  if ((my $timeout = $self->request_timeout) > 0) {
    $timer = Mojo::IOLoop->timer($timeout => sub {
      my $pending = delete $self->{pending}{$id} or return;
      $self->_send({jsonrpc => '2.0', method => 'notifications/cancelled', params => {requestId => $id}});
      $pending->{promise}->reject("upstream @{[$self->name]}: timed out after ${timeout}s");
    });
  }

  $self->{pending}{$id} = {promise => $promise, timer => $timer};
  $self->_send({jsonrpc => '2.0', id => $id, method => $method, params => $params});
  return $promise;
}

sub _notify ($self, $method, $params = {}) {
  return $self->_send({jsonrpc => '2.0', method => $method, params => $params});
}

sub _send ($self, $obj) {
  my $stream = $self->{stream} or return undef;
  $stream->write(encode_json($obj) . "\n");
  return 1;
}

# --- reading ---------------------------------------------------------------

sub _on_read ($self, $bytes) {
  $self->{inbuf} .= $bytes;
  if (length $self->{inbuf} > MAX_LINE_BUFFER) {
    $self->log->error("[@{[$self->name]}] line buffer exceeded 16MB, killing child");
    $self->{stopping} = 1;
    return $self->_kill_now;
  }
  while ((my $nl = index($self->{inbuf}, "\n")) >= 0) {
    my $line = substr($self->{inbuf}, 0, $nl + 1, '');
    $line =~ s/\r?\n\z//;
    next if $line eq '';
    $self->_on_message($line);
  }
}

sub _on_message ($self, $line) {
  my $msg = eval { decode_json($line) };
  return $self->log->debug("[@{[$self->name]}] skipping malformed line") unless ref $msg eq 'HASH';

  if (exists $msg->{id} && !exists $msg->{method}) { return $self->_on_response($msg) }
  if (exists $msg->{method} && defined $msg->{id}) { return $self->_on_server_request($msg) }
  if (exists $msg->{method})                        { return $self->_on_notification($msg) }
  return undef;
}

sub _on_response ($self, $msg) {
  my $pending = delete $self->{pending}{$msg->{id}}
    or return $self->log->debug("[@{[$self->name]}] response with unknown id @{[$msg->{id} // '?']}");
  Mojo::IOLoop->remove($pending->{timer}) if $pending->{timer};
  if (my $err = $msg->{error}) {
    $pending->{promise}->reject("upstream @{[$self->name]}: " . $self->_error_message($err));
  }
  else {
    $pending->{promise}->resolve($msg->{result} // {});
  }
}

sub _on_server_request ($self, $msg) {
  my ($method, $id) = ($msg->{method}, $msg->{id});
  return $self->_send({jsonrpc => '2.0', id => $id, result => {}})            if $method eq 'ping';
  return $self->_send({jsonrpc => '2.0', id => $id, result => {roots => []}}) if $method eq 'roots/list';
  return $self->_send({
    jsonrpc => '2.0',
    id      => $id,
    error   => {code => -32601, message => 'Method not supported by mcp-hub'},
  });
}

sub _on_notification ($self, $msg) {
  my $method = $msg->{method};

  if ($method =~ m{^notifications/(?:tools|prompts|resources)/list_changed$}) {
    $self->log->info("[@{[$self->name]}] $method received, refreshing manifest");
    $self->refresh_p->catch(sub ($err) { $self->log->debug("[@{[$self->name]}] refresh failed: $err") });
    return;
  }

  if ($method eq 'notifications/message') {
    my $params = $msg->{params} // {};
    my $level  = _log_level($params->{level} // 'info');
    my $data   = ref $params->{data} ? encode_json($params->{data}) : ($params->{data} // '');
    $self->log->$level("[@{[$self->name]}] $data");
    return;
  }

  # notifications/progress and anything else are dropped in v1.
  return undef;
}

sub _on_stderr ($self, $bytes) {
  for my $line (split /\n/, $bytes) {
    next unless length $line;
    $self->log->debug("[@{[$self->name]}] $line");
  }
}

sub _on_close ($self) {
  my $pid = $self->{pid} or return;    # already handled

  # Remember which pid this exit belongs to: the catch in start_p must not
  # count it a second time.
  $self->{exited_pid} = $pid;

  # Where SIGCHLD is ignored the kernel reaps the child itself and waitpid
  # fails with ECHILD, leaving $? at -1 -- which reads as "signal 127". The
  # exit status is simply unknown then.
  my $status = waitpid($pid, 0) > 0 ? $? : undef;
  Mojo::IOLoop->remove($self->{kill_timer}) if $self->{kill_timer};
  delete @{$self}{qw(kill_timer stream err_stream socket pid)};
  $self->stats->{pid} = undef;

  my $reason = _exit_reason($status);
  for my $id (keys %{$self->{pending}}) {
    my $pending = delete $self->{pending}{$id};
    Mojo::IOLoop->remove($pending->{timer}) if $pending->{timer};
    $pending->{promise}->reject("upstream @{[$self->name]}: exited ($reason)");
  }

  unless ($self->{stopping}) {
    $self->log->warn("[@{[$self->name]}] child exited ($reason)" . $self->_exit_hint($status));
    $self->_record_exit;
  }
  $self->_clear_idle_timer;
  $self->state($self->{failed} ? 'failed' : 'stopped');
  delete $self->{stopping};
  return $self;
}

# --- process ---------------------------------------------------------------

sub _spawn ($self) {
  my $c = $self->config;

  socketpair(my $parent, my $child, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!\n";
  pipe(my $err_r, my $err_w) or die "pipe: $!\n";
  $_->autoflush(1) for $parent, $child, $err_w;

  my $pid = fork // die "fork: $!\n";
  if (!$pid) {
    close $parent;
    close $err_r;
    open(STDIN,  '<&', $child)  or POSIX::_exit(127);
    open(STDOUT, '>&', $child)  or POSIX::_exit(127);
    open(STDERR, '>&', $err_w)  or POSIX::_exit(127);
    %ENV = (%ENV, %{$c->{env} // {}});
    if (defined $c->{cwd}) { chdir $c->{cwd} or POSIX::_exit(127) }
    { exec {$c->{command}} $c->{command}, @{$c->{args} // []} }
    POSIX::_exit(127);
  }

  close $child;
  close $err_w;
  $self->log->info("[@{[$self->name]}] started $c->{command} (pid $pid)");
  return $self->_attach($pid, $parent, $err_r);
}

# The hub's side of a child that was just started: its pid, and the hub's ends
# of its stdin/stdout socket and its stderr pipe, wired into the event loop.
sub _attach ($self, $pid, $parent, $err_r) {
  $self->{pid}               = $pid;
  $self->{socket}            = $parent;
  delete $self->{exited_pid};    # a new attempt, a new child
  $self->stats->{pid}        = $pid;
  $self->stats->{started_at} = time;

  my $stream = Mojo::IOLoop::Stream->new($parent);
  $stream->timeout(0);
  $stream->on(read  => sub ($s, $bytes) { $self->_on_read($bytes) });
  $stream->on(close => sub ($s)         { $self->_on_close });
  $stream->on(error => sub ($s, $err)   { $self->log->debug("[@{[$self->name]}] socket error: $err"); $self->_on_close });
  $stream->start;
  $self->{stream} = $stream;

  my $estream = Mojo::IOLoop::Stream->new($err_r);
  $estream->timeout(0);
  $estream->on(read  => sub ($s, $bytes) { $self->_on_stderr($bytes) });
  $estream->on(error => sub { });
  $estream->on(close => sub { });
  $estream->start;
  $self->{err_stream} = $estream;

  return $pid;
}

sub _kill_now ($self) {
  $self->_clear_idle_timer;
  Mojo::IOLoop->remove($self->{kill_timer}) if $self->{kill_timer};
  kill 'KILL', $self->{pid} if $self->{pid};
  return $self;
}

sub _record_exit ($self) {
  my $now    = time;
  my $window = $self->fail_window;
  push @{$self->{exits}}, $now;
  @{$self->{exits}} = grep { $_ >= $now - $window } @{$self->{exits}};
  return $self unless @{$self->{exits}} >= 3;
  $self->{failed} = 1;
  $self->error(scalar(@{$self->{exits}}) . ' exits within ' . $window . 's');
  return $self;
}

# --- idle timer ------------------------------------------------------------

sub _arm_idle_timer ($self) {
  return if $self->always_on;
  my $timeout = $self->idle_timeout;
  return unless $timeout > 0;
  $self->_clear_idle_timer;
  $self->{idle_timer} = Mojo::IOLoop->timer($timeout => sub {
    $self->log->info("[@{[$self->name]}] idle for ${timeout}s, stopping");
    $self->stop;
  });
  return $self;
}

sub _clear_idle_timer ($self) {
  Mojo::IOLoop->remove($self->{idle_timer}) if $self->{idle_timer};
  delete $self->{idle_timer};
  return $self;
}

# --- helpers ---------------------------------------------------------------

# A child that dies before the handshake is done is a configuration problem, so
# name the command: "exited (code 127)" on its own sends everyone hunting in the
# wrong place. Exit 127 is what the child _exit()s with when exec fails.
sub _exit_hint ($self, $status) {
  return '' unless $self->state eq 'starting';
  my $command = $self->config->{command} // '?';
  return " while starting '$command' -- is it installed and executable?"
    if defined $status && !($status & 127) && ($status >> 8) == 127;
  return " while starting '$command'";
}

sub _exit_reason ($status) {
  return 'unknown' unless defined $status;
  my $signal = $status & 127;
  return "signal $signal" if $signal;
  return 'code ' . ($status >> 8);
}

sub _log_level ($level) {
  state $map = {
    debug => 'debug', info => 'info', notice => 'info', warning => 'warn',
    error => 'error', critical => 'error', alert => 'error', emergency => 'fatal',
  };
  return $map->{$level} // 'info';
}

1;

=encoding utf8

=head1 SYNOPSIS

  use MCP::Hub::Upstream::Stdio;

  my $up = MCP::Hub::Upstream::Stdio->new(
    name      => 'context7',
    config    => {type => 'stdio', command => 'npx', args => ['-y', '@upstash/context7-mcp']},
    cache_dir => '~/.cache/mcp-hub',
  );

  $up->call_tool('resolve-library-id', {libraryName => 'react'})->then(sub ($result) { ... });

=head1 DESCRIPTION

L<MCP::Hub::Upstream::Stdio> runs a stdio MCP server as a child process and
speaks the classic (legacy) JSON-RPC handshake to it, so it can talk to the
npm and Python servers in the wild that do not speak the current stateless
revision.

The child's stdin and stdout are a single C<AF_UNIX> socket pair wrapped in a
L<Mojo::IOLoop::Stream>, its stderr a pipe logged at C<debug>. All requests are
non-blocking promises, correlated by an integer id, with a per-request timeout
that rejects the promise and sends C<notifications/cancelled>.

=head2 Lifecycle

The child is B<lazily> started: at daemon start a fresh cached manifest is
enough to answer C<tools/list>, and nothing is spawned until the first
C<tools/call>, C<prompts/get> or C<resources/read>. It is stopped again after
L</idle_timeout> seconds of no requests (unless
L<MCP::Hub::Upstream/always_on>), and restarted on the next call.

Three exits within five seconds mark it C<failed>, with the reason in
L<MCP::Hub::Upstream/error>. A failed upstream stays failed until it is
refreshed: further calls are answered with that reason rather than spawning the
crash loop again, and its endpoint answers C<503>. L<MCP::Hub::Upstream/refresh_p>
-- C<mcp-hub refresh NAME>, or the C<hub_refresh> tool -- clears the failure and
the exit history and tries once more; a successful start makes it C<ready>
again, and a later idle stop leaves it C<stopped>.

=head2 Handshake and manifest

On start the upstream sends C<initialize> (protocol C<2025-06-18>),
C<notifications/initialized>, then C<tools/list> (following C<nextCursor>) and,
when the capabilities declare them, C<prompts/list> and C<resources/list>. The
result is written to the manifest cache and turned into the L<MCP::Server> via
L<MCP::Hub::Facade>. A C<notifications/*/list_changed> from the child triggers a
background refresh.

=head1 ATTRIBUTES

L<MCP::Hub::Upstream::Stdio> inherits all attributes from L<MCP::Hub::Upstream>
and adds:

=attr cache_dir

Where the manifest cache lives.

=attr fail_window

Seconds within which three exits -- crashes or failed starts, not a
deliberate stop -- mark the upstream C<failed>; see L</Lifecycle>. Defaults to
C<5>.

=attr idle_timeout

Seconds of no requests before the child is stopped. Defaults to C<300>.

=head1 METHODS

L<MCP::Hub::Upstream::Stdio> inherits all methods from L<MCP::Hub::Upstream> and
implements the lifecycle -- L<MCP::Hub::Upstream/start_p>,
L<MCP::Hub::Upstream/stop>, L<MCP::Hub::Upstream/refresh_p>,
L<MCP::Hub::Upstream/touch> and L<MCP::Hub::Upstream/apply_timeouts> (which
re-arms a running child's idle timer) -- for a child process. The forwarding methods the
facade calls (C<call_tool>, C<get_prompt>, C<read_resource>) are the inherited
ones.

=head1 SEE ALSO

L<MCP::Hub::Upstream>, L<MCP::Hub::Facade>, L<MCP::Hub::Manifest>.

=cut
