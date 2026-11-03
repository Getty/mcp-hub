#!/usr/bin/env perl
# Keeps the fixtures of the binary checks true against the Perl code:
# scripts/verify-binary.sh and scripts/smoke-binary.sh compare `mcp-hub config`
# with t/fixtures/binary/config.expected, and the smoke mounts t/upstream/echo.sh
# -- a stdio MCP server in POSIX sh, for hosts without Perl -- as the upstream it
# starts on tools/call.
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(curfile tempdir);
use Mojo::Log;
use Mojo::Promise;
use MCP::Hub;
use MCP::Hub::Upstream::Stdio;

my $FIXTURE = curfile->sibling('fixtures', 'binary');
my $ECHO    = curfile->sibling('upstream', 'echo.sh');
my $HOME    = tempdir;

# What `mcp-hub --config FILE config` prints, and what it logged on the way --
# the upstreams are built inside new(), so the log goes in with it.
sub config_output ($file) {
  local $ENV{MCP_HUB_CONFIG} = "$file";
  local $ENV{HOME}           = "$HOME";
  my @log;
  my $log = Mojo::Log->new;
  $log->unsubscribe('message')->on(message => sub ($l, $level, @lines) { push @log, "[$level] @lines" });
  my $app = MCP::Hub->new(cli => 1, log => $log);
  open my $fh, '>', \my $out or die $!;
  my $old = select $fh;
  my $ok  = eval { $app->start('config'); 1 };
  select $old;
  die $@ unless $ok;
  return ($out, \@log);
}

subtest 'config.json and config.yaml print config.expected' => sub {
  my $want = $FIXTURE->child('config.expected')->slurp;
  for my $name (qw(config.json config.yaml)) {
    my ($out, $log) = config_output($FIXTURE->child($name));
    is $out, $want, "$name prints config.expected";
    is_deeply [grep {/failed to build upstream/} @$log], [], "$name builds every upstream";
  }
};

# A request that is never settled must fail the test instead of hanging it.
sub _await ($promise, $seconds = 10) {
  my $out;
  Mojo::Promise->race(Mojo::Promise->timeout($seconds), $promise)
    ->then(sub { $out = shift })->catch(sub { $out = {err => shift} })->wait;
  return $out;
}

subtest 't/upstream/echo.sh is a stdio MCP server' => sub {
  plan skip_all => 'no sh on PATH' unless grep { -x "$_/sh" } split /:/, $ENV{PATH} // '';
  my $dir    = tempdir;
  my $marker = $dir->child('starts');
  my $up     = MCP::Hub::Upstream::Stdio->new(
    name      => 'echo',
    config    => {type => 'stdio', command => 'sh', args => ["$ECHO", "$marker"]},
    cache_dir => "$dir",
  );

  my $started = _await($up->start_p);
  ok !(ref $started eq 'HASH' && $started->{err}), 'handshake' or diag explain $started;
  is $up->state, 'ready', 'ready after the handshake';
  is_deeply [map { $_->name } @{$up->server->tools}], ['echo'], 'one tool: echo';
  like $marker->slurp, qr/\Astart \d+\n\z/, 'the marker records one start';

  my $r = _await($up->call_tool('echo', {msg => 'hi there'}));
  is $r->{content}[0]{text}, 'hi there', 'echo answers with msg';

  $up->stop;
  Mojo::Promise->timer(0.2)->wait;
  is $up->state, 'stopped', 'stopped';
};

done_testing;
