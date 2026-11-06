#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File    qw(curfile tempdir);
use Mojo::Log;
use Mojo::IOLoop;
use Mojo::Promise;
use MCP::Hub::Upstream::Stdio;
use POSIX ();

my $ECHO = curfile->sibling('upstream', 'echo.pl');

# The crash-loop window for the subtests that count exits. Each cycle spawns
# perl, loads Mojolicious and runs the handshake; on a busy machine three of
# them do not fit into the default five seconds. These subtests are about the
# count, not about how fast the machine is.
my $WINDOW = 60;

sub upstream (%config) {
  my $dir = tempdir;
  return MCP::Hub::Upstream::Stdio->new(
    name      => 'echo',
    config    => {type => 'stdio', command => $^X, args => ['-Ilib', "$ECHO"], %config},
    cache_dir => "$dir",
  );
}

sub _await ($promise) {
  my $out;
  $promise->then(sub { $out = shift })->catch(sub { $out = {err => shift} })->wait;
  return $out;
}

# A request that is never settled must fail the test instead of hanging it: the
# promise is raced against a timeout.
sub _await_bounded ($promise, $seconds = 5) {
  my $out;
  Mojo::Promise->race(Mojo::Promise->timeout($seconds), $promise)
    ->then(sub { $out = shift })->catch(sub { $out = {err => shift} })->wait;
  return $out;
}

# The text of an error result -- or '' when the call did not answer at all.
sub _error_text ($result) {
  return '' unless ref $result eq 'HASH';
  return '' unless ref $result->{content} eq 'ARRAY';
  return '' unless ref $result->{content}[0] eq 'HASH';
  return $result->{content}[0]{text} // '';
}

sub settle ($seconds = 0.2) { Mojo::Promise->timer($seconds)->wait }

# A log that keeps its lines, "level message", instead of printing them.
sub log_to ($lines) {
  my $log = Mojo::Log->new;
  $log->unsubscribe('message');
  $log->on(message => sub ($l, $level, @msg) { push @$lines, "$level @msg" });
  return $log;
}

# An upstream around a perl one-liner instead of echo.pl.
sub oneliner ($name, $code, %attr) {
  return MCP::Hub::Upstream::Stdio->new(
    name      => $name,
    config    => {type => 'stdio', command => $^X, args => ['-e', $code]},
    cache_dir => tempdir->to_string,
    %attr,
  );
}

sub is_ev () { Mojo::IOLoop->singleton->reactor->isa('Mojo::Reactor::EV') }

# Whether this process catches SIGCHLD -- under EV, libev's handler, until
# something assigns $SIG{CHLD} and replaces it for good.
sub sigchld_caught () {
  open my $fh, '<', "/proc/$$/status" or return undef;
  while (<$fh>) { return (hex($1) >> (POSIX::SIGCHLD() - 1)) & 1 if /^SigCgt:\s+([0-9a-f]+)/ }
  return undef;
}

subtest 'handshake, manifest and echo' => sub {
  my $up = upstream;
  is $up->state, 'stopped', 'starts stopped';

  _await($up->start_p);
  is $up->state, 'ready', 'ready after handshake';
  ok $up->stats->{pid}, 'has a pid';

  my @tools = map { $_->name } @{$up->server->tools};
  is_deeply [sort @tools], [sort qw(echo sleep fail die exit notify)], 'all tools listed';

  my ($prompt) = @{$up->server->prompts};
  is $prompt->name, 'greet', 'prompt listed';
  my ($resource) = @{$up->server->resources};
  is $resource->uri, 'echo://readme', 'resource listed';

  my $r = _await($up->call_tool('echo', {msg => 'hi'}));
  is $r->{content}[0]{text}, 'hi', 'echo result forwarded';
  ok !${$r->{isError}}, 'not an error';

  my $pr = _await($up->get_prompt('greet', {who => 'world'}));
  like $pr->{messages}[0]{content}{text}, qr/Hello, world/, 'prompt forwarded';

  my $rr = _await($up->read_resource('echo://readme'));
  like $rr->{contents}[0]{text}, qr/echo server/, 'resource forwarded';

  $up->stop;
  settle;
  is $up->state, 'stopped', 'stopped after stop';
};

subtest 'lazy start from a cached manifest' => sub {
  my $dir = tempdir;
  my %args = (
    name      => 'echo',
    config    => {type => 'stdio', command => $^X, args => ['-Ilib', "$ECHO"]},
    cache_dir => "$dir",
  );

  # First instance fetches and caches, then stops.
  my $first = MCP::Hub::Upstream::Stdio->new(%args);
  _await($first->start_p);
  $first->stop;
  settle;

  # Second instance sees the same cache dir: tools are known, nothing spawned.
  my $second = MCP::Hub::Upstream::Stdio->new(%args);
  is $second->state, 'stopped', 'still stopped';
  is $second->stats->{pid}, undef, 'no process spawned';
  ok scalar(@{$second->server->tools}) >= 6, 'tools populated from cache';
};

subtest 'error results' => sub {
  my $up = upstream;

  my $fail = _await($up->call_tool('fail', {}));
  ok ${$fail->{isError}}, 'fail is an error result';
  is $fail->{content}[0]{text}, 'deliberate failure', 'error text passed through';

  my $die = _await($up->call_tool('die', {}));
  ok ${$die->{isError}}, 'die becomes an error result';
  like $die->{content}[0]{text}, qr/^upstream echo:/, 'error is attributed to the upstream';

  $up->stop;
  settle;
};

subtest 'a non-object error is reported, not swallowed' => sub {
  # An upstream that answers "error": "text" or "error": [..] -- shapes that
  # are out there in the wild. Reading ->{message} from them dies under strict
  # refs, and the request it belongs to then stays pending forever.
  for my $shape (qw(string array)) {
    my $up = upstream(args => ['-Ilib', "$ECHO", "--bad-error=$shape"]);
    my $r  = _await_bounded($up->call_tool('boom', {}), 5);
    ok $r->{isError}, "$shape error is an error result" or diag explain $r;
    like _error_text($r), qr/^upstream echo:/, "$shape error names the upstream";
    like _error_text($r), qr/nope/, "$shape error carries the upstream message";
    $up->stop;
    settle;
  }
};

subtest 'request timeout' => sub {
  my $up = upstream(request_timeout => 1);
  my $r  = _await($up->call_tool('sleep', {seconds => 5}));
  ok ${$r->{isError}}, 'timeout is an error result';
  like $r->{content}[0]{text}, qr/timed out after 1s/, 'timeout message';
  $up->stop;
  settle;
};

subtest 'crash mid-call and restart' => sub {
  my $up = upstream;
  my $r  = _await($up->call_tool('exit', {}));
  ok ${$r->{isError}}, 'crash is an error result';
  like $r->{content}[0]{text}, qr/exited \(code 0\)/, 'exit reason reported';
  is $up->state, 'stopped', 'stopped after crash';

  my $r2 = _await($up->call_tool('echo', {msg => 'again'}));
  is $r2->{content}[0]{text}, 'again', 'restarted on the next call';
  is $up->state, 'ready', 'ready again';
  $up->stop;
  settle;
};

subtest 'failed after three quick exits' => sub {
  my $up = upstream()->fail_window($WINDOW);
  _await($up->call_tool('exit', {})) for 1 .. 3;
  is $up->state, 'failed', 'three exits within the window mark it failed';
  is $up->error, "3 exits within ${WINDOW}s", 'the error names the count and the window';
  $up->stop;
  settle;
};

subtest 'exits older than the window are forgotten' => sub {
  # The other side of the window, and safe under load: a busy machine only
  # makes the pause longer. Two exits, a pause past the one-second window, a
  # third exit -- only the third one is still inside, so this is no crash loop.
  my $up = upstream()->fail_window(1);
  _await($up->call_tool('exit', {})) for 1 .. 2;
  settle(2.1);
  _await($up->call_tool('exit', {}));
  is $up->state, 'stopped', 'stopped, not failed';
  is $up->error, undef, 'and no crash loop reported';
  $up->stop;
  settle;
};

subtest 'a child that dies at startup is counted once' => sub {
  # The child exits during the handshake: _on_close records the exit, and the
  # catch in start_p must not record it a second time. Counted twice, two
  # attempts would lock the upstream out -- and the stale stopping flag would
  # swallow the warning of the next exit.
  my @lines;
  my $log = Mojo::Log->new;
  $log->unsubscribe('message');
  $log->on(message => sub ($l, $level, @msg) { push @lines, "$level @msg" });

  my $up = MCP::Hub::Upstream::Stdio->new(
    name        => 'false',
    config      => {type => 'stdio', command => $^X, args => ['-e', 'exit 0']},
    cache_dir   => tempdir->to_string,
    fail_window => $WINDOW,
  );
  $up->log($log);

  for my $n (1 .. 2) {
    my $r = _await($up->start_p);
    ok $r->{err}, "attempt $n fails" or diag explain $r;
    is $up->state, 'stopped', "stopped after attempt $n -- one exit counted, not two";
    ok +(grep { /child exited/ } @lines), "attempt $n logs the exit" or diag explain \@lines;
    @lines = ();
  }

  my $r = _await($up->start_p);
  ok $r->{err}, 'the third attempt fails';
  is $up->state, 'failed', 'failed after the third attempt';

  $up->stop;
  settle;
};

# These come before anything here assigns $SIG{CHLD}: the first one is about
# libev reaping children, and an assignment ends that for the whole process.
subtest 'the exit status is read under EV too' => sub {
  # The child exits at once; a child of its own holds the socket a second
  # longer. Under Mojo::Reactor::EV libev reaps the child as soon as SIGCHLD
  # is in, long before the socket closes, and a waitpid at the close came up
  # empty: this read "exited (unknown)" every time. Under Poll it is the
  # ordinary case.
  ok sigchld_caught(), 'libev reaps the children of this process' if is_ev() && -r "/proc/$$/status";
  my @lines;
  my $up = oneliner(forks => 'exit 5 if fork; sleep 1', log => log_to(\@lines));
  my $r  = _await_bounded($up->start_p, 30);
  is $r->{err}, 'upstream forks: exited (code 5)', 'the start fails with the code the child exited with';
  ok +(grep { $_ eq "warn [forks] child exited (code 5) while starting '$^X'" } @lines), 'and the log says it too'
    or diag explain \@lines;
  is $up->state, 'stopped', 'stopped';
};

subtest 'a child that closes its stdout and lives on does not block the loop' => sub {
  # Its socket closes two seconds before it exits. A blocking waitpid at the
  # close held the whole hub -- every other upstream, every request -- until
  # then.
  my $up    = oneliner(linger => 'close STDIN; close STDOUT; sleep 2; exit 4', log => log_to([]));
  my $start = $up->start_p;
  my $pid   = $up->stats->{pid};
  my $ticks = 0;
  my $tick  = Mojo::IOLoop->recurring(0.1 => sub { $ticks++ if kill 0, $pid });
  my $r     = _await_bounded($start, 30);
  Mojo::IOLoop->remove($tick);
  ok $ticks >= 5, "the loop ran on while the child lived ($ticks ticks)";
  is $r->{err}, 'upstream linger: exited (code 4)', 'its exit is reported once it comes';
  ok !kill(0, $pid), 'and it is reaped';
  is $up->state, 'stopped', 'stopped';
};

subtest 'a child that closes its stdout and does not exit is killed' => sub {
  # It can never answer again. It gets the grace a stop gives, then it goes.
  my @lines;
  my $up  = oneliner(stuck => 'close STDIN; close STDOUT; sleep 60', log => log_to(\@lines));
  my $r   = _await_bounded($up->start_p, 30);
  is $r->{err}, 'upstream stuck: exited (signal 9)', 'killed';
  ok +(grep { /^warn \[stuck\] closed its stdout 5s ago and still runs, killing it$/ } @lines), 'saying why'
    or diag explain \@lines;
  is $up->state, 'stopped', 'stopped';
};

subtest 'a stop ends even while a process the child started holds its socket' => sub {
  # The child exits at once; one process it leaves behind serves (echo.pl),
  # another only sits on the socket. A stop ends the server, but the socket
  # never closes -- so once the grace is over the hub lets go of it, instead
  # of waiting with the upstream stuck on its way out.
  my $up = MCP::Hub::Upstream::Stdio->new(
    name      => 'holder',
    config    => {type => 'stdio', command => $^X,
      args => ['-e', 'exit 0 if fork; if (fork) { exec $^X, "-Ilib", $ARGV[0] } sleep 20', "$ECHO"]},
    cache_dir => tempdir->to_string,
    log       => log_to([]),
  );
  _await_bounded($up->start_p, 30);
  is $up->state, 'ready', 'the server answers';
  $up->stop;
  my $deadline = time + 15;
  settle(0.1) while $up->stats->{pid} && time < $deadline;
  is $up->stats->{pid}, undef, 'the stop ends';
  is $up->state, 'stopped', 'stopped';
};

subtest 'a call while the child is stopped starts the next one' => sub {
  # A call that comes in while an idle stop is under way must not go to the
  # child that is on its way out.
  my $up = upstream;
  _await($up->start_p);
  my $old = $up->stats->{pid};
  $up->stop;
  my $r = _await_bounded($up->call_tool('echo', {msg => 'after the stop'}), 30);
  is _error_text($r), 'after the stop', 'the call is answered' or diag explain $r;
  ok $up->stats->{pid} && $up->stats->{pid} != $old, 'by a new child';
  ok !kill(0, $old), 'the stopped one is gone';
  $up->stop;
  settle;
};

subtest 'a command that cannot be executed is logged loudly' => sub {
  my $dir = tempdir;
  my $up  = MCP::Hub::Upstream::Stdio->new(
    name      => 'missing',
    config    => {type => 'stdio', command => "$dir/definitely-not-a-binary"},
    cache_dir => "$dir",
  );

  my @lines;
  my $log = Mojo::Log->new;
  $log->unsubscribe('message');
  $log->on(message => sub ($l, $level, @msg) { push @lines, "$level @msg" });
  $up->log($log);

  my $out = _await($up->start_p);
  is $out->{err}, 'upstream missing: exited (code 127)', 'start rejects with the exit';
  ok +(grep { $_ eq "warn [missing] child exited (code 127) while starting '$dir/definitely-not-a-binary' -- is it installed and executable?" } @lines),
    'the missing command is named at warn level'
    or diag explain \@lines;

  # Where SIGCHLD is ignored the kernel reaps the child itself, waitpid fails
  # with ECHILD and $? is -1 -- which must not be reported as "signal 127".
  {
    local $SIG{CHLD} = 'IGNORE';
    @lines = ();
    my $ignored = MCP::Hub::Upstream::Stdio->new(
      name      => 'missing',
      config    => {type => 'stdio', command => "$dir/definitely-not-a-binary"},
      cache_dir => "$dir",
    );
    $ignored->log($log);
    _await($ignored->start_p);
    ok +(grep { /^(?:warn|error) / && /definitely-not-a-binary/ } @lines),
      'the command is named even when the child is reaped for us';
    ok !(grep { /signal 127/ } @lines), 'and no signal number is invented'
      or diag explain \@lines;
  }
};

subtest 'failed is left only by an explicit refresh' => sub {
  my $up = upstream()->fail_window($WINDOW);
  _await($up->call_tool('exit', {})) for 1 .. 3;
  is $up->state, 'failed', 'failed after three quick exits';

  # An ordinary call must not silently respawn a failed upstream.
  my $blocked = _await($up->call_tool('echo', {msg => 'hi'}));
  ok ${$blocked->{isError}}, 'a call against a failed upstream is an error result';
  like $blocked->{content}[0]{text}, qr/refresh/, 'the error says how to retry';
  is $up->stats->{pid}, undef, 'and nothing was spawned';
  is $up->state, 'failed', 'still failed';

  # An explicit refresh is the admin's "try again".
  _await($up->refresh_p);
  is $up->state, 'ready', 'refresh revives it';
  is _await($up->call_tool('echo', {msg => 'back'}))->{content}[0]{text}, 'back', 'calls work again';

  $up->stop;
  settle;
  is $up->state, 'stopped', 'a later stop leaves it stopped, not failed';
};

subtest 'list_changed triggers a refresh' => sub {
  my $up = upstream;
  _await($up->start_p);
  ok !(grep { $_->name eq 'echo2' } @{$up->server->tools}), 'echo2 absent before notify';

  _await($up->call_tool('notify', {}));
  _await($up->refresh_p);
  ok +(grep { $_->name eq 'echo2' } @{$up->server->tools}), 'echo2 present after refresh';
  $up->stop;
  settle;
};

subtest 'idle timeout stops the child' => sub {
  my $up = upstream(idle_timeout => 1);
  _await($up->start_p);
  is $up->state, 'ready', 'ready';
  ok $up->stats->{pid}, 'has a pid';

  settle(1.6);
  is $up->state, 'stopped', 'stopped after idle timeout';
  is $up->stats->{pid}, undef, 'child reaped';
};

done_testing;
