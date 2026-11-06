package MCP::Hub::Aggregate;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Hub::Facade::Server', -signatures;

use MCP::Hub::Facade;
use MCP::Hub::Facade::Tool;
use MCP::Prompt;
use MCP::Server::Context;

# ABSTRACT: The /all endpoint -- every upstream's tools and prompts, prefixed

sub new ($class, %args) {
  return $class->SUPER::new(name => 'all', version => $VERSION, %args);
}

sub rebuild ($self, $upstreams) {
  my (@tools, @prompts, %pextra, @instructions);

  for my $upstream (@$upstreams) {
    my $server = $upstream->server or next;
    my $prefix = $upstream->name . '__';

    my $textra = _listed_extra($server, 'tools');
    push @tools, map { _wrap_tool($prefix, $_, $textra->{$_->name} // {}) } @{$server->tools};

    my $listed = _listed_extra($server, 'prompts');
    for my $prompt (@{$server->prompts}) {
      push @prompts, _wrap_prompt($prefix, $prompt);
      $pextra{$prefix . $prompt->name} = $listed->{$prompt->name};
    }

    if (defined(my $instructions = $server->instructions)) {
      push @instructions, "## @{[$upstream->name]}\n$instructions";
    }
  }

  $self->tools(\@tools);
  $self->prompts(\@prompts);
  $self->extra({prompts => \%pextra, resources => {}});
  $self->instructions(@instructions ? join("\n\n", @instructions) : undef);
  return $self;
}

# The title, icons and _meta of each entry the server itself lists, by name.
# They are taken from its own rendering, not from the objects: a facade merges
# them in from its manifest, an in-process class renders them however it does,
# and a plain MCP::Tool has nowhere to keep them. The empty context has no
# controller, so no profile filter runs here -- it runs on the aggregate's own list.
sub _listed_extra ($server, $kind) {
  my $render = "_handle_${kind}_list";
  my ($result) = $server->$render(MCP::Server::Context->new);
  return {map { $_->{name} => MCP::Hub::Facade::_extra($_) } @{$result->{$kind} // []}};
}

sub _wrap_tool ($prefix, $tool, $extra) {
  return MCP::Hub::Facade::Tool->new(
    name         => $prefix . $tool->name,
    description  => $tool->description,
    input_schema => $tool->input_schema,
    ($tool->output_schema ? (output_schema => $tool->output_schema) : ()),
    annotations  => $tool->annotations,
    extra        => $extra,
    code         => sub ($wrapper, $args) { $tool->call($args, $wrapper->context) },
  );
}

sub _wrap_prompt ($prefix, $prompt) {
  return MCP::Prompt->new(
    name        => $prefix . $prompt->name,
    description  => $prompt->description,
    arguments   => $prompt->arguments,
    code        => sub ($wrapper, $args) { $prompt->call($args, $wrapper->context) },
  );
}

1;

=encoding utf8

=head1 SYNOPSIS

  use MCP::Hub::Aggregate;

  my $all = MCP::Hub::Aggregate->new;
  $all->rebuild(\@upstreams);

=head1 DESCRIPTION

L<MCP::Hub::Aggregate> is the L<MCP::Hub::Facade::Server> mounted at C</all>. It
presents the tools and prompts of every upstream the client may see under a
C<< <server>__<tool> >> name, so one endpoint reaches everything. Each wrapped
tool calls the original tool object directly, so facade error handling and
in-process servers behave exactly as they do on their own endpoint.

Each tool and prompt keeps the C<title>, C<icons> and C<_meta> its upstream
lists for it on its own endpoint. They are read from that server's own
C<tools/list> and C<prompts/list> rendering when the aggregate is rebuilt -- a
facade merges them in from its manifest, an in-process class renders them
itself -- and merged back in by L<MCP::Hub::Facade::Server>, after the profile
filter.

Resources are not aggregated -- their URIs are opaque and would collide -- so use
the per-server endpoint for those. The C<instructions> are the concatenation of
each upstream's, headed by C<< ## <name> >>.

The per-request tool filter (L<MCP::Hub::Auth/filter_aggregate>) uses the prefix
to apply the profile's C<servers> and C<tools> rules.

=head1 METHODS

L<MCP::Hub::Aggregate> inherits all methods from L<MCP::Hub::Facade::Server> and adds:

=method rebuild

  $all->rebuild(\@upstreams);

Replace the aggregate's tools, prompts, their extras and instructions in place
from the current upstreams. Called at start and after any manifest refresh,
since a refresh replaces an upstream's tool objects.

=head1 SEE ALSO

L<MCP::Hub>, L<MCP::Hub::Facade::Server>, L<MCP::Hub::Facade::Tool>.

=cut
