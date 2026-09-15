package MCP::Hub::Command::daemon;
our $VERSION = '0.001';
use Mojo::Base 'Mojolicious::Command::daemon', -signatures;

# ABSTRACT: Run the hub in the foreground as a single process

has description => 'Run the MCP hub in the foreground';

sub run ($self, @args) {
  # Default the listen address to the one in the configuration, unless the
  # caller already passed -l/--listen. The hub must run as a single process,
  # so this is the plain daemon, never hypnotoad or a pre-forking server.
  unless (grep { $_ eq '-l' || $_ eq '--listen' } @args) {
    unshift @args, '-l', $self->app->hub_config->listen;
  }

  # Only the daemon starts upstreams: kick off background manifest fetches (and
  # any always_on servers) now, before the event loop starts serving.
  $self->app->start_background_fetches;

  return $self->SUPER::run(@args);
}

1;

=encoding utf8

=head1 SYNOPSIS

  mcp-hub daemon
  mcp-hub daemon -l http://127.0.0.1:9000

=head1 DESCRIPTION

L<MCP::Hub::Command::daemon> runs the hub in the foreground with
L<Mojo::Server::Daemon>, defaulting the listen address to the C<listen> value in
the configuration. It is the ordinary L<Mojolicious::Command::daemon>, so
C<--log-level>, C<MOJO_LOG_LEVEL> and the other daemon options all apply.

The hub must not run under hypnotoad or a pre-forking server, so there is no
C<prefork> command: every worker would spawn its own child processes and hold
its own state.

=head1 SEE ALSO

L<mcp-hub>, L<MCP::Hub>, L<Mojolicious::Command::daemon>.

=cut
