#!/usr/bin/env perl
# A tiny stdio MCP server used by the hub's test suite. It speaks the legacy
# handshake (via MCP::Server::Legacy, server side) and offers just enough
# behaviour to exercise every path in MCP::Hub::Upstream::Stdio -- without any
# node, python or network. This is the ONLY upstream the test suite spawns;
# the fake docker CLI (fake-docker.pl) runs it as its "containers", over stdio
# or, with --http, over HTTP on the loopback.
use Mojo::Base -strict, -signatures;

use FindBin;
use lib "$FindBin::Bin/../lib";

use EchoServer;
use Mojo::JSON qw(decode_json encode_json);
use POSIX ();

# --bad-error=string|array switches the peer into a mode that answers a
# tools/call with a broken error shape -- "error": "text" or "error": [..]
# instead of the error object the protocol asks for. Upstreams in the wild do
# that, and the hub must report it instead of leaving the request pending.
my $BAD_ERROR = (grep { m{^--bad-error=(?:string|array)$} } @ARGV)[0];
$BAD_ERROR =~ s/^--bad-error=// if defined $BAD_ERROR;
if (defined $BAD_ERROR) { _bad_error_peer($BAD_ERROR); exit 0 }

# The server itself is t/lib/EchoServer.pm, which `class` entries mount too.
my $server = EchoServer->new;

# --die-mid-line adds a tool `cut` that writes the first half of its answer
# and is killed before the rest: what a child that crashes in the middle of a
# line leaves the hub with.
if (grep { $_ eq '--die-mid-line' } @ARGV) {
  $server->tool(
    name         => 'cut',
    description  => 'Write half an answer, then die by SIGKILL',
    input_schema => {type => 'object'},
    code         => sub ($tool, $args) {
      syswrite STDOUT, '{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"cut off';
      kill 'KILL', $$;
    },
  );
}

# --http=PORT serves the same server over Streamable HTTP at
# http://127.0.0.1:PORT/mcp instead of stdio: what t/upstream/fake-docker.pl
# runs for an HTTP container. --http-delay=SECONDS waits that long before it
# listens, like a server that is slow to come up behind a published port.
my ($HTTP) = map { /^--http=(\d+)$/ ? $1 : () } @ARGV;
if (defined $HTTP) { _serve_http($server, $HTTP); exit 0 }

# How it ends, for the tests of a stop (t/stdio-stop.t): --signals=FILE writes
# a line "TERM <epoch seconds>" to FILE for every SIGTERM, and exits on it --
# unless --ignore-term. At the end of its input it exits, like any stdio
# server; --eof-delay=SECONDS takes that long first (finishing a commit, say),
# --ignore-eof does not, and goes on until a signal ends it -- or a minute is
# over: the orphan of a test that failed half-way ends all the same.
# --notify-on-eof writes a notifications/tools/list_changed first, as a server
# that unloads its tools on the way out may.
# --chatty=SECONDS writes a notifications/tools/list_changed every SECONDS, with
# nothing changed, as a server may whose tools come and go: the hub answers
# each with a refresh (t/idle.t). A process of its own writes them, to the
# same stdout -- the server blocks on its stdin between requests -- and ends
# once the server is gone.
my ($CHATTY)    = map { /^--chatty=([\d.]+)$/    ? $1 : () } @ARGV;
_chatter($CHATTY) if $CHATTY;

my ($SIGNALS)   = map { /^--signals=(.+)$/       ? $1 : () } @ARGV;
my ($EOF_DELAY) = map { /^--eof-delay=([\d.]+)$/ ? $1 : () } @ARGV;
if (defined $SIGNALS) {
  my $ignore = grep { $_ eq '--ignore-term' } @ARGV;
  $SIG{TERM} = sub {
    require Time::HiRes;
    open my $fh, '>>', $SIGNALS or die "$SIGNALS: $!\n";
    printf $fh "TERM %.3f\n", Time::HiRes::time();
    close $fh;
    exit 0 unless $ignore;
  };
}

$server->to_stdio;
if (grep { $_ eq '--notify-on-eof' } @ARGV) {
  STDOUT->autoflush(1);
  print STDOUT encode_json({jsonrpc => '2.0', method => 'notifications/tools/list_changed'}), "\n";
}
select undef, undef, undef, $EOF_DELAY if $EOF_DELAY;
if (grep { $_ eq '--ignore-eof' } @ARGV) { sleep 1 for 1 .. 60 }

sub _chatter ($seconds) {
  my $server = $$;
  my $pid    = fork // die "fork: $!\n";
  return if $pid;
  close STDIN;
  STDOUT->autoflush(1);
  while (1) {
    select undef, undef, undef, $seconds;
    POSIX::_exit(0) if getppid != $server;
    print STDOUT encode_json({jsonrpc => '2.0', method => 'notifications/tools/list_changed'}), "\n";
  }
}

sub _serve_http ($server, $port) {
  require Mojolicious;
  require Mojo::Server::Daemon;
  my ($delay) = map { /^--http-delay=([\d.]+)$/ ? $1 : () } @ARGV;
  select undef, undef, undef, $delay if $delay;

  my $app = Mojolicious->new;
  $app->log->level('fatal');
  $app->routes->post('/mcp' => $server->to_action({streaming => 1}));
  Mojo::Server::Daemon->new(app => $app, listen => ["http://127.0.0.1:$port"], silent => 1)->run;
  return;
}

# A hand-rolled peer: it speaks just enough of the legacy handshake to get the
# hub to call a tool, and answers that call with an error that is not an object.
sub _bad_error_peer ($shape) {
  $| = 1;    # the hub reads line by line, so nothing may sit in the buffer

  while (my $line = <STDIN>) {
    my $msg = eval { decode_json($line) };
    next unless ref $msg eq 'HASH';
    my $id = $msg->{id};
    next unless defined $id;    # a notification gets no answer
    my $method = $msg->{method} // '';
    if ($method eq 'initialize') {
      _reply({jsonrpc => '2.0', id => $id, result => {
        protocolVersion => '2025-06-18',
        capabilities    => {},
        serverInfo      => {name => 'bad-error-server', version => '0.0.1'},
      }});
    }
    elsif ($method eq 'tools/list') {
      _reply({jsonrpc => '2.0', id => $id, result => {tools => [
        {name => 'boom', description => 'Answers with a broken error', inputSchema => {type => 'object'}},
      ]}});
    }
    else {
      my $error = $shape eq 'string' ? 'nope' : ['nope', 'still nope'];
      _reply({jsonrpc => '2.0', id => $id, error => $error});
    }
  }
  return;
}

sub _reply ($obj) { print STDOUT encode_json($obj) . "\n" }
