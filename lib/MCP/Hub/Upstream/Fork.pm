package MCP::Hub::Upstream::Fork;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Hub::Upstream::Stdio', -signatures;

use MCP::Hub::Child qw(child_env inherited_fds);
use MCP::Hub::Facade;
use MCP::Hub::Facade::Server;
use MCP::Server::Context;
use Mojo::IOLoop;
use POSIX        ();
use Scalar::Util qw(blessed);
use Socket       qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

# ABSTRACT: A Perl MCP server class whose calls run in a worker forked from the hub

# How many lines of a worker's stderr the exit hint carries.
use constant STDERR_LINES => 5;

# The exit code of a worker whose class could not be built or died serving.
# An `exit` in class code keeps its own code.
use constant WORKER_FAILED => 3;

# --- the class, loaded in the hub -------------------------------------------

# The facade is filled at build, from the class itself: tools/list never needs
# a worker, and there is no cache to go stale.
sub _build_server ($self) {
  my $server = MCP::Hub::Facade::Server->new(name => $self->name, version => '0.0.0');
  $self->server($server);

  die "hub.fork needs Linux (the worker's fd isolation reads /proc/self/fd)\n" unless $self->_has_proc_fd;
  my $class = $self->_load_class;

  # Native::Status is the example: its tools read the upstreams of the hub
  # they run in, and a worker only has a dead copy of them.
  die "$class needs the live hub (it has a 'hub' attribute) and cannot run in a forked worker; drop hub.fork\n"
    if $class->can('hub');

  my $manifest = $self->_class_manifest($class);
  $self->{class_instructions}  = $manifest->{instructions};
  $self->{class_lists}         = {map { $_ => $manifest->{$_} } qw(prompts resources)};
  $self->{manifest_fetched_at} = $manifest->{fetched_at};
  MCP::Hub::Facade->apply($server, $self, $manifest);
  return $server;
}

# The manifest, read in the hub from a throwaway instance through the class's
# own JSON-RPC handler -- exactly what a worker will serve, and the facade
# merges back the extras it renders. The instance is let go of afterwards, so
# nothing it opened (a git repository, say) is open in the hub at a fork.
sub _class_manifest ($self, $class) {
  my $instance = $class->new(%{$self->config->{class_args} // {}});
  my $server   = $self->_server_of($instance);

  my %lists;
  my $ok = eval {
    my $init = $self->_handle($server, 'initialize', {
      protocolVersion => $self->protocol_version,
      capabilities    => {},
      clientInfo      => {name => 'mcp-hub', version => $VERSION},
    });
    my $caps = $init->{capabilities} // {};
    $self->{server_protocol} = $init->{protocolVersion} // $self->protocol_version;
    $self->{capabilities}    = $caps;
    $self->{server_info}     = $init->{serverInfo} // {name => $self->name, version => '0.0.0'};

    # MCP 0.15 answers a legacy initialize without the instructions -- here and
    # in a worker alike -- so they are read off the server object.
    $self->{instructions} = $server->instructions;

    # A prompts/list or resources/list the class answers with an error is an
    # empty list, as an upstream's is (MCP::Hub::Upstream::_list_all_p) -- and
    # its worker's, whose handshake and refresh go through that. An error on its
    # tools/list fails the entry.
    $lists{tools}     = $self->_handle_list($server, 'tools/list', 'tools');
    $lists{prompts}   = exists $caps->{prompts}   ? $self->_handle_list($server, 'prompts/list',   'prompts',   1) : [];
    $lists{resources} = exists $caps->{resources} ? $self->_handle_list($server, 'resources/list', 'resources', 1) : [];
    1;
  };
  my $err = $@;

  # A tool closure that captures the instance -- the usual way to write one --
  # is a cycle through the server, and the instance would never be freed.
  # Emptying the lists breaks it.
  $server->$_([]) for qw(tools prompts resources);
  die $err unless $ok;

  return $self->_manifest_from(\%lists);
}

# The result the class answers $method with. An answer with an error dies --
# with $lenient, it is undef instead.
sub _handle ($self, $server, $method, $params = {}, $lenient = 0) {
  my $class = $self->config->{class};
  my $res   = $server->handle(
    {jsonrpc => '2.0', id => 1, method => $method, params => $params},
    MCP::Server::Context->new(legacy => $self->protocol_version),
  );
  die "$class answered $method with a promise; a forked class must list synchronously\n"
    if blessed $res && $res->isa('Mojo::Promise');
  die "$class answered $method with nothing\n" unless ref $res eq 'HASH';
  if ($res->{error}) {
    return undef if $lenient;
    die "$class answered $method with an error: " . $self->_error_message($res->{error}) . "\n";
  }
  return $res->{result} // {};
}

# Every page of $method. With $lenient, an error the class answers on any of
# them makes the whole list empty, as it does over a transport.
sub _handle_list ($self, $server, $method, $key, $lenient = 0) {
  my (@all, %seen);
  my $cursor;
  while (1) {
    my $result = $self->_handle($server, $method, defined $cursor ? {cursor => $cursor} : {}, $lenient) // return [];
    push @all, @{$result->{$key} // []};
    $cursor = $result->{nextCursor};
    last unless defined $cursor && length $cursor && !$seen{$cursor}++;
  }
  return \@all;
}

# Nothing is cached for a forked class, so there is nothing to hash. Returned
# as an explicit undef: _manifest_from puts it in a hash.
sub _hash ($self) { return undef }

# There is no cache: what a worker's start keeps of a list it got no answer for
# (MCP::Hub::Upstream::_kept_list) is what the class listed at build. Every
# worker is an instance of that class.
sub _cached_manifest ($self) { return $self->{class_lists} }

# A worker's handshake refreshes the facade in memory only, never on disk. Its
# instructions are always empty (see _class_manifest), so the class's stay. An
# upstream a reload let go of applies nothing (MCP::Hub::Upstream::_dropped).
sub _apply_manifest ($self, $manifest) {
  return $self if $self->_dropped;
  $manifest->{instructions} //= $self->{class_instructions};
  $self->{instructions}        = $manifest->{instructions};
  $self->{manifest_fetched_at} = $manifest->{fetched_at};
  return $self->_show_manifest($manifest);
}

# --- the worker, forked on first use ----------------------------------------

sub _spawn ($self) {
  my $class = $self->config->{class};

  # A lock another thread holds at the fork stays locked in the worker for
  # good, so a hub running more than one thread forks nothing. The refusal
  # counts like a failed start.
  if ((my $threads = $self->_thread_count) > 1) {
    my $why = "cannot fork a worker for $class: the hub runs $threads threads";
    $self->_record_exit;
    $self->error($why) if $self->{failed};
    die "$why\n";
  }

  socketpair(my $parent, my $child, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!\n";
  pipe(my $err_r, my $err_w) or die "pipe: $!\n";
  $_->autoflush(1) for $parent, $child, $err_w;

  my $pid = fork // die "fork: $!\n";
  $self->_worker($parent, $child, $err_r, $err_w) unless $pid;    # never returns

  close $child;
  close $err_w;
  $self->{stderr_tail} = [];
  $self->log->info("[@{[$self->name]}] forked a worker for $class (pid $pid)");
  return $self->_attach($pid, $parent, $err_r);
}

# Runs in the forked child, and never returns into the hub's code: whatever
# happens, it ends in POSIX::_exit -- no hub END block, no global destruction.
sub _worker ($self, $parent, $child, $err_r, $err_w) {
  my $ok = eval {
    close $parent;
    close $err_r;

    # `pidof mcp-hub` is the documented HUP target; it must not find a worker.
    $0 = 'mcp-hub-worker ' . $self->name;
    $self->_reset_signals;

    # The hub's loop, its streams and timers stay referenced and dormant: a
    # stream destroyed here would fire the hub's close handlers in the worker.
    # A wait in the worker gets a fresh reactor.
    Mojo::IOLoop->reset({freeze => 1});

    open(STDIN,  '<&', $child) or die "cannot attach stdin: $!\n";
    open(STDOUT, '>&', $child) or die "cannot attach stdout: $!\n";
    open(STDERR, '>&', $err_w) or die "cannot attach stderr: $!\n";
    close $child;
    close $err_w;
    $self->_isolate_fds;
    %ENV = child_env();    # less the MOJO_REUSE that names the hub's listeners

    srand();    # or every worker would repeat the hub's rand() sequence

    # Compiled last, so it runs first: an `exit` in class code ends the worker
    # with its status, before any END block of the hub's.
    eval 'END { POSIX::_exit($?) } 1' or die $@;

    my $c = $self->config;
    $self->_server_of($c->{class}->new(%{$c->{class_args} // {}}))->to_stdio;
    1;
  };
  print STDERR "worker failed: $@" unless $ok;
  POSIX::_exit($ok ? 0 : WORKER_FAILED);
}

# What exec would do: a caught signal goes back to its default, an ignored one
# stays ignored (perl ignores FPE, Mojo::IOLoop PIPE). Assigning to %SIG
# replaces C-level handlers too, libev's SIGCHLD among them. HUP is ignored
# outright: `pkill -HUP -f mcp-hub` still matches a worker's command line, and
# only the hub reloads.
sub _reset_signals ($self) {
  for my $sig (grep { !/^(?:KILL|STOP|ZERO|NUM\d+|RTMIN|RTMAX|__WARN__|__DIE__)$/ } keys %SIG) {
    no warnings 'signal';
    $SIG{$sig} = 'DEFAULT' unless ($SIG{$sig} // '') eq 'IGNORE';
  }
  $SIG{__WARN__} = $SIG{__DIE__} = undef;
  $SIG{HUP} = 'IGNORE';
  POSIX::sigprocmask(POSIX::SIG_SETMASK(), POSIX::SigSet->new);
  return $self;
}

# Every fd above 2 is something of the hub's: the listening socket, client
# connections, other upstreams' sockets and pipes, libev's epoll fd and
# eventfd, log files, module DATA handles. A regular file is reopened, anything
# else gets /dev/null dup2'ed over it -- dup2 rather than close, because a
# dormant inherited handle may still close its fd number later, and that must
# never hit a fresh fd of the class.
sub _isolate_fds ($self) {
  my $fds = inherited_fds() // die "cannot read /proc/self/fd: $!\n";

  # Every listed fd is open, so /dev/null lands on none of them.
  my $null = POSIX::open('/dev/null', POSIX::O_RDWR()) // die "cannot open /dev/null: $!\n";
  for my $fd (@$fds) {
    POSIX::dup2($null, $fd) unless $self->_reopen_file($fd);
  }
  POSIX::close($null);
  return $self;
}

# A regular file gets an open file description of its own -- the same file at
# the same position, with the same access mode and append flag -- so the
# worker never moves the hub's offset. Through /proc that works for a deleted
# file too.
sub _reopen_file ($self, $fd) {
  my $link = "/proc/self/fd/$fd";
  return 0 unless -f $link;

  my ($pos, $flags) = (0, 0);
  if (open my $info, '<', "/proc/self/fdinfo/$fd") {
    while (my $line = <$info>) {
      $pos   = $1     if $line =~ /^pos:\s+(\d+)/;
      $flags = oct $1 if $line =~ /^flags:\s+(\d+)/;    # octal in fdinfo
    }
  }

  my $new = POSIX::open($link, ($flags & POSIX::O_ACCMODE()) | ($flags & POSIX::O_APPEND())) // return 0;
  POSIX::lseek($new, $pos, POSIX::SEEK_SET());
  POSIX::dup2($new, $fd);
  POSIX::close($new);
  return 1;
}

sub _thread_count ($self) {
  open my $fh, '<', '/proc/self/status' or return 1;
  while (my $line = <$fh>) { return $1 + 0 if $line =~ /^Threads:\s+(\d+)/ }
  return 1;
}

sub _has_proc_fd ($self) { return -d '/proc/self/fd' ? 1 : 0 }

# --- what the worker says on its way out ------------------------------------

sub _on_stderr ($self, $bytes) {
  $self->SUPER::_on_stderr($bytes);
  my $tail = $self->{stderr_tail} //= [];
  push @$tail, map { s/^\s+|\s+$//gr } grep {/\S/} split /\r?\n/, $bytes;
  splice @$tail, 0, @$tail - STDERR_LINES if @$tail > STDERR_LINES;
  return $self;
}

# A worker execs nothing: an exit 127 is the class's own.
sub _exec_hint ($self, $status) { return '' }

sub _exit_hint ($self, $status) {
  my $hint = $self->state eq 'starting' ? ' while starting ' . $self->config->{class} : '';
  my $tail = join ' | ', @{$self->{stderr_tail} // []};
  return length $tail ? "$hint: $tail" : $hint;
}

# --- status -----------------------------------------------------------------

sub pss_kb ($self) {
  my $pid = $self->stats->{pid} or return undef;
  open my $fh, '<', "/proc/$pid/smaps_rollup" or return undef;
  while (my $line = <$fh>) { return $1 + 0 if $line =~ /^Pss:\s+(\d+)/ }
  return undef;
}

sub status_row ($self) {
  my $row = $self->SUPER::status_row;
  $row->{pss_kb} = $self->pss_kb;
  return $row;
}

1;

=encoding utf8

=head1 SYNOPSIS

  # in the hub's configuration
  "wiki": {
    "class": "MCP::Wiki::Server",
    "args":  { "wiki_root": "/home/me/wiki", "use_git": true },
    "hub":   { "fork": true, "idle_timeout": 600 }
  }

  # or directly
  use MCP::Hub::Upstream::Fork;

  my $up = MCP::Hub::Upstream::Fork->new(
    name   => 'wiki',
    config => {type => 'fork', class => 'MCP::Wiki::Server',
               class_args => {wiki_root => '/home/me/wiki', use_git => 1}},
  );
  $up->call_tool('get_page', {page => 'index.md'})->then(sub ($result) { ... });

=head1 DESCRIPTION

L<MCP::Hub::Upstream::Fork> mounts a Perl MCP server class -- one the hub can
load -- so that it costs about as little memory as an in-process class, but
without stalling the hub the way an in-process class does. It is what a
C<class> entry with C<"hub": {"fork": true}> becomes.

=over 2

=item B<Listing needs no process.> The class is loaded in the hub when the entry
is built. A throwaway instance, made with the entry's C<args>, answers
C<initialize>, C<tools/list> and -- when its capabilities announce them --
C<prompts/list> and C<resources/list> through its own JSON-RPC handler, in
process. That fills the facade; the C<instructions> are read off the server
object. A C<prompts/list> or C<resources/list> the class answers with an error
is an empty list, as it is for the worker and any other upstream (see
L<MCP::Hub::Upstream/refresh_p>); an error on its C<tools/list> fails the
entry. A worker's start that gets no answer to its C<prompts/list> or
C<resources/list> keeps what the class listed here, as another upstream's
start keeps what is in its cache. The instance is then let go of: its
server's tool, prompt and resource lists are emptied first, so a tool closure
that captures the instance does not keep it alive through a cycle. Nothing is cached on disk and nothing is hashed,
so C<args> -- which may hold secrets -- is never written anywhere.

=item B<Calls run in a worker.> The first C<tools/call>, C<prompts/get> or
C<resources/read> forks a worker from the hub, with no exec, and talks to it
with the stdio client of L<MCP::Hub::Upstream::Stdio>. The worker shares its
pages with the hub, so it is ready in a few tens of milliseconds; it builds a
fresh instance with C<args> and runs C<to_stdio> on its server. A slow call
holds only the worker -- no other upstream and no HTTP client waits for it.

=item B<The lifecycle is stdio's.> Lazy start, idle stop
(L<MCP::Hub::Upstream::Stdio/idle_timeout>), C<always_on>, the request timeout
with C<notifications/cancelled>, three exits within five seconds making it
C<failed> until a refresh, a refresh that forks and handshakes -- all inherited
unchanged. A failed worker leaves C<tools/list> answering from the facade, while
a C<tools/call> reports the failure and the refresh hint. One request at a time,
as with any stdio child; the next call forks from the hub as it is then, which
also undoes the worker's copy-on-write growth. A stop is the end of the
worker's input: a worker that finishes the call it is in within two seconds
exits on its own and is never signalled; one still busy after that gets
C<SIGTERM>.

=back

=head2 What a worker inherits, and what it keeps

A worker starts as a copy of the hub. Before it builds its instance it drops
everything of the hub's: it renames itself C<mcp-hub-worker NAME> (so
C<pidof mcp-hub> finds only the hub), resets every caught signal to its default
the way C<exec> would and ignores C<HUP>, freezes the hub's event loop so it is
never run or destroyed in the worker, points its stdin and stdout at the hub's
socket and its stderr at its own pipe, gives every regular file it inherited an
open file description of its own (same position, same access and append flags)
and puts F</dev/null> over every other inherited fd -- the listening socket,
client connections, other upstreams' sockets and pipes, the event loop's own
fds -- and drops C<MOJO_REUSE>, which names the listening socket's fd, from its
environment (L<MCP::Hub::Child/child_env>). It reseeds C<rand>, and an C<END>
block compiled last makes an C<exit> in class code end the worker with its
status before any of the hub's C<END> blocks. It always leaves with
C<POSIX::_exit>: exit code C<0> after EOF, C<3> when the instance could not be
built or its server died (the message goes to stderr, which the hub logs and
puts in the exit warning).

Whatever the hub holds at the moment of the fork must be harmless to inherit or
be neutralised by that recipe. A hub that runs more than one thread at that
moment forks nothing -- a lock held by another thread would stay locked in the
worker for good -- and the refusal counts toward the crash loop.

=head2 What a class must do

=over 2

=item * Be an L<MCP::Server> subclass, or have a C<server> method that returns
one (as L<MCP::Wiki::Server> does).

=item * Construct cheaply and without side effects: C<new> runs once in the hub
when the entry is built (at daemon start and on every reload that rebuilds it)
and once in every worker.

=item * List synchronously. L<MCP::Server>'s own list methods are; a C<handle>
that answers C<tools/list> with a promise is refused.

=item * Not need the live hub. A class with a C<hub> attribute, such as
L<MCP::Hub::Native::Status>, is refused: its tools would read a dead copy of
the hub's state.

=item * Not need the HTTP request. Tool code in a worker gets a stdio
L<MCP::Server::Context> -- no controller, no request, no profile -- and every
scope counts as granted. The hub cannot detect a class that reads the request,
so it is up to whoever mounts it.

=item * Not drive its own event machinery (EV or AnyEvent watchers, threads).
The worker runs C<to_stdio>, a blocking line loop; a promise a tool returns is
waited for on a fresh L<Mojo::Reactor::Poll>.

=item * Take its configuration through C<args>. C<env> and C<cwd> are
configuration errors on a forked entry; C<args> is passed as it is, with no
C<${VAR}> and no C<~>, so write absolute paths.

=back

Class code is never reloaded: a newer version of the class installed on disk
reaches the hub and its workers only after a daemon restart.

=head2 Platform

Linux only: the fd isolation reads F</proc/self/fd>, and an entry built where
that is missing becomes a C<failed> upstream saying so.

=head1 ATTRIBUTES

L<MCP::Hub::Upstream::Fork> inherits all attributes from
L<MCP::Hub::Upstream::Stdio>; L<MCP::Hub::Upstream::Stdio/cache_dir> is unused.

=head1 METHODS

L<MCP::Hub::Upstream::Fork> inherits all methods from
L<MCP::Hub::Upstream::Stdio> and adds:

=method pss_kb

  my $kb = $up->pss_kb;

The running worker's proportional set size in kilobytes, from
F</proc/PID/smaps_rollup>, or C<undef> when no worker runs. Its C<rss_kb>
counts every page it shares with the hub in full -- 60 MB and more for a worker
whose own memory is a few MB. PSS splits each shared page between the processes
that map it, so the PSS of the hub and its workers adds up to the memory they
really use; what a worker costs is how much that sum rose, not its C<pss_kb>
alone, which also carries its half of every page it shares with the hub.

=method status_row

Adds C<pss_kb> to L<MCP::Hub::Upstream/status_row>; the row's C<type> is
C<fork>.

=head1 SEE ALSO

L<MCP::Hub::Upstream::Stdio>, L<MCP::Hub::Upstream::Perl>, L<MCP::Hub::Upstream>,
L<MCP::Hub/Process model>.

=cut
