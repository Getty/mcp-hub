package MCP::Hub::Facade;
our $VERSION = '0.001';
use Mojo::Base -base, -signatures;

use MCP::Hub::Facade::Server;
use MCP::Hub::Facade::Tool;
use MCP::Prompt;
use MCP::Resource;

# ABSTRACT: Build an MCP::Server from a manifest that forwards to an upstream

sub build ($class, $upstream, $manifest) {
  my $server = MCP::Hub::Facade::Server->new;
  return $class->apply($server, $upstream, $manifest);
}

sub apply ($class, $server, $upstream, $manifest) {
  $server->name($manifest->{server_info}{name} // $upstream->name);
  $server->version($manifest->{server_info}{version} // '0.0.0');
  $server->instructions($manifest->{instructions});

  $server->tools([map { _tool($upstream, $_) } @{$manifest->{tools} // []}]);

  my %pextra;
  my @prompts;
  for my $p (@{$manifest->{prompts} // []}) {
    push @prompts, _prompt($upstream, $p);
    $pextra{$p->{name}} = _extra($p);
  }
  $server->prompts(\@prompts);

  my %rextra;
  my @resources;
  for my $r (@{$manifest->{resources} // []}) {
    push @resources, _resource($upstream, $r);
    $rextra{$r->{uri}} = _extra($r);
  }
  $server->resources(\@resources);

  $server->extra({prompts => \%pextra, resources => \%rextra});
  return $server;
}

sub _tool ($upstream, $t) {
  my $name = $t->{name};
  return MCP::Hub::Facade::Tool->new(
    name         => $name,
    description  => $t->{description} // '',
    input_schema => $t->{inputSchema} // {type => 'object'},
    (defined $t->{outputSchema} ? (output_schema => $t->{outputSchema}) : ()),
    annotations  => $t->{annotations} // {},
    extra        => _extra($t),
    code         => sub ($tool, $args) { $upstream->call_tool($name, $args) },
  );
}

sub _prompt ($upstream, $p) {
  my $name = $p->{name};
  return MCP::Prompt->new(
    name        => $name,
    description => $p->{description} // '',
    arguments   => $p->{arguments} // [],
    code        => sub ($prompt, $args) { $upstream->get_prompt($name, $args) },
  );
}

sub _resource ($upstream, $r) {
  my $uri = $r->{uri};
  return MCP::Resource->new(
    uri         => $uri,
    name        => $r->{name} // '',
    description => $r->{description} // '',
    mime_type   => $r->{mimeType} // 'text/plain',
    code        => sub ($resource) { $upstream->read_resource($uri) },
  );
}

sub _extra ($entry) {
  return {map { defined $entry->{$_} ? ($_ => $entry->{$_}) : () } qw(title icons _meta)};
}

1;

=encoding utf8

=head1 SYNOPSIS

  use MCP::Hub::Facade;

  my $server = MCP::Hub::Facade->build($upstream, $manifest);

  # rebuild in place after a refresh, keeping the mounted instance
  MCP::Hub::Facade->apply($server, $upstream, $new_manifest);

=head1 DESCRIPTION

L<MCP::Hub::Facade> turns a cached manifest into an L<MCP::Hub::Facade::Server>
whose tools, prompts and resources forward to an upstream. Each tool's C<code>
calls C<< $upstream->call_tool >>, each prompt C<< $upstream->get_prompt >>, each
resource C<< $upstream->read_resource >> -- all of which return promises
resolving to the upstream's result unchanged, or, on error, to an error result.

The tools are L<MCP::Hub::Facade::Tool> objects, so their argument validation is
disabled and their C<title>/C<icons>/C<_meta> fields are preserved. Prompt and
resource extras are stored on the server.

=head1 METHODS

=method build

  my $server = MCP::Hub::Facade->build($upstream, $manifest);

Return a fresh L<MCP::Hub::Facade::Server> built from the manifest.

=method apply

  MCP::Hub::Facade->apply($server, $upstream, $manifest);

Replace the primitive lists of an existing server in place, so a mounted route
keeps its instance (and its notification subscribers) across a manifest refresh.
Returns the server.

=head1 SEE ALSO

L<MCP::Hub::Facade::Server>, L<MCP::Hub::Facade::Tool>, L<MCP::Hub::Upstream::Stdio>.

=cut
