use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File    qw(curfile tempdir);
use Mojo::Promise;
use MCP::Hub::Upstream::Stdio;

my $ECHO = curfile->sibling('upstream', 'echo.pl');

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

sub settle ($seconds = 0.2) { Mojo::Promise->timer($seconds)->wait }

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
  my $up = upstream;
  _await($up->call_tool('exit', {})) for 1 .. 3;
  is $up->state, 'failed', 'three exits within the window mark it failed';
  $up->stop;
  settle;
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
