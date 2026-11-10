package MCP::Hub::Endpoint;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Server::Transport::HTTP', -signatures;

use Mojo::Promise;

# ABSTRACT: The HTTP transport each endpoint of the hub is served by

# The server is held by whoever mounts it -- its upstream, or the hub for /all --
# never by its transport. MCP's to_action has server and transport hold each
# other: a cycle that kept every server once served on its endpoint -- a facade
# with its manifest, an in-process class instance -- alive after a reload had
# let go of its upstream.
has server => undef, weak => 1;

# The requests whose answer runs code of the server's own.
my %CALLS = map { $_ => 1 } qw(tools/call prompts/get resources/read);

# What MCP's to_action does, with this transport in place of its own.
sub action ($class, $server) {
  $server->transport(my $endpoint = $class->new(server => $server, streaming => 1));
  return sub ($c) { $endpoint->handle_request($c) };
}

# A call the server answered there and then -- an in-process class runs in the
# hub's loop -- is handed on as a promise all the same, as every call to an
# upstream outside is, so the transport streams the answer, and on the way turns
# off the connection's inactivity timeout. Rendered directly, the answer to a
# call that held the loop longer than that timeout was lost: under EV the timer,
# re-armed with the loop's time from before the call, fired as soon as the loop
# went on, and closed the connection. An answer that is not a result -- an error
# the server reports, with a status of its own -- goes out as it is.
sub _handle ($self, $data, $context) {
  my $answer = $self->SUPER::_handle($data, $context);
  return $answer unless $CALLS{$data->{method} // ''} && ref $answer eq 'HASH' && $answer->{result};
  return $answer if defined $context->status;
  return Mojo::Promise->resolve($answer);
}

1;

=encoding utf8

=head1 SYNOPSIS

  use MCP::Hub::Endpoint;

  my $action = MCP::Hub::Endpoint->action($server);
  $routes->post('/mine' => $action);

=head1 DESCRIPTION

L<MCP::Hub::Endpoint> is the L<MCP::Server::Transport::HTTP> each endpoint of
L<MCP::Hub> is served by: the C<< /<name> >> of every upstream
(L<MCP::Hub::Upstream/action>) and C</all>. It differs from the one
L<MCP::Server/to_action> builds in two ways.

B<It holds its server weakly.> Whoever mounts the server keeps it -- the
upstream, or the hub for C</all> -- so that a server goes with the upstream a
reload replaces or removes. A transport holding its server, and the server it,
kept every server ever served on its endpoint alive for the life of the daemon.

B<It streams every call.> The answer to a C<tools/call>, C<prompts/get> or
C<resources/read> that the server gives there and then -- an in-process class
(L<MCP::Hub::Upstream::Perl>) runs its code in the hub's event loop -- is handed
on as a promise, as the answer of every upstream outside the hub is, so it goes
out as an event stream and the connection's inactivity timeout is off while it
does. Rendered directly, a call that blocked the loop longer than that timeout
(C<MOJO_INACTIVITY_TIMEOUT>, 30 seconds by default) lost its answer under
L<Mojo::Reactor::EV>: the timer, re-armed with the loop's time from before the
call, fired as soon as the loop went on, and the agent saw the connection close.
The answer itself -- C<content>, C<isError>, C<structuredContent> -- is the
server's, unchanged. An error the server answers with, and its HTTP status, go
out as they are.

=head1 ATTRIBUTES

L<MCP::Hub::Endpoint> inherits all attributes from
L<MCP::Server::Transport::HTTP>, and changes this one.

=attr server

The L<MCP::Server> served, held weakly.

=head1 METHODS

L<MCP::Hub::Endpoint> inherits all methods from L<MCP::Server::Transport::HTTP>,
and implements this one.

=method action

  my $action = MCP::Hub::Endpoint->action($server);

Make an endpoint for C<$server>, with streaming on, the server's
L<MCP::Server/transport>, and return the L<Mojolicious> action that serves
requests through it, as L<MCP::Server/to_action> does with its own transport.

=head1 SEE ALSO

L<MCP::Hub>, L<MCP::Hub::Upstream>, L<MCP::Server::Transport::HTTP>.

=cut
