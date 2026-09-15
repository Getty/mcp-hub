package MCP::Hub::Upstream::Perl;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Hub::Upstream', -signatures;

use Mojo::Loader qw(load_class);
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
  my $target = $self->config->{class};
  if (my $err = load_class($target)) {
    die "cannot load class $target: " . (ref $err ? "$err" : 'class not found') . "\n";
  }
  die "$target is not an MCP::Server subclass\n" unless $target->isa('MCP::Server');

  my %args = %{$self->config->{class_args} // {}};
  $args{hub} = $self->hub if $self->hub && $target->can('hub');

  $self->server($target->new(%args));
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

L<MCP::Hub::Upstream::Perl> mounts any L<MCP::Server> subclass as an upstream
without a subprocess. The class named in the configuration is loaded with
L<Mojo::Loader> and instantiated once; its instance becomes L</server> and
answers C<tools/list> itself, so there is no manifest and no cache.

If the class has a C<hub> attribute -- as L<MCP::Hub::Native::Status> does -- the
L<MCP::Hub> instance is injected into its constructor.

The state is always C<ready>; L</stop> and L</refresh_p> are no-ops.

=head1 METHODS

L<MCP::Hub::Upstream::Perl> inherits all methods from L<MCP::Hub::Upstream>.

=head2 start_p

Resolves immediately; there is nothing to start.

=head1 SEE ALSO

L<MCP::Hub::Upstream>, L<MCP::Server>.

=cut
