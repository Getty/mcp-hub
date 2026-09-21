package MCP::Hub::Command::daemon;
our $VERSION = '0.001';
use Mojo::Base 'Mojolicious::Command::daemon', -signatures;

# ABSTRACT: Run the hub in the foreground as a single process

has description => 'Run the MCP hub in the foreground';

sub run ($self, @args) {
  @args = $self->default_listen(@args);

  # Only the daemon starts upstreams: kick off background manifest fetches (and
  # any always_on servers) now, before the event loop starts serving.
  $self->app->start_background_fetches;

  # ...and only the daemon reloads itself. SIGHUP and the hub.auto_reload
  # watcher are meaningless in config, status, refresh or token, which are gone
  # again in milliseconds.
  $self->app->watch_sighup;
  $self->app->start_config_watch;

  return $self->SUPER::run(@args);
}

sub default_listen ($self, @args) {
  # Default the listen address to the one in the configuration, unless the
  # caller already passed -l/--listen. The hub must run as a single process,
  # so this is the plain daemon, never hypnotoad or a pre-forking server.
  return @args if grep { $_ eq '-l' || $_ eq '--listen' } @args;
  return ('-l', $self->app->hub_config->listen, @args);
}

1;

=encoding utf8

=head1 SYNOPSIS

  mcp-hub daemon
  mcp-hub daemon -l http://127.0.0.1:9000

  kill -HUP $(pidof mcp-hub)           # reload the configuration

=head1 DESCRIPTION

L<MCP::Hub::Command::daemon> runs the hub in the foreground with
L<Mojo::Server::Daemon>, defaulting the listen address to the C<listen> value in
the configuration. It is the ordinary L<Mojolicious::Command::daemon>, so
C<-m>/C<--mode>, C<-i>/C<--inactivity-timeout>, C<$MOJO_LOG_LEVEL> and the other
daemon options and environment variables all apply.

The hub must not run under hypnotoad or a pre-forking server, so there is no
C<prefork> command: every worker would spawn its own child processes and hold
its own state.

=head2 Reloading

The daemon is the only command that reloads itself, and it has three ways in:

=over 2

=item B<C<SIGHUP>>

Installed here, not in the other commands. The handler does nothing but queue
the reload on the event loop, and several signals arriving together collapse
into one reload. Where L<EV> is the reactor -- which it is whenever L<EV> is
installed -- an L<EV> signal watcher is used rather than C<%SIG>, because a
plain C<%SIG> handler is only dispatched when the loop happens to wake up for
something else.

=item B<C<hub.auto_reload>>

When the configuration sets it, the daemon watches the configuration file and
reloads when it changes. See L<MCP::Hub/start_config_watch>.

=item B<C<POST /_hub/reload>>

Behind C<mcp-hub reload>, which -- unlike a signal -- prints what changed, or
why the new configuration was refused.

=back

All three end in the same L<MCP::Hub/reload>, so they behave identically: only
what actually changed in the file is touched, and a configuration that does not
validate leaves the running one fully in effect. C<hub.listen> is the one thing
a reload cannot apply -- that needs a restart, and the reload says so.

=head1 METHODS

=head2 default_listen

  my @args = $command->default_listen(@args);

Return the daemon arguments with C<-l> prepended to the configured listen
address, unless the caller already passed C<-l>/C<--listen>.

=head1 SEE ALSO

L<mcp-hub>, L<MCP::Hub>, L<Mojolicious::Command::daemon>.

=cut
