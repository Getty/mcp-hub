package MCP::Hub::Aggregate;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Hub::Facade::Server', -signatures;

use MCP::Hub::Facade;
use MCP::Hub::Facade::Tool;
use MCP::Prompt;
use MCP::Server::Context;
use Scalar::Util qw(refaddr);

# ABSTRACT: The /all endpoint -- every upstream's tools and prompts, prefixed

# Where each wrapped tool and prompt came from -- [server, its own name there] --
# keyed by the wrapper itself. The profile filters decide by this, never by the
# "<server>__<name>": a server name may contain "__" too, so splitting it can
# name the wrong server, and two entries can even share one /all name.
has _origins => sub { {} };

# The title, icons and _meta of each wrapped prompt, keyed by the wrapper as
# well: by name, two prompts of one name would show the same. A wrapped tool
# carries its own (Facade::Tool->extra).
has _prompt_extras => sub { {} };

# Each upstream's instructions as [server, text], in upstream order. What
# server/discover shows of them is narrowed per request (the instructions event).
has _sections => sub { [] };

sub new ($class, %args) {
  return $class->SUPER::new(name => 'all', version => $VERSION, %args);
}

sub origin ($self, $entry) {
  my $origin = $self->_origins->{refaddr $entry} or return;
  return @$origin;
}

sub _prompt_extra ($self, $prompt) { return $self->_prompt_extras->{refaddr $prompt} }

sub rebuild ($self, $upstreams) {
  my (@tools, @prompts, %pextra, %origins, @instructions);

  for my $upstream (@$upstreams) {
    my $server = $upstream->server or next;
    my $name   = $upstream->name;
    my $prefix = $name . '__';

    my $textra = _listed_extra($server, 'tools');
    for my $tool (@{$server->tools}) {
      push @tools, _wrap_tool($prefix, $tool, $textra->{$tool->name} // {});
      $origins{refaddr $tools[-1]} = [$name, $tool->name];
    }

    my $listed = _listed_extra($server, 'prompts');
    for my $prompt (@{$server->prompts}) {
      push @prompts, _wrap_prompt($prefix, $prompt);
      $origins{refaddr $prompts[-1]} = [$name, $prompt->name];
      $pextra{refaddr $prompts[-1]}  = $listed->{$prompt->name};
    }

    if (defined(my $instructions = $server->instructions)) {
      push @instructions, [$name, $instructions];
    }
  }

  $self->tools(\@tools);
  $self->prompts(\@prompts);
  $self->_origins(\%origins);
  $self->_prompt_extras(\%pextra);
  $self->_sections(\@instructions);
  $self->instructions(_join_sections(\@instructions));
  return $self;
}

# server/discover and the legacy initialize describe the whole server, and
# MCP::Server answers them from its unfiltered lists. Here what a caller may see
# is filtered per request, so the answer is narrowed to that: a tools or prompts
# capability only when the filter leaves any, the instructions only of the
# servers it may see -- and, depending on the caller, the answer is not public.
sub _dispatch ($self, $request, $id, $context) {
  my $response = $self->SUPER::_dispatch($request, $id, $context);
  my $method   = $request->{method} // '';
  return $response unless $method eq 'server/discover' || $method eq 'initialize';
  my $result = ref $response eq 'HASH' && $response->{result} or return $response;

  my $capabilities = $result->{capabilities} // {};
  delete $capabilities->{tools}   unless @{$self->_tools($context)};
  delete $capabilities->{prompts} unless @{$self->_prompts($context)};
  return $response unless $method eq 'server/discover';

  my $instructions = $self->_instructions($context);
  if (defined $instructions) { $result->{instructions} = $instructions }
  else                       { delete $result->{instructions} }
  $result->{cacheScope} = 'private' if grep { $self->has_subscribers($_) } qw(instructions prompts tools);
  return $response;
}

# The instructions this request may see: the instructions event narrows the
# server names, as the tools and prompts events narrow those lists.
sub _instructions ($self, $context) {
  my $servers = [map { $_->[0] } @{$self->_sections}];
  $self->emit(instructions => $servers, $context);
  my %shown = map { $_ => 1 } @$servers;
  return _join_sections([grep { $shown{$_->[0]} } @{$self->_sections}]);
}

# Each section headed by its server's name, or undef for none.
sub _join_sections ($sections) {
  return @$sections ? join("\n\n", map { "## $_->[0]\n$_->[1]" } @$sections) : undef;
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

# The MCP::Primitive fields MCP::Server acts on rather than renders: the scopes
# a listing or call needs -- checked here, since a wrapped call goes straight to
# the original object, past its own server's check -- and the cache hints.
sub _primitive_fields ($primitive) {
  return map { $_ => $primitive->$_ } qw(scopes cache_ttl cache_scope);
}

sub _wrap_tool ($prefix, $tool, $extra) {
  return MCP::Hub::Facade::Tool->new(
    name         => $prefix . $tool->name,
    description  => $tool->description,
    input_schema => $tool->input_schema,
    ($tool->output_schema ? (output_schema => $tool->output_schema) : ()),
    annotations  => $tool->annotations,
    _primitive_fields($tool),
    extra        => $extra,
    code         => sub ($wrapper, $args) { $tool->call($args, $wrapper->context) },
  );
}

sub _wrap_prompt ($prefix, $prompt) {
  return MCP::Prompt->new(
    name        => $prefix . $prompt->name,
    description  => $prompt->description,
    arguments   => $prompt->arguments,
    _primitive_fields($prompt),
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

Each also keeps the C<scopes>, C<cache_ttl> and C<cache_scope> of the original
object (L<MCP::Primitive>). Since a call goes straight to that object, past its
own server's scope check, C</all> runs that check itself: a primitive the
request's scopes do not cover is refused and left out of the list here, as on
its own endpoint. Only in-process classes set these fields; a facade built
from a manifest has none to keep, as C<tools/list> does not carry them.

Resources are not aggregated -- their URIs are opaque and would collide -- so use
the per-server endpoint for those. The C<instructions> are the concatenation of
each upstream's, headed by C<< ## <name> >>. Those headings name servers, so
C<server/discover> answers each request with only the sections of the servers
its profile may see (the L</instructions> event), and marks that answer
C<private>. Its C<tools> and C<prompts> capabilities -- and those of the legacy
C<initialize> -- are offered only when the profile leaves any of them.

The per-request filters apply the profile by the server each entry came from,
as L</origin> records it: to tools its C<servers> and C<tools> rules
(L<MCP::Hub::Auth/filter_aggregate>), to prompts its C<servers> alone
(L<MCP::Hub::Auth/filter_aggregate_prompts>). They never read the server off the
prefixed name, since a server name may contain C<__> itself: the tools of C<p__x>
are C<p__x__...>, and a profile that allows C<p> must not reach them. C<tools/call>
and C<prompts/get> look the name up in the filtered list, so an entry the
profile hides is not found, as on its own endpoint.

=head2 Known limit: colliding names

Two servers can produce the same name here: the tool C<x__echo> of C<p> and the
tool C<echo> of C<p__x> are both C<p__x__echo>. Both are listed, and a call
reaches the first in server-name order -- here C<p>'s. Under a profile that sees
only one of them the name means that one, as each is filtered by its own origin.
Each is listed with its own C<title>, C<icons> and C<_meta>: like the origin,
they are kept by the wrapper object, never looked up by name, so a profile is
never shown the fields of an entry it does not see. Refusing C<__> in server
names would end the collision; the configuration does not, so far.

=head1 EVENTS

L<MCP::Hub::Aggregate> inherits all events from L<MCP::Hub::Facade::Server> and
emits the following new one.

=head2 instructions

  $all->on(instructions => sub ($all, $servers, $context) { ... });

Emitted on every C<server/discover> with an array reference of the names of the
upstreams that have instructions, in upstream order. A name removed from it
leaves that server's section out of the answer; L<MCP::Hub> removes those the
request's profile may not see.

=head1 METHODS

L<MCP::Hub::Aggregate> inherits all methods from L<MCP::Hub::Facade::Server> and adds:

=method origin

  my ($server, $name) = $all->origin($entry);

The name of the upstream a tool or prompt of this aggregate came from, and the
entry's own name there -- C<('p__x', 'echo')> for the wrapper C<p__x__echo> of
C<p__x>'s C<echo>. Keyed by the wrapper object, not its name, so colliding names
keep apart. An empty list for anything L</rebuild> did not make.

=method rebuild

  $all->rebuild(\@upstreams);

Replace the aggregate's tools, prompts, their extras, their L</origin> and the
instructions in place from the current upstreams. Called at start and after any
manifest refresh, since a refresh replaces an upstream's tool objects.

=head1 SEE ALSO

L<MCP::Hub>, L<MCP::Hub::Facade::Server>, L<MCP::Hub::Facade::Tool>.

=cut
