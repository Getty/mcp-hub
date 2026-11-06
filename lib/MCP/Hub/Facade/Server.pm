package MCP::Hub::Facade::Server;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Server', -signatures;

# ABSTRACT: An MCP::Server whose list rendering keeps upstream extra fields

has extra => sub { {prompts => {}, resources => {}} };

sub _handle_tools_list ($self, $context) {
  local $self->{_listing} = {};
  my ($result, $hints) = $self->SUPER::_handle_tools_list($context);
  for my $pair (_pairs($result->{tools}, $self->{_listing}{tools}, $context)) {
    my ($info, $tool) = @$pair;
    _merge($info, $tool->extra) if $tool->can('extra');
  }
  return ($result, $hints);
}

sub _handle_prompts_list ($self, $context) {
  local $self->{_listing} = {};
  my ($result, $hints) = $self->SUPER::_handle_prompts_list($context);
  for my $pair (_pairs($result->{prompts}, $self->{_listing}{prompts}, $context)) {
    _merge($pair->[0], $self->_prompt_extra($pair->[1]));
  }
  return ($result, $hints);
}

# The extras of one prompt: by its name, unique on a server's own endpoint.
sub _prompt_extra ($self, $prompt) { return ($self->extra->{prompts} // {})->{$prompt->name} }

# MCP::Server renders a list from what the tools or prompts event left of it
# and keeps those objects to itself. While a list is rendered, these hand them
# on, so each rendered entry is matched to its own object (_pairs).
sub _tools ($self, $context) {
  my $tools = $self->SUPER::_tools($context);
  $self->{_listing}{tools} = $tools if $self->{_listing};
  return $tools;
}

sub _prompts ($self, $context) {
  my $prompts = $self->SUPER::_prompts($context);
  $self->{_listing}{prompts} = $prompts if $self->{_listing};
  return $prompts;
}

# Each rendered entry with the object it was rendered from. The rendering keeps
# the event's order and leaves out what the request's scopes do not cover, so
# the same scope check lines them up by position -- a name would not: two
# entries can share one (two upstreams' on /all), and the last would lend its
# fields to both. A position whose names differ is left unmerged rather than
# given another entry's fields.
sub _pairs ($rendered, $objects, $context) {
  my @listed = grep { $context->has_scope(@{$_->scopes}) } @{$objects // []};
  return map { [$rendered->[$_], $listed[$_]] }
    grep { $listed[$_] && $listed[$_]->name eq $rendered->[$_]{name} } 0 .. $#$rendered;
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
upstream, and the base of L<MCP::Hub::Aggregate> at C</all>. It is a plain
server in every respect except that its C<tools/list>, C<prompts/list> and
C<resources/list> rendering merges the C<title>, C<icons> and C<_meta> fields
the upstream reported back into each entry.

L<MCP::Server> renders only the specification's own fields, so without this an
upstream's C<title> or a Claude Code-specific C<_meta> annotation would be
dropped on the way through the hub. Tool extras are read from each
L<MCP::Hub::Facade::Tool>'s C<extra>; prompt and resource extras from
L</extra>, keyed by name and URI.

Each entry of a rendered tool or prompt list is matched to the object it was
rendered from by its position in the list, not by its name: on
L<MCP::Hub::Aggregate> two entries can share a name, and each must keep its own
fields.

=head1 ATTRIBUTES

L<MCP::Hub::Facade::Server> inherits all attributes from L<MCP::Server> and adds:

=attr extra

  my $extra = $server->extra;

Hash reference C<< { prompts => { name => {...} }, resources => { uri => {...} } } >>
holding the C<title>, C<icons> and C<_meta> fields of prompts and resources.

=head1 SEE ALSO

L<MCP::Hub::Facade>, L<MCP::Hub::Facade::Tool>, L<MCP::Hub::Aggregate>, L<MCP::Server>.

=cut
