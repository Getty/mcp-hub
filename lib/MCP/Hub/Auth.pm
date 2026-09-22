package MCP::Hub::Auth;
our $VERSION = '0.001';
use Mojo::Base -base, -signatures;

use Crypt::Misc qw(slow_eq);

# ABSTRACT: Resolve a request to a profile and filter what it may see

has 'config';
# Client name -> epoch of the last request that authenticated as it. Kept here,
# not on the config's client hash, so it survives a configuration swap.
has last_seen => sub { {} };

my $OPEN_PROFILE = {name => 'open', servers => ['*'], tools => {}, admin => 1};

sub open_profile ($self) { return $OPEN_PROFILE }

sub authenticate ($self, $c) {
  my $config = $self->config;

  if ($config->mode eq 'open') {
    $c->stash('mcp.profile' => $self->open_profile, 'mcp.client' => undef);
    return 1;
  }

  my $token = _bearer($c);
  if (defined $token and my $client = $self->resolve_client($token)) {
    $self->last_seen->{$client->{name}} = time;
    $c->stash('mcp.profile' => $config->profiles->{$client->{profile}}, 'mcp.client' => $client->{name});
    return 1;
  }

  if (defined(my $public = $config->public_profile)) {
    $c->stash('mcp.profile' => $config->profiles->{$public}, 'mcp.client' => undef);
    return 1;
  }

  return $self->_unauthorized($c);
}

sub resolve_client ($self, $token) {
  return undef unless defined $token && length $token;
  # Constant-time: compare against every client, never short-circuit.
  my $match;
  for my $client (values %{$self->config->clients}) {
    $match = $client if slow_eq($token, $client->{token});
  }
  return $match;
}

sub allows_server ($self, $profile, $name) {
  my $servers = $profile->{servers} // [];
  return 1 if grep { $_ eq '*' } @$servers;
  return (grep { $_ eq $name } @$servers) ? 1 : 0;
}

sub filter_tools ($self, $profile, $server_name, $tools) {
  return unless ($profile->{tools} // {})->{$server_name};
  @$tools = grep { $self->tool_visible($profile, $server_name, $_->name) } @$tools;
  return;
}

sub filter_aggregate ($self, $profile, $tools) {
  @$tools = grep {
    my ($srv, $tool) = split /__/, $_->name, 2;
    $self->allows_server($profile, $srv) && $self->tool_visible($profile, $srv, $tool // '');
  } @$tools;
  return;
}

sub tool_visible ($self, $profile, $server_name, $tool_name) {
  my $rule = ($profile->{tools} // {})->{$server_name};
  return 1 unless $rule;
  return 0 if grep { $_ eq $tool_name } @{$rule->{deny} // []};
  return 1 unless exists $rule->{allow};
  return (grep { $_ eq $tool_name } @{$rule->{allow}}) ? 1 : 0;
}

sub _bearer ($c) {
  my $header = $c->req->headers->authorization // return undef;
  return $header =~ /^Bearer\s+(\S+)/i ? $1 : undef;
}

sub _unauthorized ($self, $c) {
  $c->res->headers->header('WWW-Authenticate' => 'Bearer');
  $c->render(json => {error => 'Unauthorized'}, status => 401);
  return 0;
}

1;

=encoding utf8

=head1 SYNOPSIS

  use MCP::Hub::Auth;

  my $auth = MCP::Hub::Auth->new(config => $config);

  # in the routing bridge
  return unless $auth->authenticate($c);
  my $profile = $c->stash('mcp.profile');

  # deciding what a request may see
  $auth->allows_server($profile, 'context7') or $c->render(status => 404, ...);
  $auth->filter_tools($profile, 'serper', $tools);

=head1 DESCRIPTION

L<MCP::Hub::Auth> maps a request to a profile and enforces that profile.

In B<open> mode -- an empty C<clients> block -- every request gets a wildcard
profile that sees every server and has admin rights, and no token is checked.

In B<clients> mode a request must carry a bearer token matching a client, whose
profile then applies; a request without a valid token gets the C<public_profile>
if one is configured, or a C<401> otherwise. Tokens are compared in constant
time.

A profile lists the C<servers> it may see (or C<["*"]>) and optional per-server
C<tools> rules: an C<allow> list restricts the visible tools, a C<deny> list
subtracts from what is left. Prompts and resources follow C<servers> alone. A
server a profile does not include is answered with C<404> at the route, so a
client cannot even tell it exists.

=head1 ATTRIBUTES

=attr config

  my $config = $auth->config;

The L<MCP::Hub::Config> the decisions are made against.

=attr last_seen

  my $epoch = $auth->last_seen->{worker};

Hash reference of client name to the epoch seconds of the last request that
authenticated as that client, stamped by L</authenticate>. It lives here rather
than on the configuration's client hash, so that replacing the configuration
does not lose it; C<GET /_hub/status> and C<mcp-hub status> report it.

=head1 METHODS

=method allows_server

  my $bool = $auth->allows_server($profile, $name);

True if the profile's C<servers> list includes the server (or C<"*">).

=method authenticate

  my $ok = $auth->authenticate($c);

Resolve the request to a profile and store it in the stash as C<mcp.profile>
(and the client name as C<mcp.client>). Returns true on success. A token that
resolves to a client also stamps L</last_seen>. In clients mode with no valid
token and no public profile it renders a C<401> and returns false.

=method filter_aggregate

  $auth->filter_aggregate($profile, $tools);

Filter the C<< <server>__<tool> >>-prefixed tools of the C</all> endpoint in
place, dropping any whose server the profile may not see or whose tool it denies.

=method filter_tools

  $auth->filter_tools($profile, $server_name, $tools);

Filter a server's tools in place according to the profile's C<allow>/C<deny>
rules for that server. A no-op when the profile has no rule for the server.

=method open_profile

  my $profile = $auth->open_profile;

The implicit wildcard-and-admin profile used in open mode.

=method resolve_client

  my $client = $auth->resolve_client($token);

The client hash reference whose token matches, or C<undef>.

=method tool_visible

  my $bool = $auth->tool_visible($profile, $server_name, $tool_name);

Whether a single tool is visible under the profile's rules.

=head1 SEE ALSO

L<MCP::Hub>, L<MCP::Hub::Config>.

=cut
