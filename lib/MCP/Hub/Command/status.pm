package MCP::Hub::Command::status;
our $VERSION = '0.001';
use Mojo::Base 'Mojolicious::Command', -signatures;

use Getopt::Long   qw(GetOptionsFromArray :config no_auto_abbrev no_ignore_case);
use Mojo::UserAgent;

# ABSTRACT: Show the running hub's status as a table

has description => 'Show the running hub status as a table';
has usage       => <<'USAGE';
Usage: mcp-hub status [--client NAME]

Options:
  --client NAME   Client whose token to authenticate with (default: first admin client)
USAGE

sub run ($self, @args) {
  GetOptionsFromArray(\@args, 'client=s' => \my $client) or die $self->usage;

  my $app  = $self->app;
  my $base = MCP::Hub::_base_url($app->hub_config->listen);
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
  printf "%-16s %-6s %-9s %-8s %-10s %-6s %-6s\n", qw(NAME TYPE STATE PID RSS_KB CALLS ERRORS);
  for my $row (@{$report->{upstreams} // []}) {
    printf "%-16s %-6s %-9s %-8s %-10s %-6s %-6s\n",
      $row->{name}, $row->{type}, $row->{state},
      $row->{pid} // '-', $row->{rss_kb} // '-', $row->{calls} // 0, $row->{errors} // 0;
  }
  if (my @clients = @{$report->{clients} // []}) {
    print "\nclients:\n";
    printf "  %-16s %-12s %s\n", $_->{name}, $_->{profile}, $_->{last_seen} // 'never' for @clients;
  }
  return;
}

1;

=encoding utf8

=head1 SYNOPSIS

  mcp-hub status

=head1 DESCRIPTION

L<MCP::Hub::Command::status> calls C<GET /_hub/status> on the running daemon and
prints a table of every upstream's state, pid, memory and call counts, plus the
known clients. It reports "not running" on a refused connection. In clients mode
it uses the token of the first admin client, or the one named with C<--client>.

=head1 SEE ALSO

L<mcp-hub>, L<MCP::Hub>.

=cut
