package MCP::Hub::Docker;
our $VERSION = '0.001';
use Mojo::Base -base, -signatures;

use Crypt::PRNG  qw(random_bytes_hex);
use MCP::Hub::Child qw(child_env close_inherited_fds);
use Mojo::File   qw(path);
use Mojo::IOLoop;
use Mojo::IOLoop::Stream;
use Mojo::JSON   qw(decode_json);
use Mojo::Log;
use Mojo::Promise;
use POSIX ();

# ABSTRACT: Run the docker CLI from the hub's event loop, without blocking it

# Captured output is kept to its tail: a pull or a chatty container can print
# far more than anyone needs in an error message.
use constant MAX_OUTPUT => 256 * 1024;

# How many lines of a container's own output an error message carries.
use constant TAIL_LINES => 10;

has command => 'docker';
has log     => sub { Mojo::Log->new };

# --- naming and labels -----------------------------------------------------

sub container_name ($self, $server) { return "mcp-hub-$server" }

# Every container the hub starts carries the server it belongs to and the hub
# instance that started it. Cleanup only ever touches containers that carry
# both, with this hub's owner id: never another hub's, never the user's own.
# A third label tells one start of a server from the next, so the sweep after
# one container's exit can never hit the container that replaced it.
sub labels ($self, $server, $owner, $run = undef) {
  return (
    '--label', "mcp-hub.server=$server",
    '--label', "mcp-hub.owner=$owner",
    (defined $run ? ('--label', "mcp-hub.run=$run") : ()),
  );
}

# The `docker run` arguments for a normalized docker entry, after the command
# itself. Every env key is a bare `-e KEY`: the value travels in the
# environment of the docker CLI process, never on a command line.
sub run_args ($self, $server, $c, %opt) {
  return (
    'run',
    ($opt{detach} ? '-d' : ('-i', '--rm')),
    '--name', $self->container_name($server),
    $self->labels($server, $opt{owner}, $opt{run}),
    (map { ('-e', $_) } sort keys %{$c->{env} // {}}),
    @{$opt{publish} // []},
    (map { ('-v', $_) } @{$c->{volumes} // []}),
    @{$c->{docker_args} // []},
    $c->{image},
    @{$c->{args} // []},
  );
}

# What the manifest hash of a docker entry is taken over: the image and
# everything that shapes what the container offers -- never env, which may
# hold secrets, and never the docker CLI, which does not change the server.
sub hash_input ($self, $c) {
  return (
    "docker:$c->{image}",
    [$c->{args} // [], $c->{port}, $c->{path}, $c->{transport}, $c->{volumes} // [], $c->{docker_args} // [],
      $c->{stdio} ? 1 : 0],
    undef,
  );
}

# A short id for this hub instance, kept in its cache directory. Random, not
# derived from the path: two hubs in two containers both have their cache at
# /cache, and must still never take each other's containers for leftovers. It
# lives as long as the cache does, so a restarted hub recognises -- and removes
# -- the orphans of its own earlier run.
#
# Without one there is no telling this hub's containers from anyone else's, so
# a cache directory that cannot keep it is an error, never a guessed id.
sub owner_id ($self, $cache_dir) {
  my $file = path($cache_dir, 'docker-owner');
  my $id   = _read_owner($file);
  return $id if defined $id;

  my $made = eval {
    $file->dirname->make_path;
    my $tmp = $file->sibling(".docker-owner.$$.tmp");
    $tmp->spew(random_bytes_hex(6) . "\n");
    # link, not rename: if another process got there first, its id wins. A
    # filesystem without hard links gets the rename.
    die "$!\n" unless link("$tmp", "$file") || $!{EEXIST} || rename("$tmp", "$file");
    unlink "$tmp";
    _read_owner($file) // die "it holds no id\n";
  };
  return $made if defined $made;

  (my $why = $@ || 'unknown error') =~ s/(?: at \S+ line \d+\.?)?\s*\z//;
  die "cannot keep a docker owner id in $file ($why) -- docker and compose entries need a writable hub.cache_dir\n";
}

sub _read_owner ($file) {
  return undef unless -f $file;
  my $id = eval { $file->slurp } // return undef;
  return $id =~ /^([0-9a-f]{6,64})\s*$/ ? $1 : undef;
}

# --- running the CLI -------------------------------------------------------

# Run `<command> @$args` as a child process watched by the IOLoop and resolve
# with {code, signal, out, err} once it has exited -- whatever its exit code,
# which the caller interprets. The promise is rejected only when the command
# could not be run at all: the CLI is missing, the working directory does not
# exist, or it ran past `timeout`. `on_spawn` is handed a function that sends
# the running command a signal (TERM by default), for a command that is to be
# given up on -- one that never sends it to a pid that is no longer the
# command's.
sub run_p ($self, $args, %opt) {
  my $command = $self->command;
  my @argv    = ($command, @$args);
  my $done    = Mojo::Promise->new;

  my ($out_r, $out_w, $err_r, $err_w);
  unless (pipe($out_r, $out_w) && pipe($err_r, $err_w)) {
    return $done->reject("cannot run '$command': pipe: $!");
  }

  my $pid = fork;
  return $done->reject("cannot run '$command': fork: $!") unless defined $pid;

  if (!$pid) {
    close $out_r;
    close $err_r;
    open(STDIN,  '<',  '/dev/null') or POSIX::_exit(127);
    open(STDOUT, '>&', $out_w)      or POSIX::_exit(127);
    open(STDERR, '>&', $err_w)      or POSIX::_exit(127);
    close_inherited_fds();
    %ENV = child_env($opt{env});
    if (defined $opt{cwd} && !chdir $opt{cwd}) {
      print STDERR "mcp-hub: cannot chdir: $!\n";
      POSIX::_exit(127);
    }
    { exec {$argv[0]} @argv }
    print STDERR "mcp-hub: cannot exec: $!\n";
    POSIX::_exit(127);
  }

  close $out_w;
  close $err_w;

  my $run = {out => '', err => '', open => 2};
  my $settle = sub {
    return if $run->{settled}++;
    return $done->reject("'$command @{[$args->[0] // '']}' timed out after $opt{timeout}s") if $run->{timed_out};

    my $status = $run->{status};
    my $res = {
      code   => (defined $status ? ($status & 127 ? undef : $status >> 8) : undef),
      signal => (defined $status ? ($status & 127 || undef) : undef),
      out    => $run->{out},
      err    => $run->{err},
    };
    if (($res->{code} // -1) == 127 && $res->{err} =~ /^mcp-hub: cannot (exec|chdir): (.*)$/m) {
      my ($what, $why) = ($1, $2);
      return $done->reject($what eq 'exec'
        ? "'$command' not found ($why) -- install the Docker CLI or set hub.docker_command"
        : "cannot change to $opt{cwd} ($why)");
    }
    $done->resolve($res);
  };

  # The exit status is collected without blocking: a child may close its
  # output and live on for a moment, and a blocking waitpid would stall the
  # whole hub meanwhile. The result settles once both the output and the
  # status are in.
  #
  # Under Mojo::Reactor::EV, libev reaps every child itself as soon as SIGCHLD
  # arrives, so a waitpid of ours would come up empty and the status would be
  # lost: there a child watcher, set up before the loop runs again, receives
  # it. Elsewhere the child is polled for. (Where SIGCHLD is ignored the kernel
  # reaps it, and the status is simply unknown.)
  my $collect;
  if (Mojo::IOLoop->singleton->reactor->isa('Mojo::Reactor::EV')) {
    $run->{watcher} = EV::child($pid, 0, sub ($w, $revents) {
      $run->{status} = $w->rstatus;
      $run->{reaped} = 1;
      delete $run->{watcher};
      $settle->() if $run->{done};
    });
    $collect = sub { $settle->() unless $run->{watcher} };
  }
  else {
    $collect = sub {
      my $got = waitpid($pid, POSIX::WNOHANG());
      return Mojo::IOLoop->timer(0.05 => $collect) if $got == 0;
      undef $collect;
      $run->{status} = $got > 0 ? $? : undef;
      $run->{reaped} = 1;
      $settle->();
    };
  }

  # The streams' callbacks hold $run, and $run holds the streams: once both
  # are closed, letting go of them is what frees the lot.
  my $finish = sub {
    return if $run->{done}++;
    Mojo::IOLoop->remove($run->{timer}) if $run->{timer};
    $_->close for grep {defined} delete @{$run}{qw(out_stream err_stream)};
    $collect->();
  };

  for my $part ([out => $out_r], [err => $err_r]) {
    my ($key, $handle) = @$part;
    my $stream = Mojo::IOLoop::Stream->new($handle);
    $stream->timeout(0);
    $stream->on(read => sub ($s, $bytes) {
      $run->{$key} .= $bytes;
      substr($run->{$key}, 0, length($run->{$key}) - MAX_OUTPUT, '') if length $run->{$key} > MAX_OUTPUT;
    });
    $stream->on(close => sub ($s) { $finish->() unless --$run->{open} });
    $stream->on(error => sub ($s, $e) { });
    $stream->start;
    $run->{"${key}_stream"} = $stream;
  }

  if (my $timeout = $opt{timeout}) {
    $run->{timer} = Mojo::IOLoop->timer($timeout => sub {
      $run->{timed_out} = 1;
      kill 'KILL', $pid;
      $finish->();
    });
  }

  # Until the command is reaped its pid is its own; after that it may be
  # anyone's.
  $opt{on_spawn}->(sub ($signal = 'TERM') { kill $signal, $pid unless $run->{reaped} }) if $opt{on_spawn};

  return $done;
}

# --- the operations the upstreams need -------------------------------------

# Make sure the image is there before a container is started from it, and say
# which TCP ports it declares with EXPOSE: inspect it, and pull it when it is
# missing. A pull has no timeout of its own -- an image of several gigabytes is
# not a failure -- and because it happens before the container starts, the
# handshake's request_timeout never includes it. Resolves with the sorted list
# of exposed TCP ports.
sub image_ports_p ($self, $image, %opt) {
  return $self->_image_ports_p($image, %opt)->then(sub ($ports) {
    return $ports if $ports;
    $self->log->info("pulling $image");
    return $self->run_p(['pull', $image])->then(sub ($pull) {
      die "cannot pull $image: " . $self->explain($self->stderr_tail($pull)) . "\n" if $pull->{code} // 1;
      $self->log->info("pulled $image");
      return $self->_image_ports_p($image, %opt);
    })->then(sub ($ports) {
      return $ports // die "cannot inspect image $image after pulling it\n";
    });
  });
}

# Whether a local image of that name exists -- never pulling it.
sub image_exists_p ($self, $image, %opt) {
  return $self->_image_ports_p($image, %opt)->then(sub ($ports) { defined $ports ? 1 : 0 });
}

# The exposed TCP ports of a local image, or undef when the image is missing.
sub _image_ports_p ($self, $image, %opt) {
  my $format = '{{json .Config.ExposedPorts}}';
  return $self->run_p(['image', 'inspect', '--format', $format, $image], timeout => $opt{timeout})->then(sub ($res) {
    if ($res->{code}) {
      return undef if _missing_image($res->{err});
      die "cannot inspect image $image: " . $self->explain($self->stderr_tail($res)) . "\n";
    }
    my $exposed = eval { decode_json($res->{out} =~ s/\s+\z//r) };
    my @ports   = ref $exposed eq 'HASH' ? keys %$exposed : ();
    return [sort { $a <=> $b } map { m{^(\d+)(?:/tcp)?$}i ? $1 : () } @ports];
  });
}

# Docker says "No such image", Podman "image not known"; anything else (a
# daemon that cannot be reached, a permission problem) is not a missing image,
# and pulling would only report the same problem again under a wrong name.
sub _missing_image ($stderr) {
  return $stderr =~ /no such (?:image|object)|image not known/i ? 1 : 0;
}

# Remove the containers of one server that this hub started earlier and that
# are still there: a crashed hub's orphan, or a container whose CLI was killed.
# Matched by label, owner included, and every match is inspected again before
# it is removed -- a container that is not ours is never touched, whatever the
# daemon's filter semantics turn out to be. With $run, only that one start's
# containers are matched.
sub remove_orphans_p ($self, $server, $owner, %opt) {
  my %want = ('mcp-hub.server' => $server, 'mcp-hub.owner' => $owner, (defined $opt{run} ? ('mcp-hub.run' => $opt{run}) : ()));
  my @filters = map { ('--filter', "label=$_=$want{$_}") } sort keys %want;

  return $self->run_p(['ps', '-a', '-q', @filters], timeout => $opt{timeout})->then(sub ($res) {
    die "cannot list containers: " . $self->stderr_tail($res) . "\n" if $res->{code};
    my @ids = grep {length} split /\s+/, $res->{out};
    return [] unless @ids;
    return $self->run_p(['inspect', '--format', '{{.Id}} {{json .Config.Labels}}', @ids], timeout => $opt{timeout});
  })->then(sub ($res) {
    return [] if ref $res eq 'ARRAY';
    my @ours;
    for my $line (split /\n/, $res->{out}) {
      my ($id, $json) = $line =~ /^(\S+)\s+(.*)$/ or next;
      my $labels = eval { decode_json($json) };
      next unless ref $labels eq 'HASH';
      next if grep { ($labels->{$_} // '') ne $want{$_} } keys %want;
      push @ours, $id;
    }
    return [] unless @ours;
    # One start's container outliving its CLI is routine (`docker compose run
    # --rm` leaves it when the CLI is stopped); a leftover found at start is not.
    my @short = map { substr $_, 0, 12 } @ours;
    defined $opt{run}
      ? $self->log->debug("[$server] removing the container its CLI left behind: @short")
      : $self->log->info("removing leftover container(s) of $server: @short");
    return $self->run_p(['rm', '-f', @ours], timeout => $opt{timeout})->then(sub ($rm) {
      $self->log->debug("[$server] rm -f: " . $self->stderr_tail($rm)) if $rm->{code};
      return \@ours;
    });
  });
}

# --- messages --------------------------------------------------------------

# The last lines of a command's stderr, on one line: what goes into an error
# message. Never its stdout, which is the command's answer -- and that may be
# the whole compose project, secrets and all.
sub stderr_tail ($self, $res, $lines = TAIL_LINES) {
  my $tail = $self->tail($res->{err}, $lines);
  return length $tail ? $tail : 'exit ' . ($res->{code} // ('signal ' . ($res->{signal} // '?')));
}

sub tail ($self, $text, $lines = TAIL_LINES) {
  my @lines = grep { /\S/ } split /\r?\n/, $text // '';
  splice @lines, 0, @lines - $lines if @lines > $lines;
  s/^\s+|\s+$//g for @lines;
  return join ' | ', @lines;
}

# Docker refuses a container name that is already taken. When the taken one is
# not ours, the hub leaves it alone -- so say what to do about it.
sub explain ($self, $message) {
  return "$message -- a container of that name exists that this hub did not start;"
    . ' remove it if it is a leftover, or rename this server'
    if $message =~ /already in use/i;
  return "$message -- is the Docker daemon running? When the hub itself runs in a container,"
    . ' mount /var/run/docker.sock into it'
    if $message =~ /cannot connect to the docker daemon|docker\.sock/i;
  return $message;
}

# The host address a `docker port` or `docker compose port` line names, as
# something to connect to: Docker answers with the address it bound, and the
# wildcard ones are reached through the loopback.
sub host_address ($self, $text) {
  my ($line) = grep { /\S/ } split /\r?\n/, $text // '';
  return undef unless defined $line && $line =~ /^\s*(\[[^\]]+\]|[^\s:]+):(\d+)\s*$/;
  my ($host, $port) = ($1, $2);
  $host = '127.0.0.1' if $host eq '0.0.0.0';
  $host = '[::1]'     if $host eq '[::]';
  return "$host:$port";
}

1;

=encoding utf8

=head1 SYNOPSIS

  use MCP::Hub::Docker;

  my $docker = MCP::Hub::Docker->new(command => 'docker', log => $log);

  $docker->image_ports_p('mcp/fetch')->then(sub ($ports) {
    say "exposes: @$ports";
    return $docker->run_p(['ps', '-a'], timeout => 30);
  })->then(sub ($res) {
    say $res->{out} unless $res->{code};
  });

=head1 DESCRIPTION

L<MCP::Hub::Docker> is the one place the hub talks to the Docker CLI. The hub
is a single process with a single L<Mojo::IOLoop>, so a C<docker> invocation is
never a C<system> or backticks: L</run_p> forks the CLI, watches its output
through the loop, and resolves a promise when it has exited.

It also knows the conventions the Docker upstreams share: the container name
C<< mcp-hub-<server> >>, the labels every container the hub starts carries, the
C<docker run> arguments of a configuration entry, the input of its manifest
hash, the owner id that tells this hub's containers from everybody else's, and
the cleanup that removes this hub's leftovers -- and only those.

See L<MCP::Hub::Upstream::Docker> and L<MCP::Hub::Upstream::Compose> for the
upstreams built on it.

=head1 ATTRIBUTES

=attr command

The CLI to call, from C<hub.docker_command>. Defaults to C<docker>; C<podman>
works too.

=attr log

A L<Mojo::Log>.

=head1 METHODS

=method container_name

  my $name = $docker->container_name('github');    # mcp-hub-github

The name of the container that serves a server.

=method explain

  my $message = $docker->explain($message);

The message, plus what to do about it when it is Docker's "name already in
use", or a daemon that cannot be reached (mount F</var/run/docker.sock> when
the hub runs in a container).

=method hash_input

  my @input = $docker->hash_input($entry);
  my $hash  = $manifest->hash(@input);

What the manifest hash of a normalized C<docker> entry is taken over: the image,
C<args>, C<port>, C<path>, the transport, C<volumes>, C<docker_args> and
C<stdio>. Never C<env>, and never the docker command.

=method host_address

  my $addr = $docker->host_address("0.0.0.0:49153\n");    # 127.0.0.1:49153

The C<host:port> to connect to from a C<docker port> or C<docker compose port>
answer: the wildcard addresses C<0.0.0.0> and C<[::]> become the loopback, and
anything that is not an address gives undef.

=method image_exists_p

  $docker->image_exists_p($image, timeout => 60)->then(sub ($exists) { ... });

Resolves with C<1> when the image is there locally and C<0> when it is not;
never pulls. Anything but a missing image (a daemon that cannot be reached, say)
rejects.

=method image_ports_p

  $docker->image_ports_p('mcp/fetch', timeout => 60)->then(sub ($ports) { ... });

Make sure the image is present locally, pulling it first when it is missing
(logged at C<info>), and resolve with the sorted TCP port numbers its C<EXPOSE>
declares -- an empty list when there are none. The C<image inspect> honours
C<timeout>; the pull has no timeout. Rejected with C<cannot pull IMAGE: ...> and
Docker's own message when the pull fails, and with C<cannot inspect image
IMAGE: ...> when the daemon cannot even be asked.

=method labels

  my @args = $docker->labels($server, $owner, $run);

The C<--label> arguments for a container: C<mcp-hub.server>, C<mcp-hub.owner>
and, when given, C<mcp-hub.run>, which tells one start of a server from the
next.

=method owner_id

  my $owner = $docker->owner_id($cache_dir);

The id of this hub instance, in the C<mcp-hub.owner> label of every container it
starts. Made up once at random and kept in F<docker-owner> in the cache
directory, so it survives a restart -- the restarted hub cleans up its own
orphans -- while two hubs with separate caches never share one, even when both
keep their cache at the same path inside their own container. If the file
cannot be kept, it dies: without an id of its own the hub cannot tell its
containers from anyone else's, so it starts none.

=method remove_orphans_p

  $docker->remove_orphans_p($server, $owner, run => $run, timeout => 60)
    ->then(sub ($removed) { ... });

Remove (C<rm -f>) the containers labelled with this server and this owner (and
this run, when given), and resolve with the ids it removed. Each candidate the
filter returns is inspected again and only removed when its labels match
exactly, so a container that is not this hub's is never touched.

=method run_args

  my @args = $docker->run_args($server, $entry, owner => $owner, detach => 1,
    run => $run, publish => ['-p', '127.0.0.1::8080']);

The C<docker run> arguments for a normalized entry: C<-i --rm> for a stdio
container or C<-d> with C<detach>, the name, the labels, a bare C<-e KEY> for
every C<env> key, C<publish>, C<-v> for every volume, C<docker_args>, the image
and its C<args>.

=method run_p

  $docker->run_p(['port', $id, '8080/tcp'], env => {...}, cwd => $dir, timeout => 30)
    ->then(sub ($res) { ... $res->{code}, $res->{out}, $res->{err} ... });

Run the CLI with these arguments as a child process watched by the event loop.
C<env> is merged into the child's environment, C<cwd> is its working directory,
and C<timeout> (seconds) kills it when it runs over. Resolves with C<code>,
C<signal>, C<out> and C<err> whatever the exit code; rejected only when the CLI
cannot be run at all (C<'docker' not found -- install the Docker CLI or set
hub.docker_command>), the working directory is missing, or the timeout hits.
C<on_spawn> is called with a function that signals the running command
(C<TERM>, or the signal it is given) and does nothing once the command is gone:
how a C<docker wait> is given up on.

=method stderr_tail

  my $text = $docker->stderr_tail($res);

The last lines of a result's stderr joined on one line, or C<exit N> when it
said nothing there. Never its stdout: that is the command's answer, and for
C<docker compose config> it is the whole project, secrets included.

=method tail

  my $text = $docker->tail($output, 10);

The last non-empty lines of some output, joined on one line.

=head1 SEE ALSO

L<MCP::Hub>, L<MCP::Hub::Upstream::Docker>, L<MCP::Hub::Upstream::Compose>.

=cut
