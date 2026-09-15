package MCP::Hub::Config;
our $VERSION = '0.001';
use Mojo::Base -base, -signatures;

use Carp       qw(croak);
use Mojo::File qw(path);
use Mojo::JSON qw(decode_json);

# ABSTRACT: Load, validate and normalize an MCP::Hub configuration

has cache_dir      => sub { _default_cache_dir() };
has clients        => sub { {} };
has idle_timeout   => 300;
has listen         => 'http://127.0.0.1:3080';
has mode           => 'open';
has profiles       => sub { {} };
has public_profile => undef;
has request_timeout => 60;
has servers        => sub { [] };
has source         => 'config';

my %ENTRY_KEYS      = map { $_ => 1 } qw(command args env cwd class hub);
my %ENTRY_HUB_KEYS  = map { $_ => 1 } qw(idle_timeout always_on request_timeout);
my %HUB_KEYS        = map { $_ => 1 } qw(listen cache_dir idle_timeout request_timeout profiles clients public_profile);
my %PROFILE_KEYS    = map { $_ => 1 } qw(servers tools admin);
my %TOOL_RULE_KEYS  = map { $_ => 1 } qw(allow deny);
my %CLIENT_KEYS     = map { $_ => 1 } qw(token profile);

sub from_file ($class, $file) {
  croak "config file not found: $file\n" unless -f $file;
  my $json = eval { path($file)->slurp };
  croak "cannot read config file $file: $@\n" if $@;
  my $data = eval { decode_json($json) };
  croak "invalid JSON in $file: $@\n" if $@;
  return $class->from_data($data, $file);
}

sub from_data ($class, $data, $source = 'config') {
  my $self = $class->new(source => $source);
  $self->_parse($data);
  return $self;
}

sub server_names ($self) { return [map { $_->{name} } @{$self->servers}] }

sub server ($self, $name) {
  return (grep { $_->{name} eq $name } @{$self->servers})[0];
}

sub _parse ($self, $data) {
  _err('', 'configuration must be a JSON object') unless ref $data eq 'HASH';

  my $servers = $data->{mcpServers} // {};
  _err('mcpServers', 'must be a JSON object') unless ref $servers eq 'HASH';

  my @parsed;
  for my $name (sort keys %$servers) {
    push @parsed, $self->_parse_entry($name, $servers->{$name});
  }
  $self->servers(\@parsed);

  my $hub = $data->{hub} // {};
  _err('hub', 'must be a JSON object') unless ref $hub eq 'HASH';
  $self->_parse_hub($hub);

  return $self;
}

sub _parse_entry ($self, $name, $entry) {
  my $path = "mcpServers.$name";
  _err($path, "server name '$name' is reserved") if $name eq 'all' || $name =~ /^_/;
  _err($path, "server name must match /^[A-Za-z0-9][A-Za-z0-9_-]*\$/")
    unless $name =~ /^[A-Za-z0-9][A-Za-z0-9_-]*$/;
  _err($path, 'must be a JSON object') unless ref $entry eq 'HASH';

  # HTTP/SSE upstreams are a documented non-goal for v1.
  _err($path, 'HTTP upstreams are not supported yet') if defined $entry->{url};
  _err($path, 'HTTP upstreams are not supported yet')
    if defined $entry->{type} && ($entry->{type} eq 'http' || $entry->{type} eq 'sse');

  for my $key (sort keys %$entry) {
    _err("$path.$key", "unknown key '$key'") unless $ENTRY_KEYS{$key};
  }

  my $has_command = defined $entry->{command};
  my $has_class   = defined $entry->{class};
  _err($path, "exactly one of 'command' or 'class' is required")
    if $has_command == $has_class;

  my %hub = $self->_parse_entry_hub($path, $entry->{hub});

  my %out = (name => $name, %hub);

  if ($has_command) {
    $out{type}    = 'stdio';
    $out{command} = $self->_expand($entry->{command}, "$path.command");

    my $args = $entry->{args} // [];
    _err("$path.args", 'must be a JSON array') unless ref $args eq 'ARRAY';
    $out{args} = [map { $self->_expand($args->[$_], "$path.args[$_]") } 0 .. $#$args];

    my $env = $entry->{env} // {};
    _err("$path.env", 'must be a JSON object') unless ref $env eq 'HASH';
    $out{env} = {map { $_ => $self->_expand($env->{$_}, "$path.env.$_") } keys %$env};

    if (defined $entry->{cwd}) {
      $out{cwd} = _tilde($self->_expand($entry->{cwd}, "$path.cwd"));
    }
  }
  else {
    $out{type}  = 'perl';
    $out{class} = $entry->{class};
    my $args = $entry->{args} // {};
    _err("$path.args", "must be a JSON object for a 'class' upstream") unless ref $args eq 'HASH';
    $out{class_args} = $args;
  }

  return \%out;
}

sub _parse_entry_hub ($self, $path, $hub) {
  return () unless defined $hub;
  _err("$path.hub", 'must be a JSON object') unless ref $hub eq 'HASH';
  my %out;
  for my $key (sort keys %$hub) {
    _err("$path.hub.$key", "unknown key '$key'") unless $ENTRY_HUB_KEYS{$key};
  }
  $out{idle_timeout}    = _int("$path.hub.idle_timeout",    $hub->{idle_timeout})    if exists $hub->{idle_timeout};
  $out{request_timeout} = _int("$path.hub.request_timeout", $hub->{request_timeout}) if exists $hub->{request_timeout};
  $out{always_on}       = $hub->{always_on} ? 1 : 0                                  if exists $hub->{always_on};
  return %out;
}

sub _parse_hub ($self, $hub) {
  for my $key (sort keys %$hub) {
    _err("hub.$key", "unknown key '$key'") unless $HUB_KEYS{$key};
  }

  $self->listen($hub->{listen})                             if defined $hub->{listen};
  $self->cache_dir(_tilde($hub->{cache_dir}))               if defined $hub->{cache_dir};
  $self->idle_timeout(_int('hub.idle_timeout', $hub->{idle_timeout}))       if exists $hub->{idle_timeout};
  $self->request_timeout(_int('hub.request_timeout', $hub->{request_timeout})) if exists $hub->{request_timeout};

  my $profiles = $hub->{profiles} // {};
  _err('hub.profiles', 'must be a JSON object') unless ref $profiles eq 'HASH';
  $self->profiles({map { $_ => $self->_parse_profile($_, $profiles->{$_}) } keys %$profiles});

  my $clients = $hub->{clients} // {};
  _err('hub.clients', 'must be a JSON object') unless ref $clients eq 'HASH';
  $self->clients({map { $_ => $self->_parse_client($_, $clients->{$_}) } keys %$clients});

  if (defined(my $public = $hub->{public_profile})) {
    _err('hub.public_profile', "unknown profile '$public'") unless $self->profiles->{$public};
    $self->public_profile($public);
  }

  # The mode is derived, never declared.
  $self->mode(keys %{$self->clients} ? 'clients' : 'open');

  return $self;
}

sub _parse_profile ($self, $name, $profile) {
  my $path = "hub.profiles.$name";
  _err($path, 'must be a JSON object') unless ref $profile eq 'HASH';
  for my $key (sort keys %$profile) {
    _err("$path.$key", "unknown key '$key'") unless $PROFILE_KEYS{$key};
  }

  my $servers = $profile->{servers} // ['*'];
  _err("$path.servers", 'must be a JSON array') unless ref $servers eq 'ARRAY';

  my %tools;
  if (defined(my $tools = $profile->{tools})) {
    _err("$path.tools", 'must be a JSON object') unless ref $tools eq 'HASH';
    for my $srv (sort keys %$tools) {
      my $rule = $tools->{$srv};
      _err("$path.tools.$srv", 'must be a JSON object') unless ref $rule eq 'HASH';
      for my $key (sort keys %$rule) {
        _err("$path.tools.$srv.$key", "unknown key '$key'") unless $TOOL_RULE_KEYS{$key};
      }
      $tools{$srv} = {
        (exists $rule->{allow} ? (allow => $rule->{allow}) : ()),
        (exists $rule->{deny}  ? (deny  => $rule->{deny})  : ()),
      };
    }
  }

  return {servers => $servers, tools => \%tools, admin => ($profile->{admin} ? 1 : 0)};
}

sub _parse_client ($self, $name, $client) {
  my $path = "hub.clients.$name";
  _err($path, 'must be a JSON object') unless ref $client eq 'HASH';
  for my $key (sort keys %$client) {
    _err("$path.$key", "unknown key '$key'") unless $CLIENT_KEYS{$key};
  }
  _err($path, "'token' is required")   unless defined $client->{token} && length $client->{token};
  _err($path, "'profile' is required") unless defined $client->{profile};
  _err("$path.profile", "unknown profile '$client->{profile}'") unless $self->profiles->{$client->{profile}};
  return {name => $name, token => $client->{token}, profile => $client->{profile}};
}

sub _expand ($self, $value, $path) {
  return $value unless defined $value && !ref $value;
  $value =~ s/\$\{(\w+)(?::-([^}]*))?\}/_resolve($1, $2, $path)/ge;
  return $value;
}

sub _resolve ($var, $default, $path) {
  return $ENV{$var} if defined $ENV{$var};
  return $default   if defined $default;
  _err($path, "environment variable \$$var is not set and has no default");
}

sub _default_cache_dir {
  my $base = $ENV{XDG_CACHE_HOME} || ($ENV{HOME} ? "$ENV{HOME}/.cache" : '.cache');
  return "$base/mcp-hub";
}

sub _int ($path, $value) {
  _err($path, 'must be an integer') unless defined $value && $value =~ /^-?\d+$/;
  return $value + 0;
}

sub _tilde ($path) {
  return $path unless defined $path;
  my $home = $ENV{HOME} // '~';
  $path =~ s!^~(?=/|$)!$home!;
  return $path;
}

sub _err ($path, $message) {
  my $where = length $path ? " at $path" : '';
  croak "Invalid configuration$where: $message\n";
}

1;

=encoding utf8

=head1 SYNOPSIS

  use MCP::Hub::Config;

  my $config = MCP::Hub::Config->from_file('~/.config/mcp-hub/config.json');
  my $config = MCP::Hub::Config->from_data({mcpServers => {...}, hub => {...}});

  say $config->mode;                 # 'open' or 'clients'
  say $_->{name} for @{$config->servers};

=head1 DESCRIPTION

L<MCP::Hub::Config> reads the one JSON file that configures an L<MCP::Hub>,
validates it, expands C<${VAR}> and C<${VAR:-default}> references, applies the
defaults, and derives the authentication mode. It is pure data: the only I/O it
performs is reading the file in L</from_file>.

The configuration is a superset of C<.mcp.json>. An C<mcpServers> block on its
own is a valid open-mode hub configuration, so an existing C<.mcp.json> can be
handed to the hub unchanged.

Every problem is reported with the JSON path where it was found, for example
C<Invalid configuration at mcpServers.playwright.hub.idle_timeout: must be an
integer>, so a typo surfaces at start-up instead of hours later.

=head1 ATTRIBUTES

=head2 cache_dir

  my $dir = $config->cache_dir;

Directory the manifest cache lives under. Defaults to C<$XDG_CACHE_HOME/mcp-hub>
or C<~/.cache/mcp-hub>. A leading C<~/> is expanded.

=head2 clients

  my $clients = $config->clients;

Hash reference of C<< name => { name, token, profile } >>. Empty in open mode.

=head2 idle_timeout

Seconds of no requests before a stdio upstream is stopped. Defaults to C<300>.

=head2 listen

Listen address for the daemon. Defaults to C<http://127.0.0.1:3080>.

=head2 mode

C<open> when L</clients> is empty, C<clients> otherwise. Derived, never declared.

=head2 profiles

Hash reference of normalized profiles, each C<< { servers, tools, admin } >>.

=head2 public_profile

Name of the profile applied to requests without a token in clients mode, or
C<undef>.

=head2 request_timeout

Seconds to wait for an upstream response. Defaults to C<60>.

=head2 servers

Array reference of normalized server entries, in name order. Each entry is a
hash reference with C<name>, C<type> (C<stdio> or C<perl>) and the type-specific
keys (C<command>/C<args>/C<env>/C<cwd> for stdio, C<class>/C<class_args> for
perl), plus any per-entry C<idle_timeout>, C<request_timeout> and C<always_on>.

=head2 source

Where the configuration came from, for error messages. A file path, or
C<config> for data passed directly.

=head1 METHODS

=head2 from_file

  my $config = MCP::Hub::Config->from_file($path);

Read, decode and validate the JSON file at C<$path>. Dies with a clear message
if the file is missing, is not valid JSON, or fails validation.

=head2 from_data

  my $config = MCP::Hub::Config->from_data($hashref);
  my $config = MCP::Hub::Config->from_data($hashref, $source);

Validate an already-decoded configuration. Useful in tests.

=head2 server

  my $entry = $config->server('context7');

The normalized entry for a server by name, or C<undef>.

=head2 server_names

  my $names = $config->server_names;

Array reference of the configured server names, in order.

=head1 SEE ALSO

L<MCP::Hub>, L<MCP>.

=cut
