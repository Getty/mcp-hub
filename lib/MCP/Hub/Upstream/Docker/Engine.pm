package MCP::Hub::Upstream::Docker::Engine;
our $VERSION = '0.001';
use Mojo::Base -strict, -signatures;

use Mojo::Promise;

# ABSTRACT: What the transport of one container run shares with the upstream it serves

# Not a class of its own: the methods the two engines,
# MCP::Hub::Upstream::Docker::Stdio and MCP::Hub::Upstream::Docker::Http, put in
# front of the transport they inherit.

sub owner ($self) { return $self->{owner} }
sub run   ($self) { return $self->{run} }

# The engine is mounted nowhere. It carries the requests of the upstream that
# owns it, and what it learns about the server goes into that upstream's
# façade and manifest.
sub _build_server ($self) { return $self->server }
sub _hash         ($self) { return $self->{hash} }

sub _apply_manifest ($self, $manifest) {
  my $owner = $self->owner or return $self;
  $owner->_apply_manifest($manifest);
  return $self;
}

# A refresh of the container holds off the idle countdown of the upstream that
# owns it, as a call does: the engine has none (MCP::Hub::Upstream::_held_p).
sub _held_p ($self, $promise) {
  my $owner = $self->owner or return $promise;
  return $owner->_held_p($promise);
}

# Crash loops are the owning upstream's to count, over every start and every
# container: an engine lives for a single run.
sub _record_exit    ($self, @) { return $self }
sub _record_failure ($self, @) { return $self }

# Resolves once the container of this run is gone.
sub down_p ($self) { return $self->{down} //= Mojo::Promise->new }

# Remove what this run left behind -- once, however often it is asked -- and
# stop watching its container. A cleanup that fails is logged; the run counts
# as gone all the same, so that a daemon that cannot be reached never holds up
# a shutdown or the next start.
sub _teardown ($self) {
  my $down = $self->down_p;
  return $down if $self->{torn_down}++;

  if (my $unwatch = delete $self->{unwatch}) { $unwatch->() }
  my $teardown = $self->{teardown};
  my $cleanup  = $teardown ? eval { $teardown->($self) } : undef;
  $self->log->warn("[@{[$self->name]}] cleanup failed: $@") if $@;
  ($cleanup // Mojo::Promise->resolve)->catch(sub ($err) { $self->log->warn("[@{[$self->name]}] cleanup failed: $err") })
    ->finally(sub { $down->resolve });
  return $down;
}

1;

=encoding utf8

=head1 SYNOPSIS

  package MCP::Hub::Upstream::Docker::Stdio;
  use Mojo::Base -strict, -signatures;
  our @ISA = qw(MCP::Hub::Upstream::Docker::Engine MCP::Hub::Upstream::Stdio);

=head1 DESCRIPTION

An L<MCP::Hub::Upstream::Docker> decides on every start whether it talks to its
container over stdio or over HTTP, so the transport cannot be its class. Each
start builds an I<engine> instead -- an L<MCP::Hub::Upstream::Docker::Stdio> or an
L<MCP::Hub::Upstream::Docker::Http> -- that inherits the transport from
L<MCP::Hub::Upstream::Stdio> or L<MCP::Hub::Upstream::Http> and lives for that
one container run.

This package holds what both engines put in front of that transport: they
share the owning upstream's façade and manifest hash, hand every manifest they
fetch to the owner, leave crash-loop accounting to it, and remove their
container once, through the cleanup the owner gave them.

=head1 METHODS

=method down_p

  $engine->down_p->then(sub { ... });

Resolves once this run's container is gone.

=method owner

The L<MCP::Hub::Upstream::Docker> this engine serves, held weakly.

=method run

The id in this run's C<mcp-hub.run> label.

=head1 SEE ALSO

L<MCP::Hub::Upstream::Docker>, L<MCP::Hub::Upstream::Docker::Stdio>,
L<MCP::Hub::Upstream::Docker::Http>.

=cut
