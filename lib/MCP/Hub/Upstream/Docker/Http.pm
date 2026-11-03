package MCP::Hub::Upstream::Docker::Http;
our $VERSION = '0.001';
use Mojo::Base -strict, -signatures;

use MCP::Hub::Upstream::Docker::Engine;
use MCP::Hub::Upstream::Http;

# ABSTRACT: An HTTP container as the transport of a Docker upstream

# The engine's methods first, then the HTTP transport they wrap.
our @ISA = qw(MCP::Hub::Upstream::Docker::Engine MCP::Hub::Upstream::Http);

# Where the container answers. Only known once Docker has published its port,
# after the engine is built.
sub url ($self, @url) {
  return $self->{url} unless @url;
  $self->{url} = $url[0];
  return $self;
}

sub retire ($self) {
  $self->stop;
  $self->_teardown;
  return $self;
}

# A dropped SSE stream while serving is the server going away.
sub _sse_closed ($self) {
  my $serving = !$self->{stopping} && $self->state eq 'ready';
  $self->SUPER::_sse_closed;
  if ($serving && (my $owner = $self->owner)) { $owner->_engine_down($self, 'the SSE stream closed') }
  return $self;
}

1;

=encoding utf8

=head1 SYNOPSIS

  # Built by MCP::Hub::Upstream::Docker for a start that talks HTTP:
  my $engine = MCP::Hub::Upstream::Docker::Http->new(
    name     => 'crawl4ai',
    config   => {type => 'sse', url => undef, headers => {}},
    teardown => sub ($engine) { ... },
    ...
  );
  $engine->url('http://127.0.0.1:49153/mcp/sse');

=head1 DESCRIPTION

The HTTP engine of an L<MCP::Hub::Upstream::Docker> (or
L<MCP::Hub::Upstream::Compose>): once the container runs and answers on its
port, it is spoken to exactly like a C<url> upstream, over Streamable HTTP or
HTTP+SSE, by the L<MCP::Hub::Upstream::Http> transport it inherits. It lives for
one container run; see L<MCP::Hub::Upstream::Docker::Engine> for what it shares
with its owner. Starting the container, finding its port and waiting until it
answers are the owner's part.

=head1 METHODS

L<MCP::Hub::Upstream::Docker::Http> inherits all methods from
L<MCP::Hub::Upstream::Docker::Engine> and L<MCP::Hub::Upstream::Http> and
implements the following new ones.

=method retire

  $engine->retire;

Close the connection and stop and remove the container.

=method url

  my $url = $engine->url;
  $engine->url('http://127.0.0.1:49153/mcp');

The URL the container answers on.

=head1 SEE ALSO

L<MCP::Hub::Upstream::Docker>, L<MCP::Hub::Upstream::Docker::Engine>.

=cut
