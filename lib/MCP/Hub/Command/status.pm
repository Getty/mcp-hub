package MCP::Hub::Command::status;
our $VERSION = '0.001';
use Mojo::Base 'Mojolicious::Command', -signatures;

use Getopt::Long   qw(GetOptionsFromArray :config no_auto_abbrev no_ignore_case);
use Mojo::UserAgent;

# ABSTRACT: Show the running hub's status as a table

has description => 'Show the running hub status as a table';
has usage       => <<'USAGE';
Usage: mcp-hub status [--client NAME] [--url BASE] [--token TOKEN]

Options:
  --client NAME   Client whose token to authenticate with (default: first admin client)
  --url BASE      Base URL of the running hub (default derived from the listen address)
  --token TOKEN   Bearer token to authenticate with, instead of a configured client
                  (or $MCP_HUB_TOKEN); with --url the config file is never read
USAGE

sub run ($self, @args) {
  GetOptionsFromArray(\@args,
    'client=s' => \my $client, 'url=s' => \my $url, 'token=s' => \my $token) or die $self->usage;

  my ($base, $headers) = _endpoint($self->app, $url, $client, $token);

  my $tx = Mojo::UserAgent->new->get("$base/_hub/status" => $headers);
  if (my $err = $tx->error) {
    return print "hub is not running at $base ($err->{message})\n" unless $err->{code};
    die "status request failed: $err->{code} $err->{message}\n";
  }

  _print_table($tx->res->json);
  return;
}

# The base URL and auth headers for talking to the daemon, shared by status,
# refresh and reload. Given both --url and an explicit token (flag or
# $MCP_HUB_TOKEN) the on-disk config is never read, so a broken config file does
# not stop a command that was told exactly where the daemon is and how to auth.
# Otherwise the listen address and/or the admin token come from the config,
# which must load and validate now (assert_config -- a clean error if it does
# not).
sub _endpoint ($app, $url, $client, $token) {
  $token = $ENV{MCP_HUB_TOKEN} unless defined $token && length $token;

  if (defined $url && defined $token && length $token) {
    return (MCP::Hub::_base_url($url), {Authorization => "Bearer $token"});
  }

  $app->assert_config;
  my $base = MCP::Hub::_base_url($url // $app->hub_config->listen);
  return ($base, {Authorization => "Bearer $token"}) if defined $token && length $token;
  return ($base, {}) unless $app->hub_config->mode eq 'clients';
  my $admin = _admin_token($app, $client) // die "no admin client to authenticate with\n";
  return ($base, {Authorization => "Bearer $admin"});
}

sub _admin_token ($app, $client) {
  my $clients = $app->hub_config->clients;
  if (defined $client) { return ($clients->{$client} // {})->{token} }
  for my $name (sort keys %$clients) {
    my $c = $clients->{$name};
    my $profile = $app->hub_config->profiles->{$c->{profile}};
    return $c->{token} if $profile && $profile->{admin};
  }
  return undef;
}

sub _print_table ($report) {
  printf "mode: %s\n\n", $report->{mode} // 'open';
  printf "%-16s %-6s %-9s %-8s %-10s %-6s %-6s %s\n", qw(NAME TYPE STATE PID RSS_KB CALLS ERRORS MESSAGE);
  for my $row (@{$report->{upstreams} // []}) {
    printf "%-16s %-6s %-9s %-8s %-10s %-6s %-6s %s\n",
      $row->{name}, $row->{type}, $row->{state},
      $row->{pid} // '-', $row->{rss_kb} // '-', $row->{calls} // 0, $row->{errors} // 0,
      $row->{error} // '';
  }
  if (my @clients = @{$report->{clients} // []}) {
    print "\nclients:\n";
    printf "  %-16s %-12s %s\n", $_->{name}, $_->{profile}, _ago($_->{last_seen}) for @clients;
  }
  return;
}

sub _ago ($epoch) {
  return 'never' unless $epoch;
  my $seconds = time - $epoch;
  return 'just now'                     if $seconds < 5;
  return $seconds . 's ago'             if $seconds < 90;
  return int($seconds / 60) . 'm ago'   if $seconds < 5400;
  return int($seconds / 3600) . 'h ago' if $seconds < 172800;
  return int($seconds / 86400) . 'd ago';
}

1;

=encoding utf8

=head1 SYNOPSIS

  mcp-hub status
  mcp-hub status --client main
  mcp-hub status --url http://hub.local:3080
  mcp-hub status --url http://hub.local:3080 --token s3cret

=head1 DESCRIPTION

L<MCP::Hub::Command::status> calls C<GET /_hub/status> on the running daemon and
prints a table of every upstream's state, pid, memory, call counts and, for a
failed one, why it failed -- plus the known clients and when each was last seen.
It reports "not running" on a refused connection. In clients mode it uses the
token of the first admin client, or the one named with C<--client>.

The daemon is looked for at the configured C<listen> address, with a wildcard
(C<*>, C<0.0.0.0> or C<[::]>) rewritten to loopback. C<--url> points the command
at another base URL, for a hub in a container or on another host.

C<--token> (or C<$MCP_HUB_TOKEN>) authenticates with a token given on the spot
rather than one from the configuration. Given together with C<--url> it means
the command never reads the configuration file at all, so a broken configuration
does not stop C<status>, C<refresh> or C<reload> from reaching a daemon whose
address and token it was handed.

=head1 SEE ALSO

L<mcp-hub>, L<MCP::Hub>.

=cut
