package MCP::Hub::Command::reload;
our $VERSION = '0.001';
use Mojo::Base 'Mojolicious::Command', -signatures;

use Getopt::Long   qw(GetOptionsFromArray :config no_auto_abbrev no_ignore_case);
use MCP::Hub::Command::status;    # _base and _admin_token are shared with it
use Mojo::UserAgent;

# ABSTRACT: Ask the running hub to re-read its configuration file

has description => 'Re-read the configuration on the running hub';
has usage       => <<'USAGE';
Usage: mcp-hub reload [--client NAME] [--url BASE]

  mcp-hub reload               # re-read the configuration, apply what changed

Options:
  --client NAME   Client whose token to authenticate with (default: first admin client)
  --url BASE      Base URL of the running hub (default derived from the listen address)
USAGE

sub run ($self, @args) {
  GetOptionsFromArray(\@args, 'client=s' => \my $client, 'url=s' => \my $url) or die $self->usage;

  my $app  = $self->app;
  my $base = MCP::Hub::Command::status::_base($app, $url);
  my %headers = ('Content-Type' => 'application/json');
  if ($app->hub_config->mode eq 'clients') {
    my $token = MCP::Hub::Command::status::_admin_token($app, $client)
      // die "no admin client to authenticate with\n";
    $headers{Authorization} = "Bearer $token";
  }

  my $tx = Mojo::UserAgent->new->post("$base/_hub/reload" => \%headers => '{}');
  my $summary = $tx->res->json;
  if (my $err = $tx->error) {
    return print "hub is not running at $base ($err->{message})\n" unless $err->{code};

    # The hub refused the new configuration and said why. That is the message
    # worth printing -- and worth exiting non-zero on, so a script that reloads
    # after writing the file notices.
    die $summary->{error} . "\n" if ref $summary eq 'HASH' && $summary->{error};
    die "reload request failed: $err->{code} $err->{message}\n";
  }

  _print_summary($summary // {});
  return;
}

sub _print_summary ($summary) {
  for my $key (qw(added removed changed)) {
    printf "%-10s %s\n", $key, join(', ', @{$summary->{$key}}) if @{$summary->{$key} // []};
  }
  printf "%-10s %s\n", 'unchanged', scalar @{$summary->{unchanged} // []};
  print "access rules updated\n" if $summary->{auth};
  print "warning: $_\n" for @{$summary->{warnings} // []};
  return;
}

1;

=encoding utf8

=head1 SYNOPSIS

  mcp-hub reload
  mcp-hub reload --url http://hub.local:3080

=head1 DESCRIPTION

L<MCP::Hub::Command::reload> calls C<POST /_hub/reload> on the running daemon,
which re-reads its configuration file and applies only what changed in it (see
L<MCP::Hub/reload>), and prints what happened:

  added      serper
  removed    playwright
  unchanged  3
  warning: hub.listen changed from http://127.0.0.1:3080 to http://0.0.0.0:3080, restart the daemon to apply

C<SIGHUP> does the same thing but tells the sender nothing; this command exists
for the feedback. If the new configuration does not validate, the running one
stays fully in effect, the hub answers with the error and its JSON path, and
this command prints that and exits non-zero:

  Invalid configuration at mcpServers.serper.hub.idle_timeout: must be an integer

In clients mode it authenticates as the first admin client (or C<--client>).
C<--url> points it at another base URL, as for C<mcp-hub status>.

=head1 SEE ALSO

L<mcp-hub>, L<MCP::Hub>, L<MCP::Hub::Command::daemon>.

=cut
