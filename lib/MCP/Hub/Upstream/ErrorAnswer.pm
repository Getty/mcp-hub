package MCP::Hub::Upstream::ErrorAnswer;
our $VERSION = '0.001';
use Mojo::Base -base, -signatures;

use overload '""' => sub ($self, @) { $self->message }, bool => sub { 1 }, fallback => 1;

# ABSTRACT: The JSON-RPC error an upstream answered a request with

# The error member of the answer, as it came, and the text it reads as.
has 'error';
has 'message';

1;

=encoding utf8

=head1 SYNOPSIS

  use MCP::Hub::Upstream::ErrorAnswer;

  # A transport, on an answer that carries an error:
  $pending->reject(MCP::Hub::Upstream::ErrorAnswer->new(
    error   => $msg->{error},
    message => "upstream $name: $msg->{error}{message}",
  ));

  # Whoever reads the rejection:
  print "$err\n";    # upstream NAME: the error's message, either way
  my $answered = blessed $err && $err->isa('MCP::Hub::Upstream::ErrorAnswer');

=head1 DESCRIPTION

A request an upstream answers with a JSON-RPC error is rejected with one of
these; a request that fails without an answer -- it timed out, a stop cut it
off, the child or the connection went -- with a plain string. Both read the same
as text: the object stringifies to L</message>, so whatever only reports a
failure -- an error result, a log line, a C<503> -- need not tell them apart.

The hub's reading of an upstream's lists does. A C<prompts/list> or
C<resources/list> answered with an error says that the upstream has none to
list; one that got no answer says nothing about them, and a refresh cut short
there keeps the manifest it was to replace (see
L<MCP::Hub::Upstream/refresh_p>).

=head1 ATTRIBUTES

=attr error

The C<error> member of the answer, as the upstream sent it: normally an object
with C<code> and C<message>, but whatever shape it came in.

=attr message

What the rejection reads as: C<upstream NAME: >, then the error's message.

=head1 SEE ALSO

L<MCP::Hub::Upstream>.

=cut
