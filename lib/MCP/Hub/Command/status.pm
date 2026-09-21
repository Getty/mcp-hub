package MCP::Hub::Command::status;
our $VERSION = '0.001';
use Mojo::Base 'Mojolicious::Command', -signatures;

use Getopt::Long   qw(GetOptionsFromArray :config no_auto_abbrev no_ignore_case);
use Mojo::UserAgent;

# ABSTRACT: Show the running hub's status as a table

has description => 'Show the running hub status as a table';
has usage       => <<'USAGE';
Usage: mcp-hub status [--client NAME] [--url BASE]

Options:
  --client NAME   Client whose token to authenticate with (default: first admin client)
  --url BASE      Base URL of the running hub (default derived from the listen address)
USAGE

sub run ($self, @args) {
  GetOptionsFromArray(\@args, 'client=s' => \my $client, 'url=s' => \my $url) or die $self->usage;

  my $app  = $self->app;
  my $base = _base($app, $url);
  my %headers;
  if ($app->hub_config->mode eq 'clients') {
    my $token = _admin_token($app, $client) // die "no admin client to authenticate with\n";
    $headers{Authorization} = "Bearer $token";
  }

  my $tx = Mojo::UserAgent->new->get("$base/_hub/status" => \%headers);
  if (my $err = $tx->error) {
    return print "hub is not running at $base ($err->{message})\n" unless $err->{code};
    die "status request failed: $err->{code} $err->{message}\n";
  }

  _print_table($tx->res->json);
  return;
}

sub _base ($app, $url) {
  return MCP::Hub::_base_url($url // $app->hub_config->listen);
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

=head1 DESCRIPTION

L<MCP::Hub::Command::status> calls C<GET /_hub/status> on the running daemon and
prints a table of every upstream's state, pid, memory, call counts and, for a
failed one, why it failed -- plus the known clients and when each was last seen.
It reports "not running" on a refused connection. In clients mode it uses the
token of the first admin client, or the one named with C<--client>.

The daemon is looked for at the configured C<listen> address, with a wildcard
(C<*>, C<0.0.0.0> or C<[::]>) rewritten to loopback. C<--url> points the command
at another base URL, for a hub in a container or on another host.

=head1 SEE ALSO

L<mcp-hub>, L<MCP::Hub>.

=cut
