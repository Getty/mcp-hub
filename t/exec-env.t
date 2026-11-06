#!/usr/bin/env perl
# A child the hub execs starts with the hub's environment, less MOJO_REUSE.
# Mojo::IOLoop::Server keeps that variable in the hub's own %ENV as the list
# of its listening sockets, "address:port:fd" -- so that an exec'd hypnotoad
# can adopt them. The child holds none of those fds (MCP::Hub::Child closes
# them before the exec), and a Mojo app in it that listens on such an address
# would take the fd number for a socket: a dead one, or a file of its own.
# The entry's own env still goes on top, MOJO_REUSE included.
# The listener here is the one Test::Mojo starts, a Mojo::Server::Daemon like
# `mcp-hub daemon`.
use Mojo::Base -strict, -signatures;
use Test::More;

use Test::Mojo;
use Mojo::File qw(curfile tempdir);
use Mojo::Promise;
use MCP::Hub;
use MCP::Hub::Docker;

my $ECHO = curfile->sibling('upstream', 'echo.pl');
my $LIB  = curfile->dirname->sibling('lib');

# Run as `perl -e $RECORD FILE COMMAND...`: writes the environment it was
# exec'd with to FILE -- NUL-separated names and values, which no variable can
# hold -- then execs COMMAND, so the upstream behind it is echo.pl as usual.
my $RECORD = <<'PERL';
my $out = shift;
open my $fh, '>', "$out.tmp" or die "$out: $!";
print $fh map { "$_\0$ENV{$_}\0" } sort keys %ENV;
close $fh;
rename "$out.tmp", $out or die "$out: $!";
exec @ARGV or die "exec @ARGV: $!";
PERL

# The same environment, printed to stdout: what a docker CLI run sees.
my $PRINT_ENV = 'print map { "$_\0$ENV{$_}\0" } sort keys %ENV';

sub parse_env ($text) {
  my %env;
  $env{$1} = $2 while $text =~ /\G([^\0]*)\0([^\0]*)\0/g;
  return \%env;
}

sub wait_until ($cond, $seconds = 15) {
  my $deadline = time + $seconds;
  Mojo::Promise->timer(0.05)->wait until $cond->() || time > $deadline;
  return $cond->();
}

sub settle ($promise) {
  my $out;
  $promise->then(sub ($v) { $out = $v }, sub ($e) { $out = {err => $e} })->wait;
  return $out;
}

# ---------------------------------------------------------------------------

# Any variable of the hub's but MOJO_REUSE goes on to the child.
local $ENV{MCP_HUB_TEST_INHERITED} = 'k58';

my $tmp = tempdir;
my %record = (plain => $tmp->child('plain'), explicit => $tmp->child('explicit'));
my $app    = MCP::Hub->new(hub_config_input => {
  mcpServers => {
    plain    => {command => $^X, args => ['-e', $RECORD, "$record{plain}", $^X, "-I$LIB", "$ECHO"]},
    explicit => {
      command => $^X,
      args    => ['-e', $RECORD, "$record{explicit}", $^X, "-I$LIB", "$ECHO"],
      env     => {MOJO_REUSE => 'set-by-the-entry'},
    },
  },
  hub => {cache_dir => $tmp->child('cache')->to_string},
});
$app->log->level('fatal');
my $t = Test::Mojo->new($app);

my $port = $t->ua->server->url->port;    # the hub listens from here on
like $ENV{MOJO_REUSE}, qr/(?:^|,)127\.0\.0\.1:$port:\d+(?:,|$)/, "the hub's listener on port $port is in its MOJO_REUSE";

my %up = %{$app->upstreams_by_name};
$app->start_background_fetches;
ok wait_until(sub { $up{plain}->manifest_fetched_at && $up{explicit}->manifest_fetched_at }), 'both children started';

subtest 'a stdio child' => sub {
  my $env = parse_env($record{plain}->slurp);
  ok !exists $env->{MOJO_REUSE}, 'was exec\'d without MOJO_REUSE' or diag "MOJO_REUSE=$env->{MOJO_REUSE}";
  is $env->{MCP_HUB_TEST_INHERITED}, 'k58', 'and with the rest of the hub\'s environment';
};

subtest 'a stdio child whose entry sets MOJO_REUSE' => sub {
  my $env = parse_env($record{explicit}->slurp);
  is $env->{MOJO_REUSE}, 'set-by-the-entry', 'was exec\'d with the entry\'s value';
  is $env->{MCP_HUB_TEST_INHERITED}, 'k58', 'and with the rest of the hub\'s environment';
};

$_->stop for values %up;
ok wait_until(sub { !grep { $_->stats->{pid} } values %up }), 'the children stopped';

subtest 'a docker CLI run' => sub {
  my $docker = MCP::Hub::Docker->new(command => $^X);

  my $run = settle($docker->run_p(['-e', $PRINT_ENV], timeout => 30));
  is $run->{code}, 0, 'the command ran' or return diag explain $run;
  my $env = parse_env($run->{out});
  ok !exists $env->{MOJO_REUSE}, 'without MOJO_REUSE' or diag "MOJO_REUSE=$env->{MOJO_REUSE}";
  is $env->{MCP_HUB_TEST_INHERITED}, 'k58', 'and with the rest of the hub\'s environment';

  $run = settle($docker->run_p(['-e', $PRINT_ENV], env => {MOJO_REUSE => 'set-by-the-entry'}, timeout => 30));
  is $run->{code}, 0, 'the command ran with an env' or return diag explain $run;
  is parse_env($run->{out})->{MOJO_REUSE}, 'set-by-the-entry', 'which keeps the MOJO_REUSE it sets';
};

like $ENV{MOJO_REUSE}, qr/(?:^|,)127\.0\.0\.1:$port:\d+(?:,|$)/, 'the hub\'s own MOJO_REUSE is left as it was';

done_testing;
