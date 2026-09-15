package MCP::Hub::Native::Status;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Server', -signatures;

use Mojo::JSON qw(encode_json);

# ABSTRACT: Native MCP server exposing hub introspection and refresh

has 'hub';

sub new ($class, %args) {
  my $self = $class->SUPER::new(name => 'hub', version => $VERSION, %args);
  $self->instructions('Inspect and refresh the MCP hub itself.');
  $self->_register;
  return $self;
}

sub _register ($self) {
  $self->tool(
    name         => 'hub_status',
    description  => 'Report the state of every upstream and the known clients',
    input_schema => {type => 'object'},
    code         => sub ($tool, $args) {
      return $tool->text_result('hub status is unavailable', 1) unless $self->hub;
      return _json($tool, $self->hub->status_report);
    },
  );

  $self->tool(
    name         => 'hub_refresh',
    description  => 'Re-fetch upstream manifests; give a name to refresh just one',
    input_schema => {
      type       => 'object',
      properties => {name => {type => 'string', description => 'A single server to refresh'}},
    },
    code => sub ($tool, $args) {
      my $hub = $self->hub or return $tool->text_result('hub is unavailable', 1);

      if ($hub->hub_config->mode eq 'clients') {
        my $c       = $tool->context->controller;
        my $profile = $c ? $c->stash('mcp.profile') : undef;
        return $tool->text_result('hub_refresh requires an admin profile', 1)
          unless $profile && $profile->{admin};
      }

      return $hub->refresh_p($args->{name})->then(sub ($counts) { _json($tool, $counts) });
    },
  );

  return $self;
}

sub _json ($tool, $data) {
  return {
    content           => [{type => 'text', text => encode_json($data)}],
    structuredContent => (ref $data eq 'HASH' ? $data : {results => $data}),
  };
}

1;

=encoding utf8

=head1 SYNOPSIS

  use MCP::Hub::Native::Status;

  my $server = MCP::Hub::Native::Status->new(hub => $hub);

=head1 DESCRIPTION

L<MCP::Hub::Native::Status> exposes the hub's own state to agents. It receives
the L<MCP::Hub> instance (the hub injects it, because the class has a C<hub>
attribute) and offers two tools.

=head2 hub_status

The same structure as C<GET /_hub/status>: a row per upstream with C<name>,
C<type>, C<state>, C<pid>, C<rss_kb>, C<manifest_fetched_at>, C<last_used>,
C<calls> and C<errors>, plus the known clients.

=head2 hub_refresh

Re-fetch upstream manifests and return the new tool counts. Takes an optional
C<name> to refresh a single server. In clients mode it requires an admin
profile, otherwise it returns an error result.

=head1 ATTRIBUTES

L<MCP::Hub::Native::Status> inherits all attributes from L<MCP::Server> and adds:

=head2 hub

The L<MCP::Hub> instance this server reports on.

=head1 SEE ALSO

L<MCP::Hub>, L<MCP::Server>.

=cut
