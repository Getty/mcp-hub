#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;

plan skip_all => 'forked class workers need Linux (/proc/self/fd)' unless -d '/proc/self/fd';

use Test::Mojo;
use Mojo::File qw(curfile tempdir);
use Mojo::JSON qw(encode_json true);
use Mojo::Log;
use MCP::Client;
use MCP::Hub;

# ClaudeHistory with "hub": {"fork": true} runs each call in a worker forked
# from the hub (MCP::Hub::Upstream::Fork) instead of in the hub's loop, which a
# long history would stall. It must give the same answers: this mounts the same
# class twice over the same files, in-process and forked, and compares what the
# two endpoints list and answer. The fixtures of t/fixtures/claude are copied
# and given a subagent run and a prompt history, so that every tool has
# something to say; the copy keeps the fixtures in the checkout, which other
# tests list, as they are.
my $fixtures = curfile->sibling('..', 'fixtures', 'claude');
my $root     = tempdir;
for my $file (@{$fixtures->list_tree}) {
  my $to = $root->child(@{$file->to_rel($fixtures)->to_array});
  $to->dirname->make_path;
  $file->copy_to($to);
}

sub run_line ($uuid, $timestamp, %f) {
  return encode_json({sessionId => 'a1', agentId => 'aexplore1', isSidechain => true, uuid => $uuid,
    timestamp => $timestamp, cwd => '/home/tester/proj-a', gitBranch => 'main', %f});
}
my $run = $root->child('projects', '-home-tester-proj-a', 'a1', 'subagents')->make_path;
$run->child('agent-aexplore1.jsonl')->spew(join '', map {"$_\n"}
  run_line('e1', '2026-08-10T10:00:02Z', type => 'user', message => {role => 'user', content => 'Find the kubernetes pod specs'}),
  run_line('e2', '2026-08-10T10:00:03Z', type => 'assistant',
    message => {role => 'assistant', content => [{type => 'text', text => 'The kubernetes specs are in deploy/'}]}));
$run->child('agent-aexplore1.meta.json')
  ->spew(encode_json({agentType => 'Explore', description => 'Find pod specs', spawnDepth => 1}));

sub prompt ($text, $project, $session_id, $ms) {
  return encode_json({display => $text, pastedContents => {}, project => $project, sessionId => $session_id,
    timestamp => $ms});
}
$root->child('history.jsonl')->spew(join '', map {"$_\n"}
  prompt('Hello, a question about Kubernetes pods', '/home/tester/proj-a', 'a1', 1786356000000),
  prompt('A deployment question',                   '/home/tester/proj-b', 'b1', 1786456800250),
  prompt('fix the kubernetes paste',                '/home/tester/gone',   'gone-1', 1786579199999));

my $log = Mojo::Log->new(level => 'fatal');
my $cache = tempdir;
my $app   = MCP::Hub->new(
  log              => $log,
  hub_config_input => {
    mcpServers => {
      inproc => {class => 'MCP::Hub::Native::ClaudeHistory', args => {root => "$root"}},
      forked => {class => 'MCP::Hub::Native::ClaudeHistory', args => {root => "$root"}, hub => {fork => \1}},
    },
    hub => {cache_dir => "$cache"},
  },
);
my $t  = Test::Mojo->new($app);
my %up = %{$app->upstreams_by_name};

sub client ($path) {
  my $base = $t->ua->server->url->to_string;
  $base =~ s{/$}{};
  return MCP::Client->new(ua => $t->ua, url => "$base$path");
}
my ($in, $fork) = (client('/inproc'), client('/forked'));

is $up{forked}->type, 'fork', 'the one entry is a fork upstream';
isnt $up{inproc}->type, 'fork', 'the other is not';

subtest 'the same tools' => sub {
  my @names = qw(get_conversation list_projects list_prompts list_sessions list_subagents search_conversations);
  my $by    = sub ($c) { [sort { $a->{name} cmp $b->{name} } @{$c->list_tools->{tools}}] };
  my ($i, $f) = ($by->($in), $by->($fork));
  is_deeply [map { $_->{name} } @$i], \@names, 'in-process lists the six tools';
  is_deeply $f, $i, 'forked lists exactly the same, schemas and descriptions included';
  is $up{forked}->stats->{pid}, undef, 'and listing forked no worker';
};

# What each call is given, as [tool, arguments]; every one is made on both
# endpoints and must come back the same. The checks say what the fixtures hold,
# so that a comparison of two empty answers cannot pass for one of full ones.
my @calls = (
  ['list_projects',        {},                                                        qr/proj-a.*proj-b/s],
  ['list_sessions',        {},                                                        qr/"a2".*"b1".*"a1"/s],
  ['list_sessions',        {project => '/home/tester/proj-a'},                        qr/"a2".*"a1"/s],
  ['list_sessions',        {since => '2026-08-11', limit => 1},                       qr/"a2"/],
  ['search_conversations', {query => 'kubernetes'},                                   qr/"a1".*"b1"|"b1".*"a1"/s],
  ['search_conversations', {query => 'help', roles => ['assistant']},                 qr/"a1"/],
  ['search_conversations', {query => 'kubernetes', include_subagents => true},        qr/aexplore1/],
  ['get_conversation',     {session_id => 'a1'},                                      qr/tool_use Bash/],
  ['get_conversation',     {session_id => 'a1', offset => 1, limit => 1},             qr/assistant/],
  ['get_conversation',     {session_id => 'b1'},                                      qr/kubernetes/i],
  ['get_conversation',     {session_id => 'nope'},                                    qr/"total":\s*0/],
  ['get_conversation',     {session_id => 'a1', agent_id => 'aexplore1'},             qr/specs are in deploy/],
  ['get_conversation',     {session_id => 'a1', agent_id => 'nobody'},                qr/no subagent run nobody/, 1],
  ['list_subagents',       {session_id => 'a1'},                                      qr/aexplore1.*Explore/s],
  ['list_subagents',       {session_id => 'a2'},                                      qr/\[\s*\]/],
  ['list_prompts',         {},                                                        qr/deployment question.*Hello/s],
  ['list_prompts',         {query => 'kubernetes', project => '/home/tester/gone'},   qr/paste/],
  ['list_prompts',         {since => '2026-08-12'},                                   qr/paste/],
);

for my $call (@calls) {
  my ($tool, $args, $shape, $is_error) = @$call;
  my $what = "$tool " . encode_json($args);
  my $i    = $in->call_tool($tool, $args);
  my $f    = $fork->call_tool($tool, $args);
  my $text = $i->{content}[0]{text} // '';
  like $text, $shape, "$what: in-process says what the fixtures hold";
  is !!$i->{isError}, !!$is_error, "$what: and is " . ($is_error ? 'an error' : 'no error');
  is_deeply $f, $i, "$what: forked answers the same";
}

subtest 'the forked calls ran in a worker, the others in the hub' => sub {
  my $pid = $up{forked}->stats->{pid};
  ok $pid,        'the forked entry has a worker';
  isnt $pid, $$,  'a process of its own';
  is $up{inproc}->stats->{pid}, undef, 'the in-process entry has none';
};

done_testing;
