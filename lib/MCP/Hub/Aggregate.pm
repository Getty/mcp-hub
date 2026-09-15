package MCP::Hub::Aggregate;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Server', -signatures;

use MCP::Hub::Facade::Tool;
use MCP::Prompt;

# ABSTRACT: The /all endpoint -- every upstream's tools and prompts, prefixed

sub new ($class, %args) {
  return $class->SUPER::new(name => 'all', version => $VERSION, %args);
}

sub rebuild ($self, $upstreams) {
  my (@tools, @prompts, @instructions);

  for my $upstream (@$upstreams) {
    my $server = $upstream->server or next;
    my $prefix = $upstream->name . '__';

    push @tools,   map { _wrap_tool($prefix, $_) } @{$server->tools};
    push @prompts, map { _wrap_prompt($prefix, $_) } @{$server->prompts};

    if (defined(my $instructions = $server->instructions)) {
      push @instructions, "## @{[$upstream->name]}\n$instructions";
    }
  }

  $self->tools(\@tools);
  $self->prompts(\@prompts);
  $self->instructions(@instructions ? join("\n\n", @instructions) : undef);
  return $self;
}

sub _wrap_tool ($prefix, $tool) {
  return MCP::Hub::Facade::Tool->new(
    name         => $prefix . $tool->name,
    description  => $tool->description,
    input_schema => $tool->input_schema,
    ($tool->output_schema ? (output_schema => $tool->output_schema) : ()),
    annotations  => $tool->annotations,
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

L<MCP::Hub::Aggregate> is the L<MCP::Server> mounted at C</all>. It presents the
tools and prompts of every upstream the client may see under a
C<< <server>__<tool> >> name, so one endpoint reaches everything. Each wrapped
tool calls the original tool object directly, so facade error handling and
in-process servers behave exactly as they do on their own endpoint.

Resources are not aggregated -- their URIs are opaque and would collide -- so use
the per-server endpoint for those. The C<instructions> are the concatenation of
each upstream's, headed by C<< ## <name> >>.

The per-request tool filter (L<MCP::Hub::Auth/filter_aggregate>) uses the prefix
to apply the profile's C<servers> and C<tools> rules.

=head1 METHODS

L<MCP::Hub::Aggregate> inherits all methods from L<MCP::Server> and adds:

=head2 rebuild

  $all->rebuild(\@upstreams);

Replace the aggregate's tools, prompts and instructions in place from the
current upstreams. Called at start and after any manifest refresh, since a
refresh replaces an upstream's tool objects.

=head1 SEE ALSO

L<MCP::Hub>, L<MCP::Hub::Facade::Tool>.

=cut
