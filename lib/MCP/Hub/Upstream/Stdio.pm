package MCP::Hub::Upstream::Stdio;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Hub::Upstream', -signatures;

use MCP::Hub::Child qw(child_env close_inherited_fds watch_exit);
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

# A stop closes the child's stdin and waits EOF_GRACE seconds for it to exit
# on its own, then sends SIGTERM, and SIGKILL KILL_GRACE seconds after that.
use constant EOF_GRACE  => 2;
use constant KILL_GRACE => 5;

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
  return $self->{start_promise} if $self->{start_promise};

  # One child at a time. One on its way out -- being stopped, killed after its
  # start failed, or its socket closed -- is waited for: a call must not go to
  # it, and the next child must not move in before its exit is handled.
  return $self->_gone_p->then(sub { $self->start_p }) if $self->_leaving;
  return Mojo::Promise->resolve($self) if $self->state eq 'ready' && $self->{pid};

  # A crash loop is left only by an explicit refresh: an ordinary call against a
  # failed upstream reports why instead of spawning the loop all over again.
  return Mojo::Promise->reject($self->_failed_message) if $self->state eq 'failed';

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

  # A child that is gone by the end of the handshake fails the start, with the
  # reason of its exit: a list it no longer answered was taken for an empty
  # one (_list_all_p), and the upstream would be ready with no child to call.
  # One that has only closed its stdout so far is waited for, as a request it
  # leaves unanswered is (_on_close, _on_exit). One that a stop has sent EOF
  # fails it as stopped.
  my $child = $self->{child};
  $self->_handshake_p->then(sub ($manifest) {
    return $manifest unless $child->{closed} || $child->{eof};
    return Mojo::Promise->reject("upstream @{[$self->name]}: stopped") if $child->{eof};
    my $exited = sub { Mojo::Promise->reject("upstream @{[$self->name]}: $child->{exited}") };
    return defined $child->{exited} ? $exited->() : $self->_gone_p->then($exited);
  })->then(sub ($manifest) {
    $self->_apply_manifest($manifest);
    delete $self->{failed};    # a running child is never failed
    $self->error(undef);
    $self->state('ready');
    delete $self->{start_promise};
    $self->touch;
    $done->resolve($self);
  })->catch(sub ($err) {
    # A start that a stop called off -- the child has been sent EOF -- did not
    # fail: it is logged at debug, as over HTTP (MCP::Hub::Upstream::Http), not
    # as a failed handshake, and it is rejected as stopped, whatever the
    # handshake ended with: its next request failed at once (_request_p), or
    # the one in flight with the child's exit, when the child ended on its EOF
    # before it answered (_on_exit).
    my $stopped = $child->{eof};
    $stopped
      ? $self->log->debug("[@{[$self->name]}] start called off by a stop")
      : $self->log->error("[@{[$self->name]}] handshake failed: $err");

    # A child that died during the handshake was already counted by _on_close.
    # Counting it a second time here would lock the upstream out after two
    # attempts instead of three. The exit is only ours to record when the child
    # is still there -- a handshake timeout, say, which we kill ourselves.
    # Not so for a child a stop has sent EOF: the stop is no failed start, and
    # goes on as any stop -- a child that ends on its EOF is never signalled.
    $self->_record_exit unless ($self->{exited_pid} // 0) == $pid || $stopped;

    # The stopping flag means "this exit is deliberate" -- it may only be set
    # while there is a child to stop. Set for a child that is already gone, it
    # would make the next unexpected exit look deliberate: no warning, no
    # exit recorded.
    $self->{stopping} = 1 if $self->{pid};

    $self->_kill_now unless $stopped;
    $self->state($self->{failed} ? 'failed' : 'stopped');
    delete $self->{start_promise};
    $done->reject($stopped ? "upstream @{[$self->name]}: stopped" : "$err");
    return;    # never hand the rejected promise back into the chain
  });

  return $done;
}

# End of input first: a stdio server exits on EOF, and one that does is never
# signalled -- whatever it is in the middle of, a git commit say, it gets to
# finish. One still there EOF_GRACE seconds later gets SIGTERM, then SIGKILL.
# A stop already under way is neither started over nor hurried, and a child
# being killed needs none.
sub stop ($self) {
  return $self unless $self->{pid};
  my $child = $self->{child};
  $self->{stopping} = 1;
  $self->_clear_idle_timer;
  return $self if $child->{stop} || $child->{killed};
  shutdown($self->{socket}, 1) if $self->{socket};    # SHUT_WR -> EOF on child stdin
  $child->{eof}  = 1;
  $child->{stop} = Mojo::IOLoop->timer(EOF_GRACE, sub { $self->_terminate($child) });
  return $self;
}

# Resolves once the child is gone -- after a stop, within EOF_GRACE and
# KILL_GRACE seconds. A shutdown waits for it: a child that stays on after its
# EOF is still to be signalled, by this loop.
sub stopped_p ($self) {
  return Mojo::Promise->resolve($self) unless $self->{pid};
  return $self->_gone_p->then(sub { $self });
}

sub refresh_p ($self) {
  # The running child is asked for its lists again, in flight like a call: an
  # idle stop between two of them would refuse the next (_held_p). All of them
  # are asked of that child, and of no other (_request_p).
  if ($self->state eq 'ready' && $self->{pid}) {
    return $self->_held_p($self->_list_all_p(0, $self->{child})->then(sub ($lists) {
      $self->_apply_manifest($self->_manifest_from($lists));
      return $self;
    }));
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

# --- manifest hash ---------------------------------------------------------

sub _hash ($self) {
  my $c = $self->config;
  return $self->{manifest}->hash($c->{command}, $c->{args}, $c->{cwd});
}

# --- JSON-RPC over the socket ----------------------------------------------

# A request of a start's handshake goes to the child like any other. One of a
# refresh is bound to the child the refresh began on ($child), and fails at once
# when that child is no longer the one running, or has been sent EOF. The loop
# may handle the child's exit -- and a call that starts the next child --
# between the answer to one list and the request for the next. Unbound, the
# rest of the refresh would go to the next child, and its lists be taken for
# those of the one before.
#
# Any request the child can no longer be sent (_refused) fails at once, with
# the reason. Unsent, it would wait for an answer that cannot come: out the
# request timeout, or -- with the child still there -- until its exit.
sub _request_p ($self, $method, $params = {}, $of_start = 0, $child = undef) {
  return Mojo::Promise->reject("upstream @{[$self->name]}: the child the refresh began on is gone")
    if $child && !($self->{child} && $self->{child} == $child && !$child->{eof});
  if (defined(my $why = $self->_refused)) { return Mojo::Promise->reject("upstream @{[$self->name]}: $why") }

  my $id      = ++$self->{id};
  my $promise = Mojo::Promise->new;

  # One that times out goes on in the child unless it is cancelled there: with
  # its id and the reason it was rejected with, as over HTTP
  # (MCP::Hub::Upstream::Http::_cancel). Never the initialize, which a client
  # must not cancel (MCP 2025-06-18, Cancellation).
  my $timer;
  if ((my $timeout = $self->request_timeout) > 0) {
    $timer = Mojo::IOLoop->timer($timeout => sub {
      my $pending = delete $self->{pending}{$id} or return;
      my $why     = "timed out after ${timeout}s";
      $self->_notify('notifications/cancelled', {requestId => $id, reason => $why}) unless $method eq 'initialize';
      $pending->{promise}->reject("upstream @{[$self->name]}: $why");
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
  return undef if defined $self->_refused;
  $self->{stream}->write(encode_json($obj) . "\n");
  return 1;
}

# Why nothing can be sent to the child now, or undef when it can be: there is
# no stream to it -- no child, or one that closed its stdout -- or it has been
# sent EOF. Not to a child that has: the write would fail, and the error close
# the socket -- with whatever the child still has to say unread.
sub _refused ($self) {
  return 'not connected' unless $self->{stream};
  return 'stopped' if $self->{child} && $self->{child}{eof};
  return undef;
}

# --- reading ---------------------------------------------------------------

sub _on_read ($self, $bytes) {
  # A child over the limit is being killed: the rest of what it sent is let go
  # of, and the buffer with it -- the next child starts on an empty one.
  return if $self->{child} && $self->{child}{overflow};
  $self->{inbuf} .= $bytes;
  if (length $self->{inbuf} > MAX_LINE_BUFFER) {
    $self->log->error("[@{[$self->name]}] line buffer exceeded 16MB, killing child");
    $self->{inbuf} = '';
    $self->{child}{overflow} = 1 if $self->{child};
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
    $pending->{promise}->reject($self->_error_answer($err));
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

# The child's stdout and its stderr end together, and the loop may see the end
# of stdout -- and the exit -- first, under load, with all ready at once. What
# it wrote last is often why it died: Docker's own message, a worker's
# constructor dying. So what is still in the pipe is read before the exit is
# handled, up to 1 MB and without blocking: a process that lingers on the
# pipe, writing on, is not waited for.
sub _drain_stderr ($self) {
  my $handle = $self->{err_stream} && $self->{err_stream}->handle or return $self;
  $handle->blocking(0);
  my $bytes = '';
  for (1 .. 16) {
    last unless sysread $handle, my $chunk, 65536;
    $bytes .= $chunk;
  }
  $self->_on_stderr($bytes) if length $bytes;
  return $self;
}

# The child's end of the socket is closed: the child is gone, or going. Its
# exit is handled once its status is in as well (_on_exit) -- nothing here
# waits for it, the one loop runs on.
sub _on_close ($self) {
  my ($pid, $child) = @{$self}{qw(pid child)};
  return $self unless $pid && $child;     # already handled
  return $self if $child->{closed}++;     # the error event comes here too
  delete $self->{stream};
  return $self->_on_exit($child->{status}) if $child->{reaped};

  $child->{collect}->();    # may find it exited, and handle that, right away
  return $self if $child->{reaped} || $self->{stopping};

  # A child that has closed its stdout but lives on can never answer again.
  # It gets the grace a stop gives after its SIGTERM, then it is killed.
  $child->{linger} = Mojo::IOLoop->timer(KILL_GRACE, sub {
    return if $child->{reaped} || ($self->{pid} // 0) != $pid;
    $self->log->warn("[@{[$self->name]}] closed its stdout @{[KILL_GRACE]}s ago and still runs, killing it");
    kill 'KILL', $pid;
  });
  return $self;
}

# The status of the child is in. Under EV that can be before its socket
# closes: a process it started may hold the socket -- and serve on it.
sub _on_reaped ($self, $child, $status) {
  return $self unless $self->{child} && $self->{child} == $child;
  @{$child}{qw(reaped status)} = (1, $status);
  return $self->_on_exit($status) if $child->{closed};

  # Killed, there is nothing of it left to wait for: the socket is let go of.
  return $child->{killed} ? $self->_hang_up : $self;
}

# The child is gone: its socket closed and its status in -- the status as
# waitpid leaves it in $?, or undef where it is unknown.
sub _on_exit ($self, $status) {
  my $pid = $self->{pid} or return $self;    # already handled

  # Remember which pid this exit belongs to: the catch in start_p must not
  # count it a second time.
  $self->{exited_pid} = $pid;

  # Its last words, before the exit is reported (and the pipe dropped).
  $self->_drain_stderr;

  my $child = delete $self->{child} // {};
  Mojo::IOLoop->remove($_) for grep {defined} @{$child}{qw(stop linger)};
  delete @{$self}{qw(stream err_stream socket pid)};
  $self->stats->{pid} = undef;

  # The reason the requests it leaves unanswered fail with -- a failed start's
  # among them, which a 503 and the status show -- carries the hint for an
  # exec that failed, like the log line. A start whose lists it was gone for
  # fails with it too (start_p).
  my $reason = _exit_reason($status);
  my $why    = $child->{exited} = "exited ($reason)" . $self->_exec_hint($status);
  for my $id (keys %{$self->{pending}}) {
    my $pending = delete $self->{pending}{$id};
    Mojo::IOLoop->remove($pending->{timer}) if $pending->{timer};
    $pending->{promise}->reject("upstream @{[$self->name]}: $why");
  }

  unless ($self->{stopping}) {
    $self->log->warn("[@{[$self->name]}] child exited ($reason)" . $self->_exit_hint($status));
    $self->_record_exit;
  }
  $self->_clear_idle_timer;
  $self->state($self->{failed} ? 'failed' : 'stopped');
  delete $self->{stopping};
  if (my $gone = delete $self->{gone_promise}) { $gone->resolve }
  return $self;
}

# Whether the child there is now is on its way out: its exit not handled yet,
# though it is being stopped, its socket is closed, or its start has failed.
sub _leaving ($self) {
  return $self->{pid} && ($self->{stopping} || $self->{child}{closed} || $self->state ne 'ready') ? 1 : 0;
}

# Resolves once the exit of the child there is now has been handled.
sub _gone_p ($self) { return $self->{gone_promise} //= Mojo::Promise->new }

sub _hang_up ($self) {
  $self->{stream}->close if $self->{stream};    # -> _on_close
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
    close_inherited_fds();    # the hub's listening socket among them
    %ENV = child_env($c->{env});    # less the MOJO_REUSE that names those fds
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

  # And a new line buffer: what the last child left of a line when it died
  # would go in front of this one's first.
  $self->{inbuf} = '';

  # How this child ends -- its socket closed, its status in, killed -- and the
  # watch for its status, set up at once: under EV the status goes to whoever
  # watches by the time libev reaps it (MCP::Hub::Child).
  my $child = $self->{child} = {};
  $child->{collect} = watch_exit($pid, sub ($status) { $self->_on_reaped($child, $status) });

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

# The child did not exit on EOF: SIGTERM, and SIGKILL if that does not end it
# either. A child reaped already gets no signal -- its pid may be another
# process's by now.
sub _terminate ($self, $child) {
  return $self unless $self->{child} && $self->{child} == $child;
  kill 'TERM', $self->{pid} unless $child->{reaped};
  $child->{stop} = Mojo::IOLoop->timer(KILL_GRACE, sub {
    $self->_kill_now if $self->{child} && $self->{child} == $child;
  });
  return $self;
}

sub _kill_now ($self) {
  $self->_clear_idle_timer;
  my $child = $self->{child} or return $self;
  Mojo::IOLoop->remove($child->{stop}) if $child->{stop};
  $child->{killed} = 1;

  # Reaped already, a process it started holding its socket: there is no pid
  # left to signal, and letting go of the socket is what ends it.
  return $self->_hang_up if $child->{reaped};
  kill 'KILL', $self->{pid};
  $child->{collect}->();    # such a process may keep the socket from closing
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

# --- helpers ---------------------------------------------------------------

# A child that dies before the handshake is done is a configuration problem, so
# name the command: "exited (code 127)" on its own sends everyone hunting in the
# wrong place.
sub _exit_hint ($self, $status) {
  return '' unless $self->state eq 'starting';
  return $self->_exec_hint($status) || " while starting '@{[$self->config->{command} // '?']}'";
}

# Exit 127 while starting is what the child _exit()s with when exec fails.
# This hint goes into the reason a failed start gives too, not only the log.
sub _exec_hint ($self, $status) {
  return '' unless $self->state eq 'starting' && defined $status && !($status & 127) && ($status >> 8) == 127;
  return " while starting '@{[$self->config->{command} // '?']}' -- is it installed and executable?";
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
L<Mojo::IOLoop::Stream>, its stderr a pipe logged at C<debug> -- read to the end
(up to 1 MB) before the child's exit is handled, so that the last lines it wrote
are logged even when the end of its stdout is seen first; every other fd it
inherited from the hub is closed before the exec (L<MCP::Hub::Child>). All
requests are non-blocking promises, correlated by an integer id, with a
per-request timeout (L<MCP::Hub::Upstream/request_timeout>) that rejects the
promise as C<upstream NAME: timed out after Ns> and cancels the request in the
child: a C<notifications/cancelled> with its id and that reason, as over HTTP.
Never the C<initialize>, which a client must not cancel (MCP 2025-06-18).

=head2 Lifecycle

The child is B<lazily> started: at daemon start a fresh cached manifest is
enough to answer C<tools/list>, and nothing is spawned until the first
C<tools/call>, C<prompts/get> or C<resources/read>. It is stopped again
L</idle_timeout> seconds after its last request ended -- never while one is in
flight, however long it runs, nor while a refresh asks it for its lists --
unless L<MCP::Hub::Upstream/always_on>, and restarted on the next call.

A stop closes the child's stdin and gives it two seconds to exit on its own, as
a stdio server does at the end of its input. A child that does is never sent a
signal, so whatever it was in the middle of -- a git commit, say -- is finished.
One that is still there gets C<SIGTERM>, and C<SIGKILL> five seconds after that.
A call that comes in meanwhile waits for it to be gone and starts the next
child: the hub runs one child at a time. L<MCP::Hub::Upstream/stopped_p>
resolves once it is gone, and the daemon waits for that on shutdown. A child
that closes its stdout but goes on running can never answer again, and is
killed after five seconds. Its exit status is collected without blocking the
event loop, under L<Mojo::Reactor::EV> too (L<MCP::Hub::Child/watch_exit>).

A request that can no longer reach the child -- a call let through just before
a stop sent it EOF, or one after its stdout closed -- is not sent: it fails at
once, as C<upstream NAME: stopped> or C<upstream NAME: not connected>, instead
of waiting out the request timeout. A stop during a start fails the start as
C<stopped>, whatever step of it the stop cut short, as over HTTP: at once when
the next request of the start is not sent, else once the request in flight is
answered or the child is gone -- a child that ends on its EOF before it answers
fails the start as C<stopped> too, not as C<exited>. It does not count toward
the crash loop, it is logged at debug level -- as a start called off, not a
failed handshake -- and the child is left to the stop: one that ends on its EOF
is never signalled. A start that fails on its own is logged at error level.

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

A C<prompts/list> or C<resources/list> the child answers with an error is an
empty list. One it does not answer -- it times out, a stop cuts it off, the
child exits -- fails a refresh, and the manifest stays as it was; a start takes
it for an empty list (L<MCP::Hub::Upstream/refresh_p>). But a child that is gone
by the end of the handshake fails the start all the same, with the reason of its
exit -- one that has only closed its stdout is waited for -- and the exit counts
toward the crash loop like any other: the upstream never comes up C<ready>
without a child. A stop that has sent the child EOF by then fails the start as
C<stopped> (see L</Lifecycle>). A refresh asks every list of the child it began
on: once that child is stopped or gone -- whether or not a call has started the
next one -- the refresh fails at once, and asks the next child nothing.

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

Seconds after the last request -- a call, or a refresh of the running child --
ended before the child is stopped. Defaults to C<300>.

=head1 METHODS

L<MCP::Hub::Upstream::Stdio> inherits all methods from L<MCP::Hub::Upstream> and
implements the lifecycle -- L<MCP::Hub::Upstream/start_p>,
L<MCP::Hub::Upstream/stop>, L<MCP::Hub::Upstream/stopped_p> and
L<MCP::Hub::Upstream/refresh_p> -- for a child process. The idle timer of
L</idle_timeout> is the base class's: set by L<MCP::Hub::Upstream/touch>,
re-armed by L<MCP::Hub::Upstream/apply_timeouts>. The forwarding methods the
facade calls (C<call_tool>, C<get_prompt>, C<read_resource>) are the inherited
ones.

=head1 SEE ALSO

L<MCP::Hub::Upstream>, L<MCP::Hub::Facade>, L<MCP::Hub::Manifest>.

=cut
