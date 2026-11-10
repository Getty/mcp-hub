package MCP::Hub::Command::refresh;
our $VERSION = '0.001';
use Mojo::Base 'Mojolicious::Command', -signatures;

use Getopt::Long   qw(GetOptionsFromArray :config no_auto_abbrev no_ignore_case);
use MCP::Hub::Command::status;    # _endpoint (base URL + auth) is shared with it
use Mojo::JSON     qw(encode_json);
use Mojo::UserAgent;

# ABSTRACT: Ask the running hub to re-fetch upstream manifests

has description => 'Re-fetch upstream manifests on the running hub';
has usage       => <<'USAGE';
Usage: mcp-hub refresh [NAME] [--client NAME] [--url BASE] [--token TOKEN]

  mcp-hub refresh              # refresh every upstream
  mcp-hub refresh context7     # refresh just one

Options:
  --client NAME   Client whose token to authenticate with (default: first admin client)
  --url BASE      Base URL of the running hub (default derived from the listen address)
  --token TOKEN   Bearer token to authenticate with, instead of a configured client
                  (or $MCP_HUB_TOKEN); with --url the config file is never read

Exits 1, saying so, when no hub answers at the base URL.
USAGE

sub run ($self, @args) {
  GetOptionsFromArray(\@args,
    'client=s' => \my $client, 'url=s' => \my $url, 'token=s' => \my $token) or die $self->usage;
  my $name = shift @args;

  my ($base, $headers) = MCP::Hub::Command::status::_endpoint($self->app, $url, $client, $token);
  $headers->{'Content-Type'} = 'application/json';

  my $body = encode_json(defined $name ? {name => $name} : {});
  my $tx   = Mojo::UserAgent->new->post("$base/_hub/refresh" => $headers => $body);
  if (my $err = $tx->error) {
    # No hub answers: a failure, exit 1 with the reason on stderr, as for
    # status -- an uncaught die exits with $!.
    unless ($err->{code}) {
      local $! = 1;
      die "hub is not running at $base ($err->{message})\n";
    }
    die "refresh request failed: $err->{code} $err->{message}\n";
  }

  _print_counts($tx->res->json // {});
  return;
}

sub _print_counts ($counts) {
  for my $name (sort keys %$counts) {
    my $r = $counts->{$name};

    # A failed upstream (an unbuildable placeholder, or a child a refresh could
    # not revive) reports its failure and reason, not "0 tools" -- which would
    # read as success. A bare count from an older daemon is still tolerated.
    my $status = !ref $r                          ? "$r tools"
               : ($r->{state} // '') eq 'failed'  ? 'failed' . (defined $r->{error} ? ": $r->{error}" : '')
               :                                    ($r->{count} // 0) . ' tools';

    printf "%-16s %s\n", $name, $status;
  }
  return;
}

1;

=encoding utf8

=head1 SYNOPSIS

  mcp-hub refresh
  mcp-hub refresh context7
  mcp-hub refresh context7 --url http://hub.local:3080
  mcp-hub refresh --url http://hub.local:3080 --token s3cret

=head1 DESCRIPTION

L<MCP::Hub::Command::refresh> calls C<POST /_hub/refresh> on the running daemon,
optionally for a single named server, and prints the new tool count of each --
or, for one that is still C<failed> (an entry that could not be built, or a
child a refresh could not revive), C<failed> and the reason rather than
C<0 tools>. In clients mode it authenticates as the first admin client (or
C<--client>). C<--url> points it at another base URL, and C<--token> (or
C<$MCP_HUB_TOKEN>) authenticates without reading the configuration, both as for
C<mcp-hub status>.

A refresh is also the way back from a C<failed> upstream: it clears the failure
and tries to start the server once more (see L<MCP::Hub::Upstream/refresh_p>).

When no hub answers -- the connection is refused, or no HTTP response comes
back -- it says "hub is not running at" that base URL on standard error and
exits 1, as C<mcp-hub status> does.

=head1 SEE ALSO

L<mcp-hub>, L<MCP::Hub>.

=cut
