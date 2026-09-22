package MCP::Hub::Facade::Server;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Server', -signatures;

# ABSTRACT: An MCP::Server whose list rendering keeps upstream extra fields

has extra => sub { {prompts => {}, resources => {}} };

sub _handle_tools_list ($self, $context) {
  my ($result, $hints) = $self->SUPER::_handle_tools_list($context);
  my %by_name = map { $_->name => $_ } @{$self->tools};
  for my $info (@{$result->{tools}}) {
    my $tool = $by_name{$info->{name}};
    next unless $tool && $tool->can('extra');
    _merge($info, $tool->extra);
  }
  return ($result, $hints);
}

sub _handle_prompts_list ($self, $context) {
  my ($result, $hints) = $self->SUPER::_handle_prompts_list($context);
  my $extra = $self->extra->{prompts} // {};
  for my $info (@{$result->{prompts}}) { _merge($info, $extra->{$info->{name}}) }
  return ($result, $hints);
}

sub _handle_resources_list ($self, $context) {
  my ($result, $hints) = $self->SUPER::_handle_resources_list($context);
  my $extra = $self->extra->{resources} // {};
  for my $info (@{$result->{resources}}) { _merge($info, $extra->{$info->{uri}}) }
  return ($result, $hints);
}

sub _merge ($info, $extra) {
  return unless ref $extra eq 'HASH';
  for my $key (qw(title icons _meta)) {
    $info->{$key} = $extra->{$key} if defined $extra->{$key};
  }
  return $info;
}

1;

=encoding utf8

=head1 SYNOPSIS

  use MCP::Hub::Facade::Server;

  my $server = MCP::Hub::Facade::Server->new(name => 'context7');
  $server->extra->{prompts}{my_prompt} = {title => 'My prompt'};

=head1 DESCRIPTION

L<MCP::Hub::Facade::Server> is the L<MCP::Server> the hub mounts for each stdio
upstream. It is a plain server in every respect except that its C<tools/list>,
C<prompts/list> and C<resources/list> rendering merges the C<title>, C<icons>
and C<_meta> fields the upstream reported back into each entry.

L<MCP::Server> renders only the specification's own fields, so without this an
upstream's C<title> or a Claude Code-specific C<_meta> annotation would be
dropped on the way through the hub. Tool extras are read from each
L<MCP::Hub::Facade::Tool>'s C<extra>; prompt and resource extras from
L</extra>, keyed by name and URI.

=head1 ATTRIBUTES

L<MCP::Hub::Facade::Server> inherits all attributes from L<MCP::Server> and adds:

=attr extra

  my $extra = $server->extra;

Hash reference C<< { prompts => { name => {...} }, resources => { uri => {...} } } >>
holding the C<title>, C<icons> and C<_meta> fields of prompts and resources.

=head1 SEE ALSO

L<MCP::Hub::Facade>, L<MCP::Hub::Facade::Tool>, L<MCP::Server>.

=cut
