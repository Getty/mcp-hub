#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(curfile path tempdir);
use Mojo::JSON qw(decode_json encode_json true);
use MCP::Hub::Native::ClaudeHistory;
use MCP::Hub::Native::ClaudeSessions;

# What a tool sends is what its POD documents: no key of it starts with "_",
# so no internal field -- like the path of a session file on this host -- goes
# out on the wire. Every tool of both natives is called, its JSON text and its
# structured content alike, and the test fails if a tool is left out. The
# fixtures are copied to a temp dir and given what the checkout does not hold:
# the subagent runs of a session, <session>/subagents/agent-<id>.jsonl with an
# agent-<id>.meta.json beside it, and a history.jsonl beside projects/.
my $fixtures = curfile->sibling('..', 'fixtures', 'claude');
my $dir      = tempdir;
for my $file (@{$fixtures->list_tree}) {
  my $to = $dir->child(@{$file->to_rel($fixtures)->to_array});
  $to->dirname->make_path;
  $file->copy_to($to);
}
my $root = $dir->to_string;

sub run_line ($agent_id, $uuid, $timestamp, %f) {
  return encode_json({sessionId => 'a1', agentId => $agent_id, isSidechain => true, uuid => $uuid,
    timestamp => $timestamp, cwd => '/home/tester/proj-a', %f});
}
my $runs = $dir->child('projects', '-home-tester-proj-a', 'a1', 'subagents')->make_path;
$runs->child('agent-aexplore1.jsonl')->spew(join '', map {"$_\n"}
  run_line('aexplore1', 'e1', '2026-08-10T10:00:02Z', type => 'user',
    message => {role => 'user', content => 'Find the kubernetes pod specs'}),
  run_line('aexplore1', 'e2', '2026-08-10T10:00:03Z', type => 'assistant',
    message => {role => 'assistant', content => [{type => 'text', text => 'The kubernetes specs are in deploy/'}]}));
$runs->child('agent-aexplore1.meta.json')
  ->spew(encode_json({agentType => 'Explore', description => 'Find pod specs', spawnDepth => 1, toolUseId => 'toolu_1'}));
$dir->child('history.jsonl')->spew(join '', map { encode_json($_) . "\n" }
  {display => 'A question about kubernetes', pastedContents => {}, project => '/home/tester/proj-a', sessionId => 'a1',
   timestamp => 1786356000000},
  {display => 'A prompt of a session without a transcript', pastedContents => {}, project => '/home/tester/gone',
   sessionId => 'gone-1', timestamp => 1786442400000});

# Where in a value a key starts with "_", and where a string holds $root.
sub leaks ($value, $at = '') {
  return map { leaks($value->[$_], "$at\[$_]") } 0 .. $#$value if ref $value eq 'ARRAY';
  return map { (/\A_/ ? "key $at.$_" : ()), leaks($value->{$_}, "$at.$_") } sort keys %$value if ref $value eq 'HASH';
  return defined $value && !ref $value && index($value, $root) >= 0 ? "path $at" : ();
}

my %called;
sub sends_nothing_internal ($server, $name, $args = {}) {
  $called{$server->name}{$name} = 1;
  my ($tool) = grep { $_->name eq $name } @{$server->tools};
  my $result = $tool->code->($tool, $args);
  my $data   = decode_json($result->{content}[0]{text});
  ok ref $data eq 'HASH' || @$data, "$name answers with something";
  is_deeply [leaks($data)], [], "$name sends no internal key and no path of this host in its text";
  is_deeply [leaks($result->{structuredContent})], [], "$name sends none in its structured content";
}

my $h = MCP::Hub::Native::ClaudeHistory->new(root => $root);
sends_nothing_internal($h, 'list_projects');
sends_nothing_internal($h, 'list_sessions');
sends_nothing_internal($h, 'list_sessions', {project => '/home/tester/proj-a', limit => 1});
sends_nothing_internal($h, 'search_conversations', {query => 'kubernetes', roles => ['user', 'assistant']});
sends_nothing_internal($h, 'get_conversation', {session_id => 'a1'});
sends_nothing_internal($h, 'get_conversation', {session_id => 'a1', agent_id => 'aexplore1'});
sends_nothing_internal($h, 'search_conversations',
  {query => 'kubernetes', roles => ['user', 'assistant'], include_subagents => true});
sends_nothing_internal($h, 'list_subagents', {session_id => 'a1'});
sends_nothing_internal($h, 'list_prompts');
sends_nothing_internal($h, 'list_prompts', {query => 'kubernetes', project => '/home/tester/proj-a', limit => 1});

my $can_symlink = eval { symlink('', "@{[tempdir]}/x"); 1 };
SKIP: {
  skip 'symlink not supported here', 3 unless $can_symlink;
  my $proc = tempdir;
  my $pid  = path($proc, 4242)->make_path;
  $pid->child('comm')->spew("claude\n");
  symlink('/home/tester/proj-a', $pid->child('cwd')->to_string) or die $!;
  sends_nothing_internal(MCP::Hub::Native::ClaudeSessions->new(root => $root, proc_root => "$proc"), 'list_running_sessions');
}

# Every tool a native registers was called above -- a tool added later must be
# called here too, or this fails and the claim in the header stays true.
# claude-sessions is checked only where its call was not skipped (no symlink).
subtest 'every tool of both natives was called' => sub {
  for my $native ($h, ($can_symlink ? MCP::Hub::Native::ClaudeSessions->new(root => $root) : ())) {
    is_deeply [sort keys %{$called{$native->name} // {}}], [sort map { $_->name } @{$native->tools}],
      $native->name . ': the tools called are the tools registered';
  }
};

done_testing;
