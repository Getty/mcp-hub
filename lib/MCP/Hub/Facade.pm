package MCP::Hub::Facade;
our $VERSION = '0.001';
use Mojo::Base -base, -signatures;

use MCP::Hub::Facade::Server;
use MCP::Hub::Facade::Tool;
use MCP::Prompt;
use MCP::Resource;
use Mojo::Promise;
use Scalar::Util qw(weaken);

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

# Each primitive holds its upstream weakly: the upstream holds this server, the
# server its primitives, so a strong reference back is a cycle, and an upstream
# a reload replaces or removes would never be freed. The hub's list keeps every
# configured upstream alive, and a call under way its own -- call_tool and its
# kin hold it until they settle. A primitive that outlived its upstream answers
# with an error result, as a call that failed upstream would.
sub _tool ($upstream, $t) {
  my $name = $t->{name};
  my $gone = _gone($upstream);
  weaken $upstream;
  return MCP::Hub::Facade::Tool->new(
    name         => $name,
    description  => $t->{description} // '',
    input_schema => $t->{inputSchema} // {type => 'object'},
    (defined $t->{outputSchema} ? (output_schema => $t->{outputSchema}) : ()),
    annotations  => $t->{annotations} // {},
    extra        => _extra($t),
    code         => sub ($tool, $args) {
      return $upstream->call_tool($name, $args) if $upstream;
      return Mojo::Promise->resolve({content => [{type => 'text', text => $gone}], isError => \1});
    },
  );
}

sub _prompt ($upstream, $p) {
  my $name = $p->{name};
  my $gone = _gone($upstream);
  weaken $upstream;
  return MCP::Prompt->new(
    name        => $name,
    description => $p->{description} // '',
    arguments   => $p->{arguments} // [],
    code        => sub ($prompt, $args) {
      return $upstream->get_prompt($name, $args) if $upstream;
      return Mojo::Promise->resolve(
        {description => $gone, messages => [{role => 'user', content => {type => 'text', text => $gone}}]});
    },
  );
}

sub _resource ($upstream, $r) {
  my $uri  = $r->{uri};
  my $gone = _gone($upstream);
  weaken $upstream;
  return MCP::Resource->new(
    uri         => $uri,
    name        => $r->{name} // '',
    description => $r->{description} // '',
    mime_type   => $r->{mimeType} // 'text/plain',
    code        => sub ($resource) {
      return $upstream->read_resource($uri) if $upstream;
      return Mojo::Promise->resolve({contents => [{uri => $uri, mimeType => 'text/plain', text => $gone}]});
    },
  );
}

# What a primitive answers once its upstream is gone, worded like the reasons
# an upstream's own failed calls give.
sub _gone ($upstream) {
  return 'upstream ' . $upstream->name . ': gone, a configuration reload removed or replaced it';
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

They hold the upstream B<weakly>. The upstream holds the facade, so a strong
reference back would be a cycle, and an upstream a configuration reload
replaces or removes would never be freed. The caller keeps the upstream alive
-- in L<MCP::Hub>, its list of the configured upstreams -- and a call under way
keeps it until that call settles. A primitive whose upstream is gone resolves
to an error result that says so: an C<isError> tool result, a prompt whose
message is the reason, a resource whose text is.

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
