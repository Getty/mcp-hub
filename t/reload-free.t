#!/usr/bin/env perl
# A reload that replaces or removes an upstream lets go of it: the upstream is
# freed -- of every type, with tools, prompts and resources, served on its own
# endpoint and through /all, and with a child or worker running. Each primitive
# of a facade reaches its upstream weakly (MCP::Hub::Facade); before, the cycle
# upstream -> facade -> primitive -> upstream kept every upstream with a single
# tool alive for the life of the daemon. A call in flight when the reload drops
# its upstream settles with an error result, and only then is the upstream freed.
# The instance of a class entry is freed with it: the natives' tools, and the
# test EchoServer's, reach their own server weakly.
use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File   qw(curfile tempdir);
use Mojo::IOLoop;
use Mojo::JSON   qw(encode_json);
use Mojo::Promise;
use Scalar::Util qw(weaken);
use Time::HiRes  qw(time);
use MCP::Client;
use MCP::Hub;
use MCP::Hub::Facade;
use MCP::Hub::Native::ClaudeHistory;
use MCP::Hub::Native::ClaudeSessions;
use MCP::Hub::Native::Status;
use MCP::Hub::Upstream;
use MCP::Server::Context;

use lib curfile->sibling('lib')->to_string;

my $ECHO = curfile->sibling('upstream', 'echo.pl')->to_string;

# What every cached manifest lists: a tool, a prompt and a resource -- each
# with the extras the facade must carry -- named as the echo server names them,
# so that a call started from it reaches a real child.
my $MANIFEST = {
  server_info  => {name => 'echo-server', version => '9.9.9'},
  instructions => 'Echo things back.',
  capabilities => {tools => {}, prompts => {}, resources => {}},
  tools        => [
    {name => 'echo', description => 'Echo', inputSchema => {type => 'object'},
      title => 'Echo it', _meta => {'anthropic/maxResultSizeChars' => 500}},
    {name => 'sleep', description => 'Sleep', inputSchema => {type => 'object'}},
  ],
  prompts   => [{name => 'greet', description => 'Greet', title => 'Greeting'}],
  resources => [{uri => 'echo://readme', name => 'readme', _meta => {k73 => 1}}],
};

# One entry of every type the hub builds. A $variant gives each a different
# entry, so that a reload to it replaces every one of them.
sub entries ($dir, $variant = '') {
  my $compose = $dir->child("compose$variant")->make_path;
  return {
    # Two spellings of the same command: the same program under another hash.
    stdio   => {command => $^X, args => [$variant ? ('-I', 'lib') : '-Ilib', $ECHO]},
    http    => {url => "http://127.0.0.1:9/mcp$variant"},
    sse     => {url => "http://127.0.0.1:9/sse$variant", type => 'sse'},
    docker  => {docker => "t/k73$variant"},
    compose => {compose => "$compose", service => 'mcp'},
    fork    => {class => 'EchoServer', args => {version => "1$variant"}, hub => {fork => \1}},
    perl    => {class => 'EchoServer', args => {version => "1$variant"}},
  };
}

sub write_config ($dir, $servers) {
  my $file = $dir->child('config.json');
  $file->spew(encode_json({
    mcpServers => $servers,
    # Nothing in here may ever start a real container.
    hub => {
      cache_dir      => $dir->child('cache')->to_string,
      docker_command => $dir->child('no-docker')->to_string,
    },
  }));
  return $file;
}

# A cached manifest for every upstream that keeps one, so the hub starts lazy:
# its facades list everything, and nothing is spawned or connected to. Each
# type hashes its own entry, so each upstream stores under its own hash.
sub warm ($dir, $servers) {
  my $app = MCP::Hub->new(hub_config_input => write_config($dir, $servers)->to_string);
  for my $up (grep { $_->{manifest} && $_->type ne 'fork' } @{$app->upstreams}) {
    $up->{manifest}->store({%$MANIFEST, name => $up->name, hash => $up->_hash, fetched_at => '2026-11-06T00:00:00Z'});
  }
  return;
}

sub hub_for ($dir, $servers, @warm) {
  warm($dir, $_) for @warm, $servers;
  my $app = MCP::Hub->new(hub_config_input => write_config($dir, $servers)->to_string);
  $app->log->level('fatal');
  return $app;
}

sub client ($t, $path) {
  my $base = $t->ua->server->url->to_string =~ s{/$}{}r;
  return MCP::Client->new(ua => $t->ua, url => "$base$path");
}

sub weak_refs ($app, @names) {
  my %weak;
  weaken($weak{$_} = $app->upstreams_by_name->{$_}) for @names;
  return \%weak;
}

# Which of them are still alive after the loop ran for at most $timeout
# seconds -- a child has to be gone before its upstream can be.
sub alive_after ($weak, $timeout = 5) {
  my $deadline = time + $timeout;
  while (1) {
    my @alive = sort grep { defined $weak->{$_} } keys %$weak;
    return \@alive if !@alive || time > $deadline;
    Mojo::Promise->timer(0.1)->wait;
  }
}

# Every endpoint is used before the reload -- its action built, its lists
# rendered -- so whatever serving leaves behind is part of what must go.
sub serve_all ($t, @names) {
  for my $name (@names) {
    my $client = client($t, "/$name");
    my %tools  = map { $_->{name} => $_ } @{$client->list_tools->{tools}};
    ok $tools{echo}, "$name lists its tools";
    next if $name eq 'perl' || $name eq 'fork';    # the class's own lists
    is $tools{echo}{title}, 'Echo it', "$name keeps the tool title";
    is $tools{echo}{_meta}{'anthropic/maxResultSizeChars'}, 500, "$name keeps the tool _meta";
    is $client->list_prompts->{prompts}[0]{title}, 'Greeting', "$name keeps the prompt title";
    is $client->list_resources->{resources}[0]{_meta}{k73}, 1, "$name keeps the resource _meta";
  }
  my %all = map { $_->{name} => $_ } @{client($t, '/all')->list_tools->{tools}};
  ok $all{"${_}__echo"}, "/all lists ${_}__echo" for @names;
  is $all{stdio__echo}{title}, 'Echo it', '/all keeps the tool title';
  return;
}

# ---------------------------------------------------------------------------

my @TYPES = qw(stdio http sse docker compose fork perl);

subtest 'a reload frees every upstream it removes' => sub {
  my $dir = tempdir;
  my $app = hub_for($dir, {%{entries($dir)}, keep => {class => 'EchoServer'}});
  my $t   = Test::Mojo->new($app);

  is $app->upstreams_by_name->{$_}->type, $_, "$_ is built as $_" for @TYPES;
  ok @{$app->upstreams_by_name->{$_}->server->tools}, "$_ has tools" for @TYPES;
  serve_all($t, @TYPES);

  my $weak    = weak_refs($app, @TYPES, 'keep');
  my $summary = write_config($dir, {keep => {class => 'EchoServer'}}) && $app->reload;
  is_deeply [sort @{$summary->{removed}}], [sort @TYPES], 'every one of them was removed';

  my $keep = delete $weak->{keep};
  is_deeply alive_after($weak), [], 'and every one of them is freed';
  ok $keep, 'the one still configured is kept';
  ok client($t, '/all')->list_tools, '/all still answers';
};

subtest 'a reload frees every upstream it replaces' => sub {
  my $dir = tempdir;
  my $app = hub_for($dir, entries($dir), entries($dir, 2));
  my $t   = Test::Mojo->new($app);
  serve_all($t, @TYPES);

  my $weak    = weak_refs($app, @TYPES);
  my $summary = write_config($dir, entries($dir, 2)) && $app->reload;
  is_deeply [sort @{$summary->{changed}}], [sort @TYPES], 'every one of them was replaced';
  is_deeply alive_after($weak), [], 'and every old one is freed';

  # The replacements are the ones served now, extras and all.
  serve_all($t, @TYPES);
  is $app->upstreams_by_name->{stdio}->stats->{pid}, undef, 'and still nothing was spawned';
};

subtest 'an upstream whose child is running is freed once the child is gone' => sub {
  my $dir = tempdir;
  my $app = hub_for($dir, {stdio => entries($dir)->{stdio}, fork => entries($dir)->{fork}});
  my $t   = Test::Mojo->new($app);

  is client($t, "/$_")->call_tool('echo', {msg => $_})->{content}[0]{text}, $_, "$_ answers" for qw(stdio fork);
  my %pid = map { $_ => $app->upstreams_by_name->{$_}->stats->{pid} } qw(stdio fork);
  ok $pid{stdio} && $pid{fork}, 'a child and a worker are running';

  my $weak = weak_refs($app, qw(stdio fork));
  write_config($dir, {});
  is_deeply [sort @{$app->reload->{removed}}], [qw(fork stdio)], 'both were removed';
  is_deeply alive_after($weak, 15), [], 'and both are freed once their processes are gone';
  ok !kill(0, $pid{$_}), "the $_ process is gone" for qw(stdio fork);
};

# A call under way holds its upstream until it settles. The reload stops the
# child, so the call does not wait for the tool or the request timeout: it ends
# at once, with an error result that names the upstream -- and the agent gets
# it as an ordinary tool result. Then the upstream is freed.
subtest 'a call in flight when a reload drops its upstream' => sub {
  for my $case (
    {path => '/echo', tool => 'sleep', how => 'removed'},
    {path => '/all',  tool => 'echo__sleep', how => 'replaced'},
  ) {
    my $dir     = tempdir;
    my $entry   = {%{entries($dir)->{stdio}}, hub => {request_timeout => 120}};
    my $changed = {%{entries($dir, 2)->{stdio}}, hub => {request_timeout => 120}};
    my $app     = hub_for($dir, {echo => $entry}, {echo => $changed});
    my $t       = Test::Mojo->new($app);

    is client($t, '/echo')->call_tool('echo', {msg => 'warm'})->{content}[0]{text}, 'warm', 'the child is running';
    my $weak = weak_refs($app, 'echo');

    my $summary;
    Mojo::IOLoop->timer(0.5 => sub {
      write_config($dir, $case->{how} eq 'removed' ? {} : {echo => $changed});
      $summary = $app->reload;
    });
    my $started = time;
    my $result  = client($t, $case->{path})->call_tool($case->{tool}, {seconds => 60});

    is_deeply $summary->{$case->{how} eq 'removed' ? 'removed' : 'changed'}, ['echo'],
      "$case->{path}: echo was $case->{how} while the call ran";
    ok $result->{isError}, "$case->{path}: the call settles with an error result";
    like $result->{content}[0]{text}, qr/^upstream echo: /, "$case->{path}: which names the upstream";
    cmp_ok time - $started, '<', 20, "$case->{path}: as soon as the child is gone, not when the tool would be done";
    is_deeply alive_after($weak, 15), [], "$case->{path}: and then the upstream is freed";

    if ($case->{how} eq 'replaced') {
      is client($t, '/all')->call_tool('echo__echo', {msg => 'new'})->{content}[0]{text}, 'new',
        '/all reaches the replacement';
    }
    $_->stop for @{$app->upstreams};
  }
};

# What a facade primitive answers when it outlived its upstream -- something
# held on to the facade alone. In the hub nothing does: a route looks its
# upstream up per request, and a reload rebuilds /all at once.
subtest 'a primitive whose upstream is gone answers with an error result' => sub {
  my $server = do {
    my $up = MCP::Hub::Upstream->new(name => 'ghost');
    MCP::Hub::Facade->build($up, $MANIFEST);
  };
  my $context = MCP::Server::Context->new;
  my $out;

  $server->tools->[0]->call({}, $context)->then(sub { $out = shift })->wait;
  ok $out->{isError}, 'a tool call is an error result';
  like $out->{content}[0]{text}, qr/^upstream ghost: gone/, 'naming the upstream';

  $server->prompts->[0]->call({}, $context)->then(sub { $out = shift })->wait;
  like $out->{messages}[0]{content}{text}, qr/^upstream ghost: gone/, 'a prompt says so too';

  $server->resources->[0]->call($context)->then(sub { $out = shift })->wait;
  is $out->{contents}[0]{uri}, 'echo://readme', 'a resource answers for its uri';
  like $out->{contents}[0]{text}, qr/^upstream ghost: gone/, 'and says so';

  my ($list) = $server->_handle_tools_list($context);
  is $list->{tools}[0]{title}, 'Echo it', 'the listing keeps its extras all the same';
};

# The instance of an in-process class entry goes with its upstream: the tools
# it registers on itself reach it weakly -- the natives' and EchoServer's do --,
# where a closure over it would be a cycle through its own server. Each of these
# classes is an MCP::Server, so its instance is the upstream's server. Their
# tools run through /all; served on its own endpoint, a server is also held by
# the transport its action builds, and that transport by it (MCP 0.15).
subtest 'a reload frees the instance of a class entry it removes' => sub {
  my $dir     = tempdir;
  my $claude  = $dir->child('claude')->make_path->to_string;
  my %classes = (
    echo     => {class => 'EchoServer'},
    history  => {class => 'MCP::Hub::Native::ClaudeHistory', args => {root => $claude}},
    sessions => {class => 'MCP::Hub::Native::ClaudeSessions',
      args => {root => $claude, proc_root => $dir->child('proc')->make_path->to_string}},
    status => {class => 'MCP::Hub::Native::Status'},
  );
  my $app = hub_for($dir, {%classes, keep => {class => 'EchoServer'}});
  my $t   = Test::Mojo->new($app);

  my $all = client($t, '/all');
  for my $tool (qw(history__list_projects sessions__list_running_sessions status__hub_status)) {
    ok !$all->call_tool($tool, {})->{isError}, "$tool answers";
  }
  is $all->call_tool('echo__echo', {msg => 'hi'})->{content}[0]{text}, 'hi', 'echo__echo answers';

  my $upstreams = weak_refs($app, keys %classes);
  my %instances;
  weaken($instances{$_} = $app->upstreams_by_name->{$_}->server) for keys %classes;
  write_config($dir, {keep => {class => 'EchoServer'}});
  is_deeply [sort @{$app->reload->{removed}}], [sort keys %classes], 'every one of them was removed';
  is_deeply alive_after($upstreams), [], 'their upstreams are freed';
  is_deeply alive_after(\%instances), [], 'and so are their instances';
};

# What a native's tool answers when it outlived its server -- something held on
# to the tool alone. In the hub nothing does, as for a facade primitive.
subtest 'a native tool whose server is gone answers with an error result' => sub {
  my $dir = tempdir;
  for my $native (
    ['MCP::Hub::Native::ClaudeHistory', root => "$dir"],
    ['MCP::Hub::Native::ClaudeSessions', root => "$dir", proc_root => "$dir"],
    ['MCP::Hub::Native::Status'],
  ) {
    my ($class, %args) = @$native;
    my ($name, @tools) = do { my $server = $class->new(%args); ($server->name, @{$server->tools}) };
    for my $tool (@tools) {
      my $out = $tool->call({}, MCP::Server::Context->new);
      ok $out->{isError}, "$name: " . $tool->name . ' is an error result';
      like $out->{content}[0]{text}, qr/^\Q$name\E: gone/, 'that says so';
    }
  }
};

done_testing;
