package MCP::Hub::Command::token;
our $VERSION = '0.001';
use Mojo::Base 'Mojolicious::Command', -signatures;

use Crypt::Misc qw(encode_b64u);
use Crypt::PRNG qw(random_bytes);

# ABSTRACT: Print a fresh random bearer token

has description => 'Print a fresh random bearer token to paste into clients';
has usage       => "Usage: mcp-hub token\n";

sub run ($self, @args) {
  print encode_b64u(random_bytes(32)), "\n";
  return;
}

1;

=encoding utf8

=head1 SYNOPSIS

  mcp-hub token

=head1 DESCRIPTION

L<MCP::Hub::Command::token> prints 32 random bytes as a base64url string, to
paste into a client's C<token> in the configuration. It never touches the
configuration file.

=head1 SEE ALSO

L<mcp-hub>, L<MCP::Hub>.

=cut
