package ComposedEcho;
use Mojo::Base -base, -signatures;

# Option (a): not an MCP::Server itself, but has a `server` method returning
# one -- the way MCP::Wiki::Server is built.

use EchoServer;

has server => sub { EchoServer->new(name => 'composed-echo') };

1;
