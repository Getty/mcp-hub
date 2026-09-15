package MCP::Hub::Facade::Tool;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Tool', -signatures;

# ABSTRACT: A tool that forwards to an upstream, with validation disabled

has extra => sub { {} };

# The upstream validates its own arguments, and it accepts schemas that
# JSON::Schema::Tiny rejects (deeply $ref-heavy ones). Re-validating here would
# reject calls the upstream would happily serve, so the facade does not.
sub validate_input ($self, $args) { return 0 }

1;

=encoding utf8

=head1 SYNOPSIS

  use MCP::Hub::Facade::Tool;

  my $tool = MCP::Hub::Facade::Tool->new(
    name  => 'resolve-library-id',
    extra => {title => 'Resolve library id', _meta => {...}},
    code  => sub ($tool, $args) { $upstream->call_tool($tool->name, $args) },
  );

=head1 DESCRIPTION

L<MCP::Hub::Facade::Tool> is the L<MCP::Tool> the hub mounts for each tool an
upstream reports. It differs from a plain tool in two ways.

Input validation is disabled. The upstream validates its own arguments, and it
may advertise a schema L<JSON::Schema::Tiny> cannot compile -- a C<$ref>-heavy
one, say -- which would make the hub reject calls the upstream would serve. The
hub trusts the upstream and forwards the arguments untouched.

It carries an L</extra> hash with the C<title>, C<icons> and C<_meta> fields of
the upstream's manifest entry, which L<MCP::Server> does not render in
C<tools/list>. L<MCP::Hub::Facade::Server> merges them back in, so
Claude Code-specific annotations such as C<_meta["anthropic/maxResultSizeChars"]>
survive the trip through the hub.

=head1 ATTRIBUTES

L<MCP::Hub::Facade::Tool> inherits all attributes from L<MCP::Tool> and adds:

=head2 extra

  my $extra = $tool->extra;

Hash reference with the C<title>, C<icons> and C<_meta> fields of the manifest
entry, present only when the upstream declared them.

=head1 METHODS

L<MCP::Hub::Facade::Tool> inherits all methods from L<MCP::Tool> and overrides:

=head2 validate_input

  my $bool = $tool->validate_input($args);

Always returns false (validation passed), so the upstream is the only validator.

=head1 SEE ALSO

L<MCP::Hub::Facade>, L<MCP::Hub::Facade::Server>, L<MCP::Tool>.

=cut
