package MCP::Hub::Child;
our $VERSION = '0.001';
use Mojo::Base -strict, -signatures;

use Exporter qw(import);
use POSIX ();

# ABSTRACT: The file descriptors a child process inherits from the hub

our @EXPORT_OK = qw(close_inherited_fds inherited_fds);

# Where there is no /proc/self/fd to list, every fd below the soft limit is
# closed, one call each -- but never more than this many, since a soft limit
# can be in the millions or unlimited. fds are handed out lowest first, so the
# hub's own sit far below it.
use constant CLOSE_MAX => 65536;

sub inherited_fds () {
  opendir my $dh, '/proc/self/fd' or return undef;
  my @fds = grep { /^\d+$/ && $_ > 2 } readdir $dh;
  closedir $dh;

  # The directory's own fd is in the listing, and closed by now.
  return [grep { defined readlink "/proc/self/fd/$_" } @fds];
}

sub close_inherited_fds () {
  my $fds = inherited_fds() // [3 .. _open_max() - 1];
  POSIX::close($_) for @$fds;
  return;
}

sub _open_max () {
  my $max = POSIX::sysconf(POSIX::_SC_OPEN_MAX()) // 0;
  return $max > 0 && $max < CLOSE_MAX ? $max : CLOSE_MAX;
}

1;

=encoding utf8

=head1 SYNOPSIS

  use MCP::Hub::Child qw(close_inherited_fds);

  my $pid = fork // die "fork: $!\n";
  unless ($pid) {
    open(STDIN,  '<&', $child) or POSIX::_exit(127);
    open(STDOUT, '>&', $child) or POSIX::_exit(127);
    open(STDERR, '>&', $err_w) or POSIX::_exit(127);
    close_inherited_fds();
    { exec {$command} $command, @args }
    POSIX::_exit(127);
  }

=head1 DESCRIPTION

A child forked from the hub starts with every fd the hub holds at that moment.
Most of them are close-on-exec -- perl sets that flag on every fd above C<$^F>
it opens -- but not all: L<Mojo::IOLoop::Server> creates its listening socket
under C<local $^F = 1023>, so that a hot deployment can hand it on, and other
modules (a packed binary's archive handles, a log file) open fds of their own.
Whatever of that a child keeps, it keeps for as long as it lives -- a child
that outlives a crashed hub keeps its port bound.

So every child the hub execs -- a stdio upstream (L<MCP::Hub::Upstream::Stdio>),
a C<docker> or C<docker compose> run (L<MCP::Hub::Docker/run_p>) -- closes all
of them between C<fork> and C<exec>, once its stdin, stdout and stderr are in
place. A forked class worker (L<MCP::Hub::Upstream::Fork>) runs no exec and
lists them with L</inherited_fds> to neutralise them in place.

=head1 FUNCTIONS

Nothing is exported by default.

=func close_inherited_fds

  close_inherited_fds();

Closes every fd above C<2>. They are listed from F</proc/self/fd>; where that is
missing (anywhere but Linux), every fd from C<3> up to the C<_SC_OPEN_MAX> soft
limit is closed, capped at 65536. Call it in a child, once its stdin, stdout and
stderr are set up, right before the C<exec>.

=func inherited_fds

  my $fds = inherited_fds() // die "cannot read /proc/self/fd: $!\n";

An array reference with every fd above C<2> this process holds, from
F</proc/self/fd> -- or C<undef>, with C<$!> set, where that cannot be read.

=head1 SEE ALSO

L<MCP::Hub::Upstream::Stdio>, L<MCP::Hub::Docker>, L<MCP::Hub::Upstream::Fork>,
L<MCP::Hub/Process model>.

=cut
