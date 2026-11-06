#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;

plan skip_all => 'forked class workers need Linux (/proc/self/fd)' unless -d '/proc/self/fd';

use Test::Mojo;
use Mojo::File    qw(curfile tempdir);
use Mojo::IOLoop;
use Mojo::JSON    qw(encode_json decode_json);
use Mojo::Log;
use Mojo::Promise;
use MCP::Client;
use MCP::Hub;
use Scalar::Util qw(refaddr);
use Time::HiRes  qw(time);

use lib curfile->sibling('lib')->to_string;

# The lifecycle of a forked worker as a whole: queuing, the crash loop, stop,
# the loop staying free, shared file offsets and reload. What a single call and
# the isolation of the worker look like is t/fork.t's. They run the same under
# either reactor.

my @LOG;
sub log_to_array {
  my $log = Mojo::Log->new(level => 'debug');
  $log->unsubscribe('message')->on(message => sub ($l, $level, @lines) { push @LOG, "$level: @lines" });
  return $log;
}

sub hub ($servers, %extra) {
  my $cache = tempdir;
  return MCP::Hub->new(log => log_to_array(),
    hub_config_input => {mcpServers => $servers, hub => {cache_dir => "$cache"}}, %extra);
}

sub client ($t, $path) {
  my $base = $t->ua->server->url->to_string;
  $base =~ s{/$}{};
  return MCP::Client->new(ua => $t->ua, url => "$base$path");
}

sub forked ($class, %hub) { return {class => $class, hub => {fork => \1, %hub}} }

sub wait_until ($cond, $timeout = 5) {
  my $deadline = time + $timeout;
  Mojo::Promise->timer(0.02)->wait until $cond->() || time > $deadline;
  return $cond->();
}

# A tools/call that does not block the test: a promise for the result. The hub
# answers a call with a server-sent event, which MCP::Client would read the same way.
sub call_p ($t, $path, $tool, $args = {}) {
  state $id = 0;
  my $request = {jsonrpc => '2.0', id => ++$id, method => 'tools/call', params => {name => $tool, arguments => $args}};
  my $tx = $t->ua->build_tx(POST => $path => {Accept => 'application/json, text/event-stream'} => json => $request);
  my $result;
  $tx->res->content->on(sse => sub ($content, $event = undef) {
    return unless $event && $event->{text};
    my $res = Mojo::JSON::decode_json($event->{text});
    return unless defined $res->{id} && $res->{id} eq $request->{id};
    $result = $res->{result} // {error => $res->{error}};
    $tx->res->error({message => 'Interrupted'});
  });
  return $t->ua->start_p($tx)->then(
    sub ($tx) { $result // ($tx->res->json // {})->{result} },
    sub ($err) { $result // Mojo::Promise->reject($err) },
  );
}

sub text ($res) { return $res->{content}[0]{text} // '' }

# ---------------------------------------------------------------------------

my $app = hub({
  queue   => forked('ForkProbe'),
  crashy  => forked('ForkProbe'),
  stopper => forked('ForkProbe'),
  free    => forked('ForkProbe'),
  files   => forked('ForkProbe'),
  inproc  => {class => 'ForkProbe'},
});
my $t  = Test::Mojo->new($app);
my %up = %{$app->upstreams_by_name};

subtest 'concurrent calls queue on one worker' => sub {
  my $forks_before = grep {/forked a worker for ForkProbe/} @LOG;
  is $up{queue}->stats->{pid}, undef, 'no worker yet';

  # Staggered by a few milliseconds, so they reach the hub in this order -- all
  # while the first one is still forking the worker (the single fork below shows it).
  my @p;
  for my $n (1 .. 4) {
    push @p, call_p($t, '/queue', 'seq')->then(sub ($res) { return $res->{structuredContent} });
    Mojo::Promise->timer(0.01)->wait;
  }
  my $got;
  Mojo::Promise->all(@p)->then(sub (@r) { $got = [map { $_->[0] } @r] })->catch(sub { diag "@_" });
  wait_until(sub { $got }, 6);

  is scalar(@{$got // []}), 4, 'all four calls were answered';
  is scalar(keys %{{map { $_->{pid} => 1 } @{$got // []}}}), 1, 'by one worker';
  is $got->[0]{pid}, $up{queue}->stats->{pid}, 'the one the status shows';
  is_deeply [map { $_->{seq} } @{$got // []}], [1, 2, 3, 4], 'which took them in the order they came';
  is scalar(grep {/forked a worker for ForkProbe/} @LOG) - $forks_before, 1, 'and only one fork was made';
};

subtest 'a crash loop ends in failed, a refresh brings the worker back' => sub {
  my $up = $up{crashy};
  my $c  = client($t, '/crashy');

  for my $n (1 .. 3) {
    my $res = $c->call_tool('crash', {});
    ok $res->{isError}, "crash $n: the call fails";
    like text($res), qr/exited \(signal 9\)/, "crash $n: and says how the worker exited";
    ok wait_until(sub { $up->state ne 'ready' && $up->state ne 'starting' }), "crash $n: the upstream notices";
  }
  is $up->state, 'failed', 'three crashes are a crash loop';
  like $up->error, qr/3 exits within \d+s/, 'with the reason';
  is $up->stats->{pid}, undef, 'and no worker';

  $t->post_ok('/crashy', json => {jsonrpc => '2.0', id => 1, method => 'tools/list'})->status_is(503)
    ->json_like('/error', qr/upstream 'crashy' failed: 3 exits within \d+s/);

  ok scalar(grep { $_->{name} eq 'crashy__echo' } @{client($t, '/all')->list_tools->{tools}}),
    'its tools are still listed in /all';
  my $all = client($t, '/all')->call_tool('crashy__echo', {msg => 'x'});
  ok $all->{isError}, 'a call through /all fails';
  like text($all), qr/run 'mcp-hub refresh crashy' to try again/, 'saying how to get out';
  is $up->stats->{pid}, undef, 'without forking again';

  my $ok;
  $up->refresh_p->then(sub { $ok = 1 })->catch(sub ($err) { diag $err })->wait;
  ok $ok, 'refreshed';
  is $up->state, 'ready', 'ready again';
  is text($c->call_tool('echo', {msg => 'back'})), 'back', 'and answering';
};

subtest 'a stop gives a call in flight the grace, not the time it would take' => sub {
  # The worker reads its EOF only once the call is done: it is still busy when
  # the two seconds are over, and SIGTERM ends it.
  my $up = $up{stopper};
  my $p  = call_p($t, '/stopper', 'sleep', {seconds => 5});
  my ($result, $error);
  $p->then(sub { $result = shift }, sub { $error = shift });

  ok wait_until(sub { $up->state eq 'ready' && $up->stats->{pid} }), 'the worker runs the call';
  my $pid = $up->stats->{pid};
  Mojo::Promise->timer(0.2)->wait;    # the call has reached the worker

  my $start = time;
  $up->stop;
  ok wait_until(sub { !kill 0, $pid }, 10), 'the worker is gone';
  my $took = time - $start;
  cmp_ok $took, '>=', $up->EOF_GRACE - 0.1, sprintf 'once the grace was over (%.2fs)', $took;
  cmp_ok $took, '<', 4, 'not once the call was done';
  ok wait_until(sub { $up->state eq 'stopped' }), 'and the upstream is stopped';
  is $up->stats->{pid}, undef, 'with no pid';
  ok wait_until(sub { $result || $error }), 'the call in flight was answered, not left hanging';
};

subtest 'a call that ends within the grace is finished, and the worker not signalled' => sub {
  my $up = $up{stopper};
  my %status;
  no warnings 'redefine';
  my $on_exit = \&MCP::Hub::Upstream::Stdio::_on_exit;
  local *MCP::Hub::Upstream::Stdio::_on_exit = sub {
    my ($self, $status) = @_;
    $status{$self->{pid}} = $status if $self->{pid};
    goto &$on_exit;
  };
  my ($result, $error);
  call_p($t, '/stopper', 'sleep', {seconds => 0.5})->then(sub { $result = shift }, sub { $error = shift });
  ok wait_until(sub { $up->state eq 'ready' && $up->stats->{pid} }), 'the worker runs the call';
  my $pid = $up->stats->{pid};
  Mojo::Promise->timer(0.2)->wait;    # the call has reached the worker

  my $start = time;
  $up->stop;
  ok wait_until(sub { exists $status{$pid} }, 10), 'the worker is gone after the stop';
  my $took = time - $start;
  cmp_ok $took, '<', $up->EOF_GRACE, sprintf 'within the grace (%.2fs)', $took;
  is MCP::Hub::Upstream::Stdio::_exit_reason($status{$pid}), 'code 0', 'having exited on its own, not on a signal';
  ok wait_until(sub { $result || $error }), 'the call is answered';
  is text($result // {}), 'slept 0.5', 'by the worker, done with it' or diag explain $result // $error;
};

subtest 'a blocking tool in a worker does not stall the hub' => sub {
  my $gap = sub ($path) {
    my ($last, $max) = (time, 0);
    my $id = Mojo::IOLoop->recurring(0.05 => sub { my $now = time; $max = $now - $last if $now - $last > $max; $last = $now });
    my $done;
    call_p($t, $path, 'block', {seconds => 1})->then(sub { $done = shift })->catch(sub { diag "@_" });
    wait_until(sub { $done }, 6);
    Mojo::IOLoop->remove($id);
    return ($max, $done);
  };

  # The control: the same tool in process holds the hub's loop for its whole
  # duration, so what is measured below is the worker's doing.
  my ($stalled, $control) = $gap->('/inproc');
  is text($control), 'blocked 1', 'the in-process call returned';
  cmp_ok $stalled, '>', 0.8, sprintf 'in process the loop stalls (%.2fs between ticks)', $stalled;

  my ($lag, $res) = $gap->('/free');
  is text($res), 'blocked 1', 'the forked call returned';
  cmp_ok $lag, '<', 0.4, sprintf 'in a worker the hub keeps ticking (%.2fs between ticks)', $lag;
};

subtest 'a file the hub has open keeps its offset' => sub {
  my $dir  = tempdir;
  my $file = $dir->child("data.txt");
  $file->spew('0123456789abcdefghij');

  open my $fh, '<', "$file" or die $!;
  is sysread($fh, my $buf, 5), 5, 'the hub reads five bytes';
  my $fd = fileno $fh;
  is sysseek($fh, 0, 1) + 0, 5, 'and stands at 5';
  is $up{files}->stats->{pid}, undef, 'before the worker exists';

  my $c = client($t, '/files');
  my $r = $c->call_tool('readfd', {fd => $fd, bytes => 5})->{structuredContent};
  is $r->{text}, '56789', 'the worker has the file at the hub\'s offset';
  is $r->{pos}, 10, 'and reads on from there';
  is sysseek($fh, 0, 1) + 0, 5, 'the hub\'s own offset did not move';

  $r = $c->call_tool('readfd', {fd => $fd, bytes => 3})->{structuredContent};
  is $r->{text}, 'abc', 'the worker\'s offset is its own';
  is sysread($fh, $buf, 3), 3, 'the hub reads on';
  is $buf, '567', 'from where it stood';
};

subtest 'a reload keeps an unchanged worker, replaces a changed one, reaps a removed one' => sub {
  my $dir   = tempdir;
  my $file  = $dir->child('config.json');
  my $cache = $dir->child('cache');
  $file->spew(encode_json({
    mcpServers => {
      keep   => forked('ForkProbe'),
      change => {class => 'ForkProbe', args => {name => 'before'}, hub => {fork => \1}},
      drop   => forked('ForkProbe'),
    },
    hub => {cache_dir => "$cache"},
  }));

  my $rapp = MCP::Hub->new(log => log_to_array(), hub_config_input => "$file");
  my $rt   = Test::Mojo->new($rapp);
  my ($keep, $change, $drop) = map { $rapp->upstreams_by_name->{$_} } qw(keep change drop);

  my %pid;
  for my $name (qw(keep change drop)) {
    $pid{$name} = client($rt, "/$name")->call_tool('whoami', {})->{structuredContent}{pid};
    is $rapp->upstreams_by_name->{$name}->stats->{pid}, $pid{$name}, "$name has a worker";
  }
  my $keep_addr = refaddr $keep;

  # `change` gets other args, `drop` is removed, `keep` is left alone.
  $file->spew(encode_json({
    mcpServers => {
      keep   => forked('ForkProbe'),
      change => {class => 'ForkProbe', args => {name => 'after'}, hub => {fork => \1}},
    },
    hub => {cache_dir => "$cache"},
  }));
  my $summary = $rapp->reload;
  ok $summary->{ok}, 'the reload was applied' or diag encode_json($summary);
  is_deeply $summary->{changed},   ['change'], 'change is changed';
  is_deeply $summary->{removed},   ['drop'],   'drop is removed';
  is_deeply $summary->{unchanged}, ['keep'],   'keep is unchanged';

  is refaddr $rapp->upstreams_by_name->{keep}, $keep_addr, 'keep is the same object';
  is $keep->stats->{pid}, $pid{keep}, 'with the same worker';
  ok kill(0, $pid{keep}), 'which is still running';
  is client($rt, '/keep')->call_tool('whoami', {})->{structuredContent}{pid}, $pid{keep}, 'and still answers';

  ok wait_until(sub { !kill 0, $pid{change} }), 'the old worker of change is gone';
  my $new = $rapp->upstreams_by_name->{change};
  isnt refaddr $new, refaddr $change, 'change is a new upstream';
  is $new->stats->{pid}, undef, 'which has no worker until called';
  my $who = client($rt, '/change')->call_tool('whoami', {})->{structuredContent}{pid};
  ok $who && $who != $pid{change}, 'and then gets one of its own';
  is client($rt, '/change')->call_tool('whoami', {})->{structuredContent}{server}, 'after', 'built from the new args';

  ok wait_until(sub { !kill 0, $pid{drop} }), 'the worker of drop is gone';
  is $drop->stats->{pid}, undef, 'and drop has no pid';
  $rt->post_ok('/drop', json => {jsonrpc => '2.0', id => 1, method => 'tools/list'})->status_is(404);

  $rapp->shutdown_p->wait;
  ok wait_until(sub { !kill 0, $_ }), "worker $_ is gone after shutdown" for grep { kill 0, $_ } $pid{keep}, $who;
};

$app->shutdown_p->wait;
done_testing;
