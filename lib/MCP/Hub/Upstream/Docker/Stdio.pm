package MCP::Hub::Upstream::Docker::Stdio;
our $VERSION = '0.001';
use Mojo::Base -strict, -signatures;

use MCP::Hub::Upstream::Docker::Engine;
use MCP::Hub::Upstream::Stdio;

# ABSTRACT: A stdio container -- docker run -i -- as the transport of a Docker upstream

# The engine's methods first, then the stdio transport they wrap.
our @ISA = qw(MCP::Hub::Upstream::Docker::Engine MCP::Hub::Upstream::Stdio);

# How many lines of the container's stderr an error message carries.
use constant STDERR_LINES => 10;

# Stop the CLI, or -- when there never was one -- clean up right away.
sub retire ($self) {
  return $self->stop if $self->{pid};
  $self->_teardown;
  return $self;
}

# Only a stop asked for is deliberate. The stdio transport also kills its
# child on its own -- for a line over its limit -- and flags that as a stop
# too; to the owner it is a container gone, like a crash.
sub stop ($self) {
  $self->{retiring} = 1 if $self->{pid};
  return $self->SUPER::stop;
}

# The last lines the container (or Docker) wrote to stderr, on one line.
sub stderr_tail ($self) { return join ' | ', @{$self->{stderr_tail} // []} }

sub _on_stderr ($self, $bytes) {
  $self->SUPER::_on_stderr($bytes);
  my $tail = $self->{stderr_tail} //= [];
  push @$tail, map { s/^\s+|\s+$//gr } grep {/\S/} split /\r?\n/, $bytes;
  splice @$tail, 0, @$tail - STDERR_LINES if @$tail > STDERR_LINES;
  return $self;
}

# The exit of the docker CLI is the container's exit -- or Docker's own error,
# exit 125 -- and what it printed says why, so the warning carries it.
sub _exit_hint ($self, $status) {
  $self->{exit_status} = $status;
  my $tail = $self->stderr_tail;
  return length $tail ? ": $tail" : '';
}

sub _on_close ($self) {
  return $self unless $self->{pid};    # already handled
  my $deliberate = $self->{retiring};
  $self->_drain_stderr;
  $self->SUPER::_on_close;

  if (!$deliberate && (my $owner = $self->owner)) {
    my $why  = 'exited (' . MCP::Hub::Upstream::Stdio::_exit_reason($self->{exit_status}) . ')';
    my $tail = $self->stderr_tail;
    $owner->_engine_down($self, length $tail ? "$why: $tail" : $why);
  }

  $self->_teardown;
  return $self;
}

# The CLI's stdout and stderr end together, and the IOLoop may see the end of
# stdout first -- under load, with both ready at once. The stdio transport then
# drops the stderr pipe with Docker's own message still unread in it, so what
# is there is read first. A CLI that lingers, writing on, is not waited for.
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

1;

=encoding utf8

=head1 SYNOPSIS

  # Built by MCP::Hub::Upstream::Docker for a start that talks stdio:
  my $engine = MCP::Hub::Upstream::Docker::Stdio->new(
    name     => 'github',
    config   => {type => 'stdio', command => 'docker', args => ['run', '-i', '--rm', ...]},
    teardown => sub ($engine) { ... },
    ...
  );

=head1 DESCRIPTION

The stdio engine of an L<MCP::Hub::Upstream::Docker> (or
L<MCP::Hub::Upstream::Compose>): the C<docker run -i --rm ...> (or C<docker compose
run --rm -T ...>) command line is spawned as an ordinary
L<MCP::Hub::Upstream::Stdio> child, and the container's stdin and stdout are the
JSON-RPC channel. It lives for one container run; see
L<MCP::Hub::Upstream::Docker::Engine> for what it shares with its owner.

On top of the stdio transport it keeps the last lines of the container's
stderr for error messages (read to the end before an exit is handled, so that
Docker's own message is not lost), reports an exit it did not ask for to its
owner, and removes the container once the CLI is gone, in case the CLI was
killed before it could.

=head1 METHODS

L<MCP::Hub::Upstream::Docker::Stdio> inherits all methods from
L<MCP::Hub::Upstream::Docker::Engine> and L<MCP::Hub::Upstream::Stdio> and
implements the following new ones.

=method retire

  $engine->retire;

Stop the CLI (and with it the container), or clean up right away when there is
no CLI.

=method stop

  $engine->stop;

The stdio stop, marked as asked for: an exit after it is no news to the owner.
Any other end of the CLI -- a crash, or the transport killing it for a line
over its limit -- is reported to the owner as the container gone.

=method stderr_tail

  my $text = $engine->stderr_tail;

The last lines of the container's stderr, joined on one line.

=head1 SEE ALSO

L<MCP::Hub::Upstream::Docker>, L<MCP::Hub::Upstream::Docker::Engine>.

=cut
