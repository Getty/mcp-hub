package MCP::Hub::Upstream::Perl;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Hub::Upstream', -signatures;

use Mojo::Promise;

# ABSTRACT: An in-process Perl MCP::Server mounted as an upstream

sub new ($class, %args) {
  my $self = $class->SUPER::new(%args);
  $self->_load;
  return $self;
}

sub start_p   ($self) { return Mojo::Promise->resolve($self) }
sub stop      ($self) { return $self }
sub refresh_p ($self) { return Mojo::Promise->resolve($self) }

sub _load ($self) {
  my $target = $self->_load_class;

  my %args = %{$self->config->{class_args} // {}};
  $args{hub} = $self->hub if $self->hub && $target->can('hub');

  # The instance is kept, not only its server: a class that holds its server
  # (option (a)) may be referenced by that server's tools only weakly.
  my $instance = $target->new(%args);
  $self->server($self->_server_of($instance));
  $self->{instance} = $instance;
  $self->state('ready');
  return $self;
}

1;

=encoding utf8

=head1 SYNOPSIS

  use MCP::Hub::Upstream::Perl;

  my $upstream = MCP::Hub::Upstream::Perl->new(
    name   => 'run',
    config => {type => 'perl', class => 'MCP::Run', class_args => {allowed_commands => ['ls']}},
    hub    => $hub,
  );

=head1 DESCRIPTION

L<MCP::Hub::Upstream::Perl> mounts a Perl MCP server class as an upstream
without a subprocess. The class named in the configuration is loaded with
L<Mojo::Loader> and instantiated once, with the entry's C<args> as it is (no
C<${VAR}>, no C<~>). The class is either an L<MCP::Server> subclass, whose
instance becomes L<MCP::Hub::Upstream/server>, or a class whose instances
B<hold> a server and hand it out from a C<server> method -- a Moo class with
C<has server>, say, as L<MCP::Wiki::Server> is. Either way that server answers
C<tools/list> itself, so there is no manifest and no cache. A class that cannot
be loaded, or is neither kind, makes the constructor die -- the hub turns that
entry into a C<failed> upstream carrying the reason.

B<A slow tool stalls the whole hub.> An in-process server runs inside the hub's
one event loop: a tool that blocks -- a long git walk, a big file read, a
synchronous HTTP request -- holds up every other upstream and every agent until
it returns. Mount such a class with C<"hub": {"fork": true}> instead, which runs
its calls in a worker of their own (L<MCP::Hub::Upstream::Fork>), or as a stdio
C<command>.

If the class has a C<hub> attribute -- as L<MCP::Hub::Native::Status> does -- the
L<MCP::Hub> instance is injected into its constructor.

The state is always C<ready>; L<MCP::Hub::Upstream/stop> and
L<MCP::Hub::Upstream/refresh_p> are no-ops.

=head1 METHODS

L<MCP::Hub::Upstream::Perl> inherits all methods from L<MCP::Hub::Upstream>.

=method start_p

Resolves immediately; there is nothing to start.

=head1 SEE ALSO

L<MCP::Hub::Upstream>, L<MCP::Hub::Upstream::Fork>, L<MCP::Server>.

=cut
