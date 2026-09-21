package MCP::Hub::Command::refresh;
our $VERSION = '0.001';
use Mojo::Base 'Mojolicious::Command', -signatures;

use Getopt::Long   qw(GetOptionsFromArray :config no_auto_abbrev no_ignore_case);
use MCP::Hub::Command::status;    # _base and _admin_token are shared with it
use Mojo::JSON     qw(encode_json);
use Mojo::UserAgent;

# ABSTRACT: Ask the running hub to re-fetch upstream manifests

has description => 'Re-fetch upstream manifests on the running hub';
has usage       => <<'USAGE';
Usage: mcp-hub refresh [NAME] [--client NAME] [--url BASE]

  mcp-hub refresh              # refresh every upstream
  mcp-hub refresh context7     # refresh just one

Options:
  --client NAME   Client whose token to authenticate with (default: first admin client)
  --url BASE      Base URL of the running hub (default derived from the listen address)
USAGE

sub run ($self, @args) {
  GetOptionsFromArray(\@args, 'client=s' => \my $client, 'url=s' => \my $url) or die $self->usage;
  my $name = shift @args;

  my $app  = $self->app;
  my $base = MCP::Hub::Command::status::_base($app, $url);
  my %headers = ('Content-Type' => 'application/json');
  if ($app->hub_config->mode eq 'clients') {
    my $token = MCP::Hub::Command::status::_admin_token($app, $client)
      // die "no admin client to authenticate with\n";
    $headers{Authorization} = "Bearer $token";
  }

  my $body = encode_json(defined $name ? {name => $name} : {});
  my $tx   = Mojo::UserAgent->new->post("$base/_hub/refresh" => \%headers => $body);
  if (my $err = $tx->error) {
    return print "hub is not running at $base ($err->{message})\n" unless $err->{code};
    die "refresh request failed: $err->{code} $err->{message}\n";
  }

  my $counts = $tx->res->json // {};
  printf "%-16s %s\n", $_, $counts->{$_} . ' tools' for sort keys %$counts;
  return;
}

1;

=encoding utf8

=head1 SYNOPSIS

  mcp-hub refresh
  mcp-hub refresh context7
  mcp-hub refresh context7 --url http://hub.local:3080

=head1 DESCRIPTION

L<MCP::Hub::Command::refresh> calls C<POST /_hub/refresh> on the running daemon,
optionally for a single named server, and prints the new tool counts. In clients
mode it authenticates as the first admin client (or C<--client>). C<--url>
points it at another base URL, as for C<mcp-hub status>.

A refresh is also the way back from a C<failed> upstream: it clears the failure
and tries to start the server once more (see L<MCP::Hub::Upstream/refresh_p>).

=head1 SEE ALSO

L<mcp-hub>, L<MCP::Hub>.

=cut
