package MCP::Hub::Command::config;
our $VERSION = '0.001';
use Mojo::Base 'Mojolicious::Command', -signatures;

use Getopt::Long qw(GetOptionsFromArray :config no_auto_abbrev no_ignore_case);
use JSON::PP     ();

# ABSTRACT: Print the mcpServers client configuration for the hub

has description => 'Print ready-to-paste mcpServers client configuration';
has usage       => <<'USAGE';
Usage: mcp-hub config [OPTIONS]

  mcp-hub config
  mcp-hub config --client main
  mcp-hub config --all --url http://127.0.0.1:3080

Options:
  --client NAME   Client whose token and profile to use (required in clients mode)
  --all           Emit a single "hub" entry pointing at /all
  --url BASE      Override the base URL (default derived from the listen address)
USAGE

sub run ($self, @args) {
  GetOptionsFromArray(\@args,
    'client=s' => \my $client,
    'all'      => \my $all,
    'url=s'    => \my $url,
  ) or die $self->usage;

  my $data = $self->app->export_config(client => $client, all => $all, url => $url);
  print JSON::PP->new->pretty->canonical->encode($data);
  return;
}

1;

=encoding utf8

=head1 SYNOPSIS

  mcp-hub config --client main

=head1 DESCRIPTION

L<MCP::Hub::Command::config> prints the C<< {"mcpServers": {...}} >> JSON an
agent needs, one HTTP entry per server the profile allows. In clients mode
C<--client> is required and adds the C<Authorization: Bearer> header; in open
mode it is ignored with a warning. C<--all> emits a single C<hub> entry pointing
at C</all>.

=head1 SEE ALSO

L<mcp-hub>, L<MCP::Hub>.

=cut
