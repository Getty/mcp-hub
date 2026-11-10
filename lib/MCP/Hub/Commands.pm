package MCP::Hub::Commands;
our $VERSION = '0.001';
use Mojo::Base 'Mojolicious::Commands', -signatures;

use Mojo::Loader qw(find_modules find_packages load_class);
use Mojo::Util   qw(tablify);

# ABSTRACT: The mcp-hub command line, without the ways to serve the hub as more than one process

# Ours first: our daemon must win over the built-in Mojolicious::Command::daemon
# (which ignores the configured listen address). Mojolicious::Command::Author is
# left out: generate, inflate and cpanify scaffold, unpack or upload a
# Mojolicious application or a CPAN distribution, nothing a hub has a use for.
has namespaces => sub { ['MCP::Hub::Command', 'Mojolicious::Command'] };

# The text above and below the command list. The inherited one is the mojo
# command's: its examples, CGI/PSGI auto-detection and PLACK_ENV as the mode.
has message => <<'MESSAGE';
Usage: mcp-hub [--config PATH] COMMAND [OPTIONS]

  mcp-hub daemon
  mcp-hub config --client main
  mcp-hub --config ~/hub.yml status
  mcp-hub help daemon

Options (before the command name):
  -c, --config <path>   Configuration file, JSON or YAML; defaults to the value
                        of MCP_HUB_CONFIG, else config.json, config.yml or
                        config.yaml in ~/.config/mcp-hub

Options (for all commands, after the command name):
  -h, --help            Get more information on a specific command
  -m, --mode <name>     Operating mode, defaults to the value of MOJO_MODE or
                        "development"

Commands:
MESSAGE
has hint => <<'HINT';

See 'mcp-hub help COMMAND' for more information on a specific command.
HINT

# The Mojolicious commands that would serve the hub outside the one daemon
# process, and why each cannot.
my %REFUSED = (
  prefork => "a pre-forking server's workers would each start their own upstreams and keep their own state",
  cgi     => 'CGI builds a new hub for every request and drops it, with every upstream it started, when the request ends',
  psgi    => 'under PSGI the Plack server, not the hub, decides how many processes serve it and when its event loop runs',
);

# What makes Mojolicious::Commands->detect pick cgi or psgi over the command name.
my %DETECTED_BY = (cgi => [qw(PATH_INFO GATEWAY_INTERFACE)], psgi => ['PLACK_ENV']);

# The servers that are no command but load mcp-hub as an app to serve it in
# more than one process, or one after another, and why each cannot.
my %UNDER = (
  hypnotoad => 'hypnotoad serves it from pre-forked workers, and each would start its own upstreams and keep its own state',
  morbo     => 'morbo ends its worker and starts another on every file change, without the wait for the upstreams the old one started, the background fetches and the reloads of the daemon command',
);

# Why any other server cannot: it is neither the one process nor one we know.
my $NOT_PLAIN = 'only a plain Mojo::Server::Daemon serves it as that one process';

sub run ($self, $name = undef, @args) {
  # Loaded by a server (Mojo::Server->load_app): Mojolicious hands it the app --
  # unless the server is hypnotoad, which sets HYPNOTOAD_APP before it loads
  # the app and then pre-forks.
  if (defined $ENV{MOJO_APP_LOADER}) {
    die $self->_refusal('hypnotoad', under => 1)
      if defined $ENV{HYPNOTOAD_APP} || $INC{'Mojo/Server/Hypnotoad.pm'};
    return $self->SUPER::run($name, @args);
  }

  # Mojolicious lets a CGI or PSGI environment replace the command name.
  my $env = !$ENV{MOJO_NO_DETECT} && $self->detect;
  die $self->_refusal($env, detected => 1) if $env && $REFUSED{$env};

  my $help    = defined $name && $name eq 'help';
  my $command = $help ? $args[0] : $name;
  die $self->_refusal($command) if $command && $REFUSED{$command};

  # The cases in which Mojolicious::Commands prints its command list.
  return $self->_list if !$name || ($help && !$args[0]) || $name eq '--help' || $name eq '-h';

  return $self->SUPER::run($name, @args);
}

# Why $server cannot serve the hub, or undef when it can. MCP::Hub asks as any
# server starts it (before_server_start), which catches what never comes past
# run: a script of its own that hands the hub to a pre-forking server.
sub server_refusal ($self, $server) {
  my $class = ref $server;

  # morbo's worker serves the app from a plain daemon. Only the morbo script
  # loads Mojo::Server::Morbo, and its worker is forked from it.
  return $self->_refusal('morbo', under => 1) if $class eq 'Mojo::Server::Daemon' && $INC{'Mojo/Server/Morbo.pm'};
  return undef if $class eq 'Mojo::Server::Daemon';
  my $name
    = $server->isa('Mojo::Server::Prefork') ? ($INC{'Mojo/Server/Hypnotoad.pm'} ? 'hypnotoad' : 'prefork')
    : $server->isa('Mojo::Server::CGI')     ? 'cgi'
    : $server->isa('Mojo::Server::PSGI')    ? 'psgi'
    :                                         $class;
  return $self->_refusal($name, under => 1);
}

sub _refusal ($self, $name, %opt) {
  my $why = 'the hub is one process that owns every upstream and all state; '
    . ($REFUSED{$name} // $UNDER{$name} // $NOT_PLAIN);
  return qq{mcp-hub refuses to run under $name: $why. Run "mcp-hub daemon" instead.\n} if $opt{under};
  return qq{mcp-hub refuses "$name": $why. Run "mcp-hub daemon" instead.\n} unless $opt{detected};

  my $set = join ' and ', grep { defined $ENV{$_} } @{$DETECTED_BY{$name}};
  return 'mcp-hub refuses to run as ' . uc($name) . " ($set set): $why. "
    . qq{Run "mcp-hub daemon" instead, with $set unset or MOJO_NO_DETECT=1.\n};
}

# The list Mojolicious::Commands prints, less the refused commands.
sub _list ($self) {
  return 1 if $ENV{HARNESS_ACTIVE};    # as Mojolicious: no list under a test harness

  my %all;
  for my $ns (@{$self->namespaces}) {
    for my $module (find_modules($ns), find_packages($ns)) {
      my $name = substr $module, length "${ns}::";
      next if $REFUSED{$name} || exists $all{$name};
      next if load_class($module) || !$module->isa('Mojolicious::Command');
      $all{$name} = $module->new->description;
    }
  }

  my @rows = map { [' ' . s/(?<!^)_/-/gr, $all{$_}] } sort keys %all;
  return print $self->message, tablify(\@rows), $self->hint;
}

1;

=encoding utf8

=head1 SYNOPSIS

  # MCP::Hub
  has commands => sub ($self) { MCP::Hub::Commands->new(app => $self) };

  mcp-hub prefork      # mcp-hub refuses "prefork": the hub is one process ...

=head1 DESCRIPTION

L<MCP::Hub::Commands> is the command line of L<mcp-hub>: the
L<Mojolicious::Commands> every Mojolicious application has, with the hub's own
commands (L<MCP::Hub::Command>) searched first.

The hub has to be a single process that owns every upstream and all state, so
the commands that would serve it any other way are refused, each with the reason
and a pointer to C<mcp-hub daemon>:

=over 2

=item C<prefork>

A pre-forking server runs several workers, and each would start its own
upstreams and keep its own state.

=item C<cgi>

CGI builds a new hub for every request and drops it, with every upstream it
started, when the request ends.

=item C<psgi>

Under PSGI the Plack server decides how many processes serve the hub and when its
event loop runs.

=back

They are refused by name, as C<help NAME>, and when the environment would pick
them: L<Mojolicious::Commands/detect> turns any command into C<psgi> when
C<PLACK_ENV> is set and into C<cgi> when C<PATH_INFO> or C<GATEWAY_INTERFACE>
is, so C<PLACK_ENV=production mcp-hub daemon> would serve nothing at all. With
C<MOJO_NO_DETECT=1> the named command runs regardless. The command list leaves
the refused commands out.

hypnotoad is refused as well. It is no command: C<hypnotoad bin/mcp-hub> loads
the script as an app (L<Mojo::Server/load_app>) and serves it from pre-forked
workers, each of which would start its own upstreams and keep its own state. So
when C<mcp-hub> is loaded as an app while C<HYPNOTOAD_APP> is set or
L<Mojo::Server::Hypnotoad> is loaded, it dies instead of handing the app over.
Any other loader -- L<Test::Mojo/new> with the script, say -- still gets the app,
and a command line with C<HYPNOTOAD_APP> in its environment runs as ever.

A script of its own that hands the hub to a server never comes past L</run>,
so the hub asks again as any server starts it (C<before_server_start> in
L<MCP::Hub>): anything but a plain L<Mojo::Server::Daemon> -- a
L<Mojo::Server::Prefork>, built by hand or by hypnotoad, a L<Mojo::Server::CGI>
or L<Mojo::Server::PSGI>, a subclass of the daemon -- is refused there, before it
listens or forks, in the same words (L</server_refusal>).

So is morbo (C<morbo bin/mcp-hub>). It gets the app, and its worker serves it
from a plain daemon -- but with L<Mojo::Server::Morbo> loaded, which nothing
but morbo loads. It ends that worker and starts another on every file change,
without the wait for the upstreams the old one started, and it serves without
the background manifest fetches and the reloads that C<mcp-hub daemon> adds
around the server. The worker dies with the refusal; morbo goes on watching
files, serving nothing.

The author tools of L<Mojolicious::Command::Author> -- C<generate>, C<inflate>,
C<cpanify> -- are not searched; C<get>, C<routes>, C<eval> and C<version> stay.

=head1 ATTRIBUTES

=attr namespaces

Defaults to C<MCP::Hub::Command> and C<Mojolicious::Command>, in that order.

=attr message

The usage printed above the command list: C<mcp-hub> examples, the global
C<--config> and the options every command takes. It replaces the C<mojo> usage
of L<Mojolicious::Commands/message>, whose examples, CGI and PSGI auto-detection
and C<PLACK_ENV> mode the hub has no use for.

=attr hint

The line below the command list, pointing at C<mcp-hub help COMMAND>.

=head1 METHODS

=method run

  $commands->run('daemon', '-l', 'http://127.0.0.1:3080');

As L<Mojolicious::Commands/run>, but dies, with the reason and a pointer to
C<mcp-hub daemon>, for a refused command -- named or picked by the environment
-- and when loaded as an app by hypnotoad, and leaves the refused commands out
of the command list.

=method server_refusal

  my $why = $commands->server_refusal($server);

Why C<$server> cannot serve the hub -- the reason and the pointer to C<mcp-hub
daemon> a refused command gets -- or C<undef> when it can, when it is a plain
L<Mojo::Server::Daemon> and not morbo's. L<MCP::Hub> dies with it as that server
starts it.

=head1 SEE ALSO

L<mcp-hub>, L<MCP::Hub>, L<MCP::Hub::Command::daemon>, L<Mojolicious::Commands>.

=cut
