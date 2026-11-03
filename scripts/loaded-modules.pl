#!/usr/bin/env perl
# Print the modules the mcp-hub binary loads, one per line (Foo::Bar), by running
# the real commands and a real daemon round trip. Run it from the checkout root:
#
#   perl -Ilib scripts/loaded-modules.pl              # the loaded set
#   perl -Ilib scripts/loaded-modules.pl --left-out   # the families left out
#
# build-binary.sh turns the loaded set into pp -M options and the left-out families
# into -X options; verify-binary.sh requires every loaded module inside the packed
# archive and no file of a left-out family. One source, so the three cannot drift.
# The list goes to STDOUT, problems to STDERR.
#
# pp's scanner reads source and misses whatever loads by name, which in mcp-hub is a
# lot: Mojolicious finds the commands (MCP::Hub::Command::*, Mojolicious::Command::*)
# by namespace, its plugins and the reactor by name; Upstream::Perl mounts a `class`
# (the natives MCP::Hub::Native::*) through Mojo::Loader; MCP::Hub::Config requires
# YAML::PP only when a .yml/.yaml is read, and YAML::PP loads its schema by name;
# Mojo::IOLoop::TLS requires IO::Socket::SSL in an eval, and IO::Socket::SSL requires
# Mozilla::CA only when the host has no trust store of its own. Running all of that
# for real -- the daemon listens on http and https, and a `url` upstream speaks https
# -- is what makes the set complete.
use strict;
use warnings;

# What the binary leaves out, whatever the build host has installed: the code runs
# without each, and packing it would make one platform's binary behave unlike
# another's. A name is that module; a name ending in :: is everything below it.
#   EV, Mojo::Reactor::EV  the reactor is Mojo::Reactor::Poll everywhere, as in the
#                          Docker image and a plain `cpanm MCP::Hub` (EV is no
#                          dependency). MCP::Hub uses EV only when it is the
#                          running reactor (SIGHUP watcher, Docker child reaping).
#   IO::Socket::Socks, Net::DNS::Native, Cpanel::JSON::XS, Role::Tiny,
#   Future::AsyncAwait     Mojolicious extras switched on only when installed;
#                          neither the hub nor MCP uses them.
#   JSON, JSON::XS, JSON::backportPP
#                          CryptX requires JSON.pm when installed, for JWK only,
#                          and JSON.pm picks its backend by name. JSON::PP is core
#                          and stays: the config command and the setup page use it.
#   LWP                    IO::Socket::SSL::PublicSuffix requires LWP::UserAgent in
#                          update_self_from_url, a maintainer's tool; LWP would drag
#                          in HTTP::Message and its compression XS modules.
#   URI, Net::IDN::Encode, Net::LibIDN
#                          PublicSuffix's IDN backends, used only for host names
#                          with non-ASCII characters -- Mojolicious hands
#                          IO::Socket::SSL the punycode form, and wildcard checks
#                          work without one. URI is no dependency of the hub, so
#                          only a build host that happens to have it would pack it;
#                          libidn is not a system library.
my @LEFT_OUT;
BEGIN {
  @LEFT_OUT = qw(
    EV EV:: Mojo::Reactor::EV
    IO::Socket::Socks IO::Socket::Socks:: Net::DNS::Native Cpanel::JSON::XS Cpanel::JSON::XS::
    Role::Tiny Role::Tiny:: Future::AsyncAwait Future::AsyncAwait::
    JSON JSON::XS JSON::XS:: JSON::backportPP JSON::backportPP::
    LWP LWP:: URI URI:: Net::IDN::Encode Net::IDN:: Net::LibIDN Net::LibIDN::
  );
  if ( ( $ARGV[0] // '' ) eq '--left-out' ) {
    print "$_\n" for @LEFT_OUT;
    exit 0;
  }
}

sub left_out {
  my ($m) = @_;
  for my $spec (@LEFT_OUT) {
    return 1 if $spec =~ /::\z/ ? index( $m, $spec ) == 0 : $m eq $spec;
  }
  return 0;
}

my $root;
BEGIN {
  require Cwd;
  require File::Basename;
  $root = Cwd::abs_path( File::Basename::dirname(__FILE__) . '/..' );
  -f "$root/bin/mcp-hub" or die "loaded-modules: no bin/mcp-hub below $root\n";

  # Run like the binary would: the left-out families cannot be loaded at all, so
  # every `eval { require ... }` fallback takes the path the binary takes.
  unshift @INC, sub {
    my ( undef, $file ) = @_;
    return unless $file =~ /\.pm\z/;
    ( my $m = $file ) =~ s{/}{::}g;
    $m =~ s/\.pm\z//;
    die "Can't locate $file in \@INC (left out of the mcp-hub binary)\n" if left_out($m);
    return;
  };

  # Never the maintainer's own configuration, never a live reactor choice, never a
  # trust store or proxy of this shell's.
  delete @ENV{qw( MCP_HUB_CONFIG XDG_CONFIG_HOME CLAUDE_CONFIG_DIR MOJO_MODE MOJO_REACTOR MOJO_HOME
    SSL_CERT_FILE SSL_CERT_DIR MOJO_CA_FILE MOJO_CERT_FILE MOJO_KEY_FILE MOJO_INSECURE
    HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy )};
}

use File::Temp ();
use Mojo::File qw( path );
use Mojo::IOLoop::Server;
use Mojo::UserAgent;
use POSIX ();

my $tmp = File::Temp::tempdir( CLEANUP => 1 );
$ENV{HOME} = "$tmp/home";
mkdir $ENV{HOME} or die $!;

# The dist's own modules, from the checkout (an installed MCP::Hub may be older).
my %mods;
path( $root, 'lib' )->list_tree->each( sub {
  return unless /\.pm\z/;
  ( my $m = $_->to_rel( path( $root, 'lib' ) ) ) =~ s{/}{::}g;
  $m =~ s/\.pm\z//;
  $mods{$m} = 1;
} );
for my $m ( sort keys %mods ) {
  eval "require $m; 1" or warn "loaded-modules: not loadable: $m (" . ( split /\n/, $@ )[0] . ")\n";
}
# Loaded by name on some path only, and the binary needs each: the YAML reader, the
# reactor, and the CA bundle IO::Socket::SSL falls back to on a host without a trust
# store of its own (a missing one would show nowhere else, so it ends the run).
for my $m (qw( YAML::PP Mojo::Reactor::Poll Mozilla::CA )) {
  eval "require $m; 1" or die "loaded-modules: $m is not installed (" . ( split /\n/, $@ )[0] . ")\n";
}
require MCP::Hub;
# The binary speaks TLS. Without IO::Socket::SSL 2.009+ (and Net::SSLeay) Mojolicious
# switches TLS off without a word, and the set would come out without it.
require Mojo::IOLoop::TLS;
Mojo::IOLoop::TLS->can_tls
  or die "loaded-modules: no TLS in this perl: IO::Socket::SSL 2.009+ and Net::SSLeay are needed\n";

# --- fixtures ----------------------------------------------------------------

my $port   = Mojo::IOLoop::Server->generate_port;
my $listen = "http://127.0.0.1:$port";
my $echo   = "$root/t/upstream/echo.sh";
my $claude = "$root/t/fixtures/claude";

# The daemon also listens on https, with the test certificate of
# t/fixtures/binary/tls/; whoever trusts its ca.crt verifies the connection.
my $tls_dir    = "$root/t/fixtures/binary/tls";
my $tls_port   = Mojo::IOLoop::Server->generate_port;
my $tls        = "https://127.0.0.1:$tls_port";
my $tls_listen = "$tls?cert=$tls_dir/server.crt&key=$tls_dir/server.key";

# Every kind of entry: stdio, the three natives, a remote HTTP upstream (the hub's
# own /history, over https), a container and a compose service (their docker CLI
# does not exist, so they fail fast without touching a container engine).
my $yaml = <<"YAML";
# the daemon's configuration, as YAML: YAML::PP loads in the daemon too
mcpServers:
  echo:     {command: sh, args: ['$echo']}
  history:  {class: MCP::Hub::Native::ClaudeHistory, args: {root: '$claude'}}
  sessions: {class: MCP::Hub::Native::ClaudeSessions, args: {root: '$claude'}}
  hub:      {class: MCP::Hub::Native::Status}
  remote:   {url: '$tls/history'}
  boxed:    {docker: 'example/mcp-server:1'}
  stack:    {compose: '$tmp', service: mcp}
hub:
  listen: '$listen'
  cache_dir: '$tmp/cache'
  docker_command: '$tmp/no-such-docker'
YAML
path( $tmp, 'daemon.yml' )->spew($yaml);
path( $tmp, 'clients.json' )->spew( <<'JSON' );
{"mcpServers": {"hub": {"class": "MCP::Hub::Native::Status"}},
 "hub": {"profiles": {"all": {"admin": true}},
         "clients": {"main": {"token": "secret-token", "profile": "all"}}}}
JSON
path( $tmp, 'broken.json' )->spew('{ "mcpServers": ');
path( $tmp, 'broken.yml' )->spew("mcpServers: [\n");
path( $tmp, 'unknown.json' )->spew('{ "hub": { "bogus_key": true } }');

# One CLI run, as bin/mcp-hub does it: --config goes to the environment, then the
# command layer. Output is discarded; a command that dies is an error path we want.
sub cli {
  my ( $config, @args ) = @_;
  local $ENV{MCP_HUB_CONFIG} = $config if defined $config;
  open my $oldout, '>&', \*STDOUT or die $!;
  open my $olderr, '>&', \*STDERR or die $!;
  open STDOUT, '>', '/dev/null' or die $!;
  open STDERR, '>', '/dev/null' or die $!;
  eval { MCP::Hub->new( cli => 1 )->start(@args); 1 };
  open STDOUT, '>&', $oldout or die $!;
  open STDERR, '>&', $olderr or die $!;
  return;
}

# --- the short-lived commands ------------------------------------------------

my $config_json = "$root/t/fixtures/binary/config.json";
my $config_yml  = "$root/t/fixtures/binary/config.yaml";
cli( undef, @$_ ) for ( [], ['help'], ['--help'], ['token'], ['nope'] );
cli( undef, 'help', $_ ) for qw( daemon config status refresh reload token eval get routes version );
cli( $config_json, 'config' );
cli( $config_json, 'config', '--all', '--url', 'http://127.0.0.1:1' );
cli( $config_yml,  'config' );
cli( $config_json, 'routes' );
cli( $config_json, 'eval', 'app->hub_config->listen' );
cli( "$tmp/clients.json", 'config', '--client', 'main' );
cli( "$tmp/clients.json", 'config' );    # clients mode without --client: an error
cli( "$tmp/$_", 'config' ) for qw( broken.json broken.yml unknown.json missing.json );

# --- a real daemon, and the commands that talk to it --------------------------
# The daemon runs in a child and writes its %INC on the way out; this process is
# the client side.

my $inc_file = "$tmp/daemon-inc";
my $pid      = fork // die "fork: $!";
if ( !$pid ) {
  open STDOUT, '>', '/dev/null' or die $!;
  open STDERR, '>', "$tmp/daemon.log" or die $!;
  local $ENV{MCP_HUB_CONFIG} = "$tmp/daemon.yml";
  local $ENV{SSL_CERT_FILE}  = "$tls_dir/ca.crt";    # the remote upstream verifies the hub
  eval { MCP::Hub->new( cli => 1 )->start( 'daemon', '-l', $listen, '-l', $tls_listen ); 1 }
    or print STDERR "daemon died: $@";
  open my $fh, '>', $inc_file or die $!;
  print {$fh} "$_\t" . ( ref $INC{$_} ? 'REF' : $INC{$_} // '' ) . "\n" for sort keys %INC;
  close $fh;
  POSIX::_exit(0);
}

# Each step must have worked: a round trip that failed loaded less than the real
# one does, and the set would come out short. Any miss ends the run with the log.
my @missed;
sub expect {
  my ( $what, $res, $like ) = @_;
  my ( $code, $text ) = @$res;
  push @missed, "$what: got " . ( $code // 'no response' ) . ' ' . substr( $text, 0, 200 ) unless $text =~ $like;
  return;
}

my $ua = Mojo::UserAgent->new( request_timeout => 30, ca => "$tls_dir/ca.crt" );
my $up;
for ( 1 .. 300 ) {
  last if $up = ( $ua->get("$listen/")->res->code // 0 ) == 200;
  select undef, undef, undef, 0.1;
}
push @missed, 'the daemon did not come up' unless $up;

# [code, text] of a request; an answer streamed as server-sent events (every
# call that waits on an upstream) counts with the text of its events.
sub request {
  my $tx   = $ua->build_tx(@_);
  my $text = '';
  $tx->res->content->on( sse => sub { $text .= ( $_[1]{text} // '' ) . "\n" if $_[1] } );
  $tx = $ua->start($tx);
  return [ $tx->res->code, $tx->res->body . $text ];
}

my $id = 0;
sub mcp {
  my ( $server, $method, $params ) = @_;
  my $res;
  for ( 1 .. 100 ) {    # 503 while the first manifest is still being fetched
    $res = request( POST => "$listen/$server",
      json => { jsonrpc => '2.0', id => ++$id, method => $method, params => $params // {} } );
    last unless ( $res->[0] // 0 ) == 503;
    select undef, undef, undef, 0.2;
  }
  return $res;
}

if ($up) {
  expect( "tools/list $_->[0]", mcp( $_->[0], 'tools/list' ), $_->[1] )
    for ( [ history => qr/list_projects/ ], [ sessions => qr/"name":"\w/ ], [ hub => qr/hub_status/ ],
          [ echo => qr/"echo"/ ], [ remote => qr/list_projects/ ], [ all => qr/echo__echo/ ] );
  expect( 'tools/call echo', mcp( 'echo', 'tools/call', { name => 'echo', arguments => { msg => 'hi there' } } ),
    qr/hi there/ );
  expect( "tools/call $_ list_projects", mcp( $_, 'tools/call', { name => 'list_projects', arguments => {} } ),
    qr/proj-a/ ) for qw( history remote );
  expect( 'tools/call hub_status', mcp( 'hub', 'tools/call', { name => 'hub_status', arguments => {} } ),
    qr/upstreams/ );
  expect( 'tools/call all echo__echo',
    mcp( 'all', 'tools/call', { name => 'echo__echo', arguments => { msg => 'via all' } } ), qr/via all/ );
  expect( 'GET /',            request( GET => "$listen/", { Accept => 'text/html' } ), qr/<html/i );
  expect( 'GET /_hub/status', request( GET => "$listen/_hub/status" ), qr/"upstreams"/ );
  expect( 'GET /_hub/status over https', request( GET => "$tls/_hub/status" ), qr/"upstreams"/ );
  expect( 'GET /no/such/route', request( GET => "$listen/no/such/route", { Accept => 'text/html' } ), qr/<html/i );
  $ua->post( "$listen/no-such-server", json => { jsonrpc => '2.0', id => 1, method => 'tools/list' } );
  $ua->post( "$listen/history", { 'Content-Type' => 'application/json' }, 'not json' );
  cli( undef, @$_ )
    for ( [ 'status', '--url', $listen ], [ 'refresh', '--url', $listen, 'echo' ], [ 'reload', '--url', $listen ],
          [ 'get', '-M', 'POST', '-H', 'Content-Type: application/json',
            '-c', '{"jsonrpc":"2.0","id":1,"method":"tools/list"}', "$listen/history" ] );
}
kill 'TERM', $pid;
waitpid $pid, 0;
push @missed, 'the daemon wrote no module list' unless -s $inc_file;
die "loaded-modules: the daemon round trip failed, the set would be short:\n  "
  . join( "\n  ", @missed ) . "\n--- daemon log\n" . ( eval { path("$tmp/daemon.log")->slurp } // '' )
  if @missed;
cli( undef, 'status', '--url', $listen );    # the hub is gone: the error path

# --- the set -------------------------------------------------------------------

my %inc = map { $_ => $INC{$_} } grep { !ref $INC{$_} } keys %INC;
open my $fh, '<', $inc_file or die "loaded-modules: $inc_file: $!\n";
while (<$fh>) {
  chomp;
  my ( $k, $v ) = split /\t/, $_, 2;
  $inc{$k} //= $v unless $v eq 'REF';
}

for my $file ( sort keys %inc ) {
  next unless $file =~ m{\A[\w/]+\.pm\z};
  next unless defined $inc{$file} && $inc{$file} =~ m{/\Q$file\E\z};
  ( my $m = $file ) =~ s{/}{::}g;
  $m =~ s/\.pm\z//;
  next if left_out($m);
  print "$m\n";
}
