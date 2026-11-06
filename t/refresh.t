#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File    qw(curfile tempdir);
use Mojo::Log;
use Mojo::Promise;
use MCP::Hub::Manifest;
use MCP::Hub::Upstream::Stdio;

# A refresh of a running stdio child asks it for its lists again, one after
# another: the tools, then the prompts and the resources. What it does when it
# is cut short between two of them -- and what it does when the child answers
# one of them with an error, which is an answer.

my $ECHO = curfile->sibling('upstream', 'echo.pl');

# A hook per method, run as the upstream is about to send a request for it --
# once, the next time it does: what a test does to the child, or to the
# request, at exactly that point. It is handed the upstream and a sender, and
# returns the request's promise.
my %ON;
{
  no warnings 'redefine';
  my $request_p = \&MCP::Hub::Upstream::Stdio::_request_p;
  *MCP::Hub::Upstream::Stdio::_request_p = sub ($self, $method, @rest) {
    my $on = delete $ON{$method} or return $request_p->($self, $method, @rest);
    return $on->($self, sub (@request) { $request_p->($self, @request) }, $method, @rest);
  };
}

# Every list a facade told its listeners about.
my @NOTIFIED;
{
  no warnings 'redefine';
  my $notify = \&MCP::Server::notify_list_changed;
  *MCP::Server::notify_list_changed = sub ($server, $kind) {
    push @NOTIFIED, $kind;
    return $notify->($server, $kind);
  };
}

sub log_to ($lines) {
  my $log = Mojo::Log->new;
  $log->unsubscribe('message');
  $log->on(message => sub ($l, $level, @msg) { push @$lines, "$level @msg" });
  return $log;
}

sub upstream (%attr) {
  my $dir = tempdir;
  return MCP::Hub::Upstream::Stdio->new(
    name            => 'echo',
    config          => {type => 'stdio', command => $^X, args => ['-Ilib', "$ECHO"]},
    cache_dir       => "$dir",
    request_timeout => 2,
    log             => log_to([]),
    %attr,
  );
}

# A promise settled, raced against a timeout: its value, or {err => ...}.
sub await_bounded ($promise, $seconds = 10) {
  my $out;
  Mojo::Promise->race(Mojo::Promise->timeout($seconds), $promise)
    ->then(sub { $out = shift // 1 })->catch(sub { $out = {err => shift} })->wait;
  return $out;
}

sub names ($list) { return [map { $_->name } @$list] }

# What the cache holds for the upstream now.
sub cached ($up) { return MCP::Hub::Manifest->new(cache_dir => $up->cache_dir)->load($up->name, $up->_hash) // {} }

subtest 'a refresh cut short keeps the manifest, an error answer is an empty list' => sub {
  # A prompts/list or resources/list that failed was taken for an empty list,
  # whatever the failure was. For a server that declares prompts and cannot
  # list them -- it answers with an error -- that is what it has. But a refresh
  # cut short there -- a stop between the tools and the prompts, a timeout --
  # stored a manifest with no prompts and no resources, and told the listeners
  # those lists had changed. It fails instead, and the manifest stays.
  my %how = (
    # The server's answer: an error, for a method it does not know.
    'the child answers with an error' => sub ($up, $send, $method, @rest) { $send->('prompts/nope', @rest) },
    'the child is stopped'            => sub ($up, $send, @request) { $up->stop; $send->(@request) },
    'the prompts/list times out'      => sub ($up, $send, @request) {
      my $timeout = $up->request_timeout;
      $up->request_timeout(0.2);    # the child takes 0.5 s over each list
      my $p = $send->(@request);
      $up->request_timeout($timeout);
      return $p;
    },
  );
  for my $how (sort keys %how) {
    my $answered = $how eq 'the child answers with an error';
    my $up       = upstream;
    is await_bounded($up->start_p), $up, "$how: started";
    is_deeply names($up->server->prompts), ['greet'], "$how: the prompts are listed";
    await_bounded($up->call_tool('slow_lists', {seconds => 0.5})) if $how =~ /times out/;

    # A tool the refresh is to find, and the hook for its prompts/list.
    await_bounded($up->call_tool('notify', {what => 'tools', quiet => \1}));
    @NOTIFIED = ();
    $ON{'prompts/list'}   = $how{$how};
    $ON{'resources/list'} = sub ($up, $send, @request) { $send->(@request) };
    my $refreshed = await_bounded($up->refresh_p);
    ok !exists $ON{'prompts/list'}, "$how: the refresh asked for the prompts";

    if ($answered) {
      is $refreshed, $up, "$how: the refresh is through" or diag explain $refreshed;
      is_deeply names($up->server->prompts), [], "$how: and the child has no prompts to list";
      ok +(grep { $_ eq 'echo2' } @{names($up->server->tools)}), "$how: the new tool is listed";
      ok !exists $ON{'resources/list'}, "$how: then for the resources";
      is_deeply [map { $_->uri } @{$up->server->resources}], ['echo://readme'], "$how: which are listed";
      is_deeply [sort @NOTIFIED], [qw(prompts tools)], "$how: the listeners hear of the tools and the prompts";
      is_deeply cached($up)->{prompts}, [], "$how: the cache has no prompts either";
    }
    else {
      ok ref $refreshed eq 'HASH' && $refreshed->{err}, "$how: the refresh fails" or diag explain $refreshed;
      ok exists $ON{'resources/list'}, "$how: without asking for the resources";
      is_deeply names($up->server->prompts), ['greet'], "$how: the prompts are still listed";
      ok !(grep { $_ eq 'echo2' } @{names($up->server->tools)}), "$how: the manifest is the one before";
      is_deeply [map { $_->uri } @{$up->server->resources}], ['echo://readme'], "$how: with its resources";
      is_deeply \@NOTIFIED, [], "$how: nobody is told anything changed";
      is_deeply [map { $_->{name} } @{cached($up)->{prompts} // []}], ['greet'], "$how: the cache keeps the prompts";
    }

    %ON = ();
    $up->stop;
    await_bounded($up->stopped_p);
  }
};

done_testing;
