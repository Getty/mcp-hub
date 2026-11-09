#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(curfile tempdir);
use Mojo::JSON qw(decode_json encode_json false true);
use MCP::Hub::Native::ClaudeHistory;

# Claude Code keeps the subagent runs of a session beside its file, in
# <session>/subagents/agent-<id>.jsonl, each with an agent-<id>.meta.json next
# to it; every line of a run carries the parent's sessionId. The runs are
# written here into a copy of the fixtures, so the fixtures in the checkout,
# which other tests list, stay as they are.
my $fixtures = curfile->sibling('..', 'fixtures', 'claude');
my $root     = tempdir;
for my $file (@{$fixtures->list_tree}) {
  my $to = $root->child(@{$file->to_rel($fixtures)->to_array});
  $to->dirname->make_path;
  $file->copy_to($to);
}

sub line ($session_id, $agent_id, $uuid, $timestamp, %f) {
  return encode_json({sessionId => $session_id, agentId => $agent_id, isSidechain => true, uuid => $uuid,
    timestamp => $timestamp, cwd => '/home/tester/run', gitBranch => 'run-branch', %f});
}
sub user ($text)        { (type => 'user',      message => {role => 'user',      content => $text}) }
sub assistant (@blocks) { (type => 'assistant', message => {role => 'assistant', content => [@blocks]}) }
sub text ($text)        { +{type => 'text', text => $text} }

# a1 has two runs: aexplore1 has its meta file and began second, bworker2
# has its meta file, began first and holds a line that is no JSON. b1, whose
# file is sess-b1.jsonl, has one run without a meta file. a2 has a subagents
# dir holding no run: a workflow journal and a meta file without its run.
my $a1 = $root->child('projects', '-home-tester-proj-a', 'a1', 'subagents')->make_path;
my $explore = $a1->child('agent-aexplore1.jsonl');
$explore->spew(join '', map {"$_\n"}
  line('a1', 'aexplore1', 'e1', '2026-08-10T10:00:02Z', user('Find the kubernetes pod specs')),
  line('a1', 'aexplore1', 'e2', '2026-08-10T10:00:03Z',
    assistant(text('Found the deployment'), {type => 'tool_use', id => 't1', name => 'Grep', input => {}})),
  encode_json({type => 'attachment', sessionId => 'a1', agentId => 'aexplore1', timestamp => '2026-08-10T10:00:04Z'}),
  line('a1', 'aexplore1', 'e3', '2026-08-10T10:00:05Z', assistant(text('The kubernetes specs are in deploy/'))));
$a1->child('agent-aexplore1.meta.json')
  ->spew(encode_json({agentType => 'Explore', description => 'Find pod specs', spawnDepth => 1, toolUseId => 'toolu_1'}));
$a1->child('agent-bworker2.jsonl')->spew(join '', map {"$_\n"}
  line('a1', 'bworker2', 'w1', '2026-08-10T10:00:01Z', user('Fix the widget')),
  '{"type":"user","sessionId":"a1", not json kubernetes',
  line('a1', 'bworker2', 'w2', '2026-08-10T10:00:06Z', assistant(text('Fixed it, kubernetes untouched'))));
$a1->child('agent-bworker2.meta.json')
  ->spew(encode_json({agentType => 'mcp-hub-worker', description => 'Fix the widget', spawnDepth => 1}));

my $b1 = $root->child('projects', '-home-tester-proj-b', 'sess-b1', 'subagents')->make_path;
$b1->child('agent-cnometa3.jsonl')->spew(join '', map {"$_\n"}
  line('b1', 'cnometa3', 'n1', '2026-08-11T14:00:02Z', user('Check the kubernetes deployment')),
  line('b1', 'cnometa3', 'n2', '2026-08-11T14:00:03Z', assistant(text('The deployment is fine'))));

my $a2 = $root->child('projects', '-home-tester-proj-a', 'a2', 'subagents')->make_path;
$a2->child('workflows', 'wf_1')->make_path->child('journal.jsonl')
  ->spew(encode_json({type => 'user', sessionId => 'a2', message => {content => 'kubernetes journal'}}) . "\n");
$a2->child('agent-orphan.meta.json')->spew(encode_json({agentType => 'Explore', description => 'no run'}));

sub history () { MCP::Hub::Native::ClaudeHistory->new(root => "$root") }
my $plain = MCP::Hub::Native::ClaudeHistory->new(root => "$fixtures");
my $h     = history;

# A tool's answer, as the hub sends it: its JSON text decoded, checked against
# its structured content, and whether it is an error.
sub call ($server, $name, $args) {
  my ($tool) = grep { $_->name eq $name } @{$server->tools} or return {error => "no tool $name"};
  my $result = $tool->code->($tool, $args);
  return {error => $result->{content}[0]{text}} if $result->{isError};
  my $data = decode_json($result->{content}[0]{text});
  is_deeply decode_json(encode_json($result->{structuredContent})), (ref $data eq 'HASH' ? $data : {results => $data}),
    "$name: the structured content is the text";
  return $data;
}

# Where in a value a key starts with "_", and where a string holds $root.
sub leaks ($value, $at = '') {
  return map { leaks($value->[$_], "$at\[$_]") } 0 .. $#$value if ref $value eq 'ARRAY';
  return map { (/\A_/ ? "key $at.$_" : ()), leaks($value->{$_}, "$at.$_") } sort keys %$value if ref $value eq 'HASH';
  return defined $value && !ref $value && index($value, "$root") >= 0 ? "path $at" : ();
}

subtest 'runs are no sessions' => sub {
  is_deeply $h->list_sessions, $plain->list_sessions, 'list_sessions as without the runs';
  is_deeply $h->list_projects, $plain->list_projects, 'list_projects as without the runs';
  is_deeply $h->get_conversation({session_id => 'a1'}), $plain->get_conversation({session_id => 'a1'}),
    'a session without agent_id reads its own messages';
  is $h->get_conversation({session_id => 'aexplore1'})->{total}, 0, 'a run is no session of its own';
};

subtest 'list_subagents' => sub {
  my $runs = call($h, 'list_subagents', {session_id => 'a1'});
  is_deeply $runs, [
    {agent_id => 'bworker2', agent_type => 'mcp-hub-worker', description => 'Fix the widget',
      started_at => '2026-08-10T10:00:01Z', last_activity => '2026-08-10T10:00:06Z', messages => 2},
    {agent_id => 'aexplore1', agent_type => 'Explore', description => 'Find pod specs',
      started_at => '2026-08-10T10:00:02Z', last_activity => '2026-08-10T10:00:05Z', messages => 3},
  ], 'one row per run, in the order they started; a line that is no JSON is skipped';

  is_deeply call($h, 'list_subagents', {session_id => 'b1'}), [
    {agent_id => 'cnometa3', agent_type => undef, description => undef,
      started_at => '2026-08-11T14:00:02Z', last_activity => '2026-08-11T14:00:03Z', messages => 2},
  ], 'a run without a meta file, beside a session file named otherwise';

  is_deeply call($h, 'list_subagents', {session_id => 'a2'}), [], 'a subagents dir holding no run: an empty list';
  is_deeply call($plain, 'list_subagents', {session_id => 'a2'}), [], 'no subagents dir: an empty list';
  is_deeply call($h, 'list_subagents', {session_id => 'nope'}), [], 'an unknown session: as get_conversation answers it';
  is_deeply call($h, 'list_subagents', {session_id => 'aexplore1'}), [], 'a run has no runs';

  $a1->child('agent-bworker2.meta.json')->spew('{"agentType": "half');
  is $h->list_subagents({session_id => 'a1'})->[0]{agent_type}, undef, 'a meta file that is no JSON: null';
  $a1->child('agent-bworker2.meta.json')->spew('["mcp-hub-worker"]');
  is $h->list_subagents({session_id => 'a1'})->[0]{agent_type}, undef, 'one that holds no object: null';
  $a1->child('agent-bworker2.meta.json')
    ->spew(encode_json({agentType => {name => 'x'}, description => 42, spawnDepth => 1}));
  is_deeply [@{$h->list_subagents({session_id => 'a1'})->[0]}{qw(agent_type description)}], [undef, '42'],
    'an object counts as absent, a number as its string';
  $a1->child('agent-bworker2.meta.json')
    ->spew(encode_json({agentType => 'mcp-hub-worker', description => 'Fix the widget', spawnDepth => 1}));
};

subtest 'get_conversation of a run' => sub {
  my $conv = call($h, 'get_conversation', {session_id => 'a1', agent_id => 'aexplore1'});
  is_deeply $conv, {
    entries => [
      {uuid => 'e1', timestamp => '2026-08-10T10:00:02Z', role => 'user',      text => 'Find the kubernetes pod specs'},
      {uuid => 'e2', timestamp => '2026-08-10T10:00:03Z', role => 'assistant', text => "Found the deployment\n[tool_use Grep]"},
      {uuid => 'e3', timestamp => '2026-08-10T10:00:05Z', role => 'assistant', text => 'The kubernetes specs are in deploy/'},
    ],
    total    => 3,
    has_more => false,
  }, "the run's messages, in the shape of a session's";

  my $page = call($h, 'get_conversation', {session_id => 'a1', agent_id => 'aexplore1', offset => 1, limit => 1});
  is_deeply [map { $_->{uuid} } @{$page->{entries}}], ['e2'], 'offset and limit';
  ok $page->{has_more}, 'has_more';
  my $users = call($h, 'get_conversation', {session_id => 'a1', agent_id => 'bworker2', roles => ['user']});
  is_deeply [map { $_->{text} } @{$users->{entries}}], ['Fix the widget'], 'roles; the line that is no JSON skipped';
  is_deeply [map { $_->{uuid} } @{call($h, 'get_conversation', {session_id => 'b1', agent_id => 'cnometa3'})->{entries}}],
    ['n1', 'n2'], 'a run without a meta file';

  is_deeply call($h, 'get_conversation', {session_id => 'a1', agent_id => 'nope'}),
    {error => 'claude-history: no subagent run nope in session a1'}, 'an unknown agent_id is an error';
  is $h->get_conversation({session_id => 'a1', agent_id => 'nope'}), undef, 'which the method answers with undef';
  is_deeply call($h, 'get_conversation', {session_id => 'a1', agent_id => 'cnometa3'}),
    {error => 'claude-history: no subagent run cnometa3 in session a1'}, 'so is the run of another session';
  is_deeply call($h, 'get_conversation', {session_id => 'nope', agent_id => 'aexplore1'}),
    {entries => [], total => 0, has_more => false}, 'an unknown session: as without agent_id';

  for my $id ('../a1', 'aexplore1.jsonl', 'agent-aexplore1', '../../a1/subagents/agent-aexplore1', '', '.', 'orphan',
    "$a1/agent-aexplore1.jsonl") {
    is $h->get_conversation({session_id => 'a1', agent_id => $id}), undef, "agent_id '$id' finds no run";
  }
};

subtest 'search_conversations' => sub {
  for my $args ({query => 'kubernetes'}, {query => 'kubernetes', roles => ['user', 'assistant']},
    {query => 'deployment', roles => ['assistant'], limit => 1}, {query => 'zzz'}) {
    my $name  = encode_json($args);
    my $today = $plain->search_conversations({%$args});
    is_deeply call($h, 'search_conversations', {%$args}), $today, "$name: as without the runs";
    is_deeply call($h, 'search_conversations', {%$args, include_subagents => false}), $today,
      "$name: include_subagents false, the same";
  }

  my $hits = call($h, 'search_conversations', {query => 'kubernetes', roles => ['user', 'assistant'], include_subagents => true});
  is_deeply [map { [$_->{session_id}, $_->{agent_id}, $_->{timestamp}] } @$hits], [
    ['b1', undef,       '2026-08-11T14:00:00Z'],
    ['b1', 'cnometa3',  '2026-08-11T14:00:02Z'],
    ['a1', undef,       '2026-08-10T10:00:00Z'],
    ['a1', 'bworker2',  '2026-08-10T10:00:06Z'],
    ['a1', 'aexplore1', '2026-08-10T10:00:02Z'],
    ['a1', 'aexplore1', '2026-08-10T10:00:05Z'],
  ], "each session's own matches first, then its runs', in the order the runs started";
  my @own = grep { !exists $_->{agent_id} } @$hits;
  is_deeply \@own, $plain->search_conversations({query => 'kubernetes', roles => ['user', 'assistant']}),
    'the matches without agent_id are those of today';
  is_deeply $hits->[1], {session_id => 'b1', project => '/home/tester/proj-b', agent_id => 'cnometa3',
    timestamp => '2026-08-11T14:00:02Z', role => 'user', snippet => 'Check the kubernetes deployment'},
    "a run's match carries its session's id and project, and its agent_id";

  my $limited
    = $h->search_conversations({query => 'kubernetes', roles => ['user', 'assistant'], include_subagents => 1, limit => 4});
  is_deeply $limited, [@$hits[0 .. 3]], 'the limit counts the matches of runs too';
  is_deeply [map { [$_->{session_id}, $_->{agent_id}] }
      @{$h->search_conversations({query => 'kubernetes', include_subagents => 1, project => '/home/tester/proj-b'})}],
    [['b1', undef], ['b1', 'cnometa3']], "a session's filters keep its runs";
};

subtest 'nothing internal goes out' => sub {
  for my $call (['list_subagents', {session_id => 'a1'}], ['list_subagents', {session_id => 'b1'}],
    ['get_conversation', {session_id => 'a1', agent_id => 'aexplore1'}],
    ['search_conversations', {query => 'kubernetes', include_subagents => true}]) {
    my ($name, $args) = @$call;
    my ($tool) = grep { $_->name eq $name } @{$h->tools};
    my $result = $tool->code->($tool, $args);
    is_deeply [leaks(decode_json($result->{content}[0]{text}))], [], "$name: no internal key or path in the text";
    is_deeply [leaks($result->{structuredContent})], [], "$name: none in the structured content";
  }
};

my $decoded = 0;
my @opened;
{
  no warnings 'redefine';
  my $decode = \&MCP::Hub::Native::ClaudeHistory::decode_json;
  *MCP::Hub::Native::ClaudeHistory::decode_json = sub { $decoded++; $decode->(@_) };
  my $open = \&Mojo::File::open;
  *Mojo::File::open = sub ($p, @args) { push @opened, "$p"; $open->($p, @args) };
}
sub decodes ($code) { $decoded = 0; @opened = (); $code->(); return $decoded }

subtest 'a search reads the runs only if asked to' => sub {
  my $cold = history;
  decodes(sub { $cold->search_conversations({query => 'kubernetes'}) });
  is_deeply [grep {m{/subagents/}} @opened], [], 'without include_subagents, no run file is opened';

  my $lines = 0;
  for my $file (grep { $_->basename =~ /\.jsonl\z/ && $_ !~ m{/workflows/} } @{$root->list_tree}) {
    $lines += grep { length } split /\n/, $file->slurp;
  }
  $cold = history;
  is decodes(sub { $cold->search_conversations({query => 'wörd', include_subagents => 1}) }), $lines,
    "a cold search with them decodes every line of every session and run once ($lines), and no meta file";
  is scalar(grep {m{/subagents/}} @opened), 3, 'it opens each run file once';
  is_deeply [grep {m{/workflows/}} @opened], [], 'and nothing else in a subagents dir';
};

subtest 'the metadata cache keeps run files too' => sub {
  my $runs = $h->list_subagents({session_id => 'a1'});
  is decodes(sub { $h->list_subagents({session_id => 'a1'}) }), 2, 'unchanged runs: only their two meta files are decoded';

  open my $fh, '>>:raw', "$explore" or die $!;
  print {$fh} line('a1', 'aexplore1', 'e4', '2026-08-10T10:00:09Z', user('an appended needle')), "\n";
  close $fh;
  my $grown;
  is decodes(sub { $grown = $h->list_subagents({session_id => 'a1'}) }), 1 + 2, 'an appended line: it and the meta files';
  is_deeply [@{$grown->[1]}{qw(agent_id messages last_activity)}], ['aexplore1', 4, '2026-08-10T10:00:09Z'],
    'the run counts it';
  is_deeply $grown, history->list_subagents({session_id => 'a1'}), 'as a fresh instance';

  open $fh, '>>:raw', "$explore" or die $!;
  print {$fh} line('a1', 'aexplore1', 'e5', '2026-08-10T10:00:10Z', user('a second appended needle')), "\n";
  close $fh;
  my $hits;
  is decodes(sub { $hits = $h->search_conversations({query => 'needle', include_subagents => 1}) }), 2,
    'a search decodes the appended line, and the lines before it only where they hold the word raw';
  is_deeply [map { $_->{snippet} } @$hits], ['an appended needle', 'a second appended needle'], 'and finds both';
  is_deeply $hits, history->search_conversations({query => 'needle', include_subagents => 1}), 'as a fresh instance';
  is_deeply $h->list_subagents({session_id => 'a1'}), history->list_subagents({session_id => 'a1'}),
    'the metadata the search brought up to date';
};

# Every plain string under $value.
sub strings ($value) {
  return map { strings($_) } @$value        if ref $value eq 'ARRAY';
  return map { strings($_) } values %$value if ref $value eq 'HASH';
  return defined $value && !ref $value ? $value : ();
}

# Which of @texts the metadata cache of $server holds, whole or in part, for a
# run file.
sub held ($server, @texts) {
  my $cache   = $server->meta_cache;
  my @strings = map { strings($cache->{$_}) } grep {m{/subagents/}} keys %$cache;
  return grep { my $text = $_; grep { index($_, $text) >= 0 } @strings } @texts;
}

# No tool sends a run's first prompt, which is often a whole briefing of tens
# of KB; on a history of thousands of runs it would be most of what the cache
# holds. So the cache keeps it nowhere, whichever tool read the run, cold or
# grown; a session's first prompt it keeps.
subtest 'the cache keeps no first prompt of a run' => sub {
  my @prompts = ('Find the kubernetes pod specs', 'Fix the widget', 'Check the kubernetes deployment');

  my $searched = history;
  $searched->search_conversations({query => 'wörd', include_subagents => 1});
  is scalar(grep {m{/subagents/}} keys %{$searched->meta_cache}), 3, 'a cold search caches the three runs';
  is_deeply [held($searched, @prompts)], [], 'and keeps none of their first prompts';
  is_deeply $searched->list_sessions, $plain->list_sessions, "a session's first prompt it keeps";

  my $listed = history;
  $listed->list_subagents({session_id => $_}) for qw(a1 b1);
  is scalar(grep {m{/subagents/}} keys %{$listed->meta_cache}), 3, 'list_subagents caches them too';
  is_deeply [held($listed, @prompts)], [], 'and keeps none either';

  my $appended = 'a zebra prompt appended to a run';
  open my $fh, '>>:raw', $a1->child('agent-bworker2.jsonl') or die $!;
  print {$fh} line('a1', 'bworker2', 'w3', '2026-08-10T10:00:07Z', user($appended)), "\n";
  close $fh;
  is decodes(sub { $listed->list_subagents({session_id => 'a1'}) }), 1 + 2,
    'a grown run is read from where its scan stopped: the appended line and the meta files';
  my $hits = $searched->search_conversations({query => 'zebra', include_subagents => 1});
  is_deeply [map { $_->{agent_id} } @$hits], ['bworker2'], 'a search reads the grown run too';
  is_deeply [held($_, @prompts, $appended)], [], 'neither keeps a prompt of a grown run' for $listed, $searched;

  my $fresh = history;
  is_deeply $listed->list_subagents({session_id => 'a1'}), $fresh->list_subagents({session_id => 'a1'}),
    'list_subagents sends what a fresh instance sends';
  is_deeply $hits, $fresh->search_conversations({query => 'zebra', include_subagents => 1}), 'so does the search';
  is_deeply $searched->list_sessions, $plain->list_sessions, 'and list_sessions';
};

subtest 'registration' => sub {
  my %tool = map { $_->name => $_ } @{$h->tools};
  is_deeply [map { $_->name } @{$h->tools}[0 .. 4]],
    [qw(list_projects list_sessions search_conversations get_conversation list_subagents)],
    'list_subagents comes after the four tools before it';
  is_deeply $tool{list_subagents}->input_schema,
    {type => 'object', properties => {session_id => {type => 'string'}}, required => ['session_id']}, 'its schema';
  is $tool{get_conversation}->input_schema->{properties}{agent_id}{type}, 'string', 'get_conversation takes agent_id';
  is $tool{search_conversations}->input_schema->{properties}{include_subagents}{type}, 'boolean',
    'search_conversations takes include_subagents';
};

done_testing;
