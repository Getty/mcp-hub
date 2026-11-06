#!/usr/bin/env perl
# A child the hub execs holds stdin, stdout and stderr -- nothing else of the
# hub's. Mojo creates the listening socket under `local $^F = 1023`, so that fd
# has no close-on-exec, and before k52 every stdio upstream and every docker CLI
# run inherited it: a child that outlived a crashed hub kept its port bound.
# The listener here is the one Test::Mojo starts, a Mojo::Server::Daemon like
# `mcp-hub daemon`.
use Mojo::Base -strict, -signatures;
use Test::More;

plan skip_all => "reads a child's fds from /proc/PID/fd, which only Linux has" unless -d '/proc/self/fd';

use Test::Mojo;
use Mojo::File    qw(curfile tempdir);
use Mojo::Promise;
use MCP::Client;
use MCP::Hub;
use MCP::Hub::Child;
use MCP::Hub::Docker;
use POSIX ();

my $ECHO = curfile->sibling('upstream', 'echo.pl');
my $LIB  = curfile->dirname->sibling('lib');

# Run as `perl -e $SNAPSHOT FILE COMMAND...`: writes the fd table it was exec'd
# with to FILE -- one "fd target" line each, before it opens anything of its
# own -- then execs COMMAND, so the upstream behind it is echo.pl as usual.
my $SNAPSHOT = <<'PERL';
my $out = shift;
my $fds = do {
  opendir my $dh, '/proc/self/fd' or die "/proc/self/fd: $!";
  my @fds = grep { /^\d+$/ } readdir $dh;
  closedir $dh;
  join '', map { my $l = readlink "/proc/self/fd/$_"; defined $l ? "$_ $l\n" : '' } sort { $a <=> $b } @fds;
};
open my $fh, '>', $out or die "$out: $!";
print $fh $fds;
close $fh;
exec @ARGV or die "exec @ARGV: $!";
PERL

# The same table, printed to stdout: what a docker CLI run sees.
my $PRINT_FDS = $SNAPSHOT =~ s/^my \$out = shift;\n//r =~ s/open my.*\z/print \$fds;\n/sr;

sub fds ($pid) {
  opendir my $dh, "/proc/$pid/fd" or return {};
  my %links = map { my $l = readlink "/proc/$pid/fd/$_"; defined $l ? ($_ => $l) : () } grep {/^\d+$/} readdir $dh;
  return \%links;
}

sub table ($text) { return {map { split / /, $_, 2 } split /\n/, $text} }

# The inode of the socket listening on $port, from the kernel's own table.
sub listen_inode ($port) {
  my $hex = sprintf '%04X', $port;
  for my $file ('/proc/net/tcp', '/proc/net/tcp6') {
    open my $fh, '<', $file or next;
    while (<$fh>) {
      my @f = split ' ';
      return $f[9] if ($f[1] // '') =~ /:$hex$/ && ($f[3] // '') eq '0A';
    }
  }
  return undef;
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

my $tmp      = tempdir;
my $snapshot = $tmp->child('fds');
my $app      = MCP::Hub->new(hub_config_input => {
  mcpServers => {echo => {command => $^X, args => ['-e', $SNAPSHOT, "$snapshot", $^X, "-I$LIB", "$ECHO"]}},
  hub        => {cache_dir => $tmp->child('cache')->to_string},
});
$app->log->level('fatal');
my $t = Test::Mojo->new($app);

my $port  = $t->ua->server->url->port;    # the hub listens from here on
my $inode = listen_inode($port);
ok $inode, "found the socket the hub listens on (port $port)";
ok((grep { $_ eq "socket:[$inode]" } values %{fds($$)}), 'the hub holds it');

subtest 'a stdio child started by tools/call' => sub {
  my ($up) = @{$app->upstreams};
  $app->start_background_fetches;
  ok wait_until(sub { $up->manifest_fetched_at }), 'the manifest is fetched';
  $up->stop;
  ok wait_until(sub { $up->state eq 'stopped' && !$up->stats->{pid} }), 'and the warming child stopped';
  $snapshot->remove;

  my $base = $t->ua->server->url->to_string =~ s{/$}{}r;
  my $res  = MCP::Client->new(ua => $t->ua, url => "$base/echo")->call_tool('echo', {msg => 'k52'});
  is $res->{content}[0]{text}, 'k52', 'the call is answered by a child it started';
  my $pid = $up->stats->{pid} or return fail 'no child';

  my $at_exec = table($snapshot->slurp);
  is_deeply [sort { $a <=> $b } keys %$at_exec], [0, 1, 2], 'the child was exec\'d with fds 0, 1 and 2 only'
    or diag explain $at_exec;
  like $at_exec->{0}, qr/^socket:/, 'stdin is the hub\'s socket';
  is $at_exec->{1}, $at_exec->{0}, 'stdout the same socket';
  like $at_exec->{2}, qr/^pipe:/, 'stderr a pipe';

  # The running child: its own fds -- a module's DATA handle, its event loop --
  # are its business, the hub's listening socket is not.
  my $running = fds($pid);
  ok !(grep { $_ eq "socket:[$inode]" } values %$running), 'the running child does not hold the listening socket'
    or diag explain $running;

  $up->stop;
  ok wait_until(sub { !kill 0, $pid }), 'the child is gone after stop';
};

subtest 'a docker CLI run' => sub {
  my $run = settle(MCP::Hub::Docker->new(command => $^X)->run_p(['-e', $PRINT_FDS], timeout => 30));
  is $run->{code}, 0, 'the command ran' or return diag explain $run;
  my $fds = table($run->{out});
  is_deeply [sort { $a <=> $b } keys %$fds], [0, 1, 2], 'with fds 0, 1 and 2 only' or diag explain $fds;
  is $fds->{0}, '/dev/null', 'stdin is /dev/null';
  like $fds->{$_}, qr/^pipe:/, "fd $_ a pipe" for 1, 2;
};

# Off Linux there is no /proc/self/fd to list, and every fd up to the soft
# limit is closed instead. That path runs here too, with the listing made to
# fail -- the hub's listening socket is still open in this process.
subtest 'where /proc/self/fd cannot be listed' => sub {
  pipe(my $r, my $w) or die "pipe: $!";
  my $pid = fork // die "fork: $!";
  unless ($pid) {
    close $r;
    open(STDOUT, '>&', $w) or POSIX::_exit(127);
    no warnings 'redefine';
    *MCP::Hub::Child::inherited_fds = sub () { return undef };
    MCP::Hub::Child::close_inherited_fds();
    { exec $^X, '-e', $PRINT_FDS }
    POSIX::_exit(127);
  }
  close $w;
  my $out = do { local $/; <$r> };
  waitpid $pid, 0;
  is $?, 0, 'the command ran';
  my $fds = table($out);
  is_deeply [sort { $a <=> $b } keys %$fds], [0, 1, 2], 'with fds 0, 1 and 2 only' or diag explain $fds;
};

done_testing;
