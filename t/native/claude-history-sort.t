#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(tempdir);
use Mojo::JSON qw(decode_json encode_json);
use MCP::Hub::Native::ClaudeHistory;

# list_projects and list_sessions put the newest first, list_subagents the runs
# in the order they started, and search_conversations its matches in both
# orders: by the instants the times are. Claude Code writes them in UTC with
# milliseconds, whose strings sort as their instants do; times in other forms
# do not: of 2026-11-09T10:00:00.500Z and 2026-11-09T10:00:00Z, the earlier
# string is the later time ("." sorts before "Z"), and
# 2026-11-09T12:30:00+05:00, 07:30 in UTC, sorts as a string after 09:00 in
# UTC. Of one instant written in two forms (10:00:00Z, 10:00:00.000Z), their
# strings' order stands. A time that is no instant, none at all or one that is
# no ISO 8601 time ("yesterday"), counts as the oldest; of two such, their
# strings' order stands too.
my %time = (
  half   => '2026-11-09T10:00:00.500Z',
  whole  => '2026-11-09T10:00:00Z',
  millis => '2026-11-09T10:00:00.000Z',
  nine   => '2026-11-09T09:00:00.000Z',
  offset => '2026-11-09T12:30:00+05:00',
  junk   => 'yesterday',
  none   => undef,
);

sub line ($session_id, $timestamp, %f) {
  return encode_json({type => 'user', sessionId => $session_id, (defined $timestamp ? (timestamp => $timestamp) : ()),
      message => {role => 'user', content => "hello $session_id"}, %f}) . "\n";
}

# One root holds a project of a session for each time, and a session "parent"
# in another project, with a subagent run for each time and two more of nine's
# time, anine and bnine: of the three, their agent_ids decide the order.
my $root = tempdir;
my $sessions = $root->child('projects', '-home-tester-sessions')->make_path;
$sessions->child("$_.jsonl")->spew(line($_, $time{$_}, cwd => '/home/tester/sessions')) for keys %time;
my $runs = $root->child('projects', '-home-tester-runs')->make_path;
$runs->child('parent.jsonl')->spew(line('parent', '2026-11-09T09:30:00Z', cwd => '/home/tester/runs'));
my $subagents = $runs->child('parent', 'subagents')->make_path;
my %run = (%time, anine => $time{nine}, bnine => $time{nine});
$subagents->child("agent-$_.jsonl")->spew(line('parent', $run{$_}, agentId => $_, cwd => '/home/tester/runs'))
  for keys %run;

# Another root holds a project for each of these times; east has two
# sessions, of which the one at 09:00 in UTC is the newer.
my %project = (
  east => ['2026-11-09T12:30:00+05:00', '2026-11-09T09:00:00Z'],
  half => ['2026-11-09T09:00:00.500Z'],
  west => ['2026-11-09T08:00:00Z'],
  junk => ['yesterday'],
  none => [undef],
);
my $projects_root = tempdir;
for my $name (keys %project) {
  my $dir = $projects_root->child('projects', "-home-tester-$name")->make_path;
  my @times = @{$project{$name}};
  for my $n (1 .. @times) {
    $dir->child("$name-$n.jsonl")->spew(line("$name-$n", $times[$n - 1], cwd => "/home/tester/$name"));
  }
}

# What a tool answers, as the hub sends it.
sub call ($server, $name, $args = {}) {
  my ($tool) = grep { $_->name eq $name } @{$server->tools};
  my $result = $tool->code->($tool, $args);
  return {error => $result->{content}[0]{text}} if $result->{isError};
  return decode_json($result->{content}[0]{text});
}

my $h = MCP::Hub::Native::ClaudeHistory->new(root => "$root");

subtest 'list_sessions: newest first' => sub {
  my $list = call($h, 'list_sessions', {project => '/home/tester/sessions'});
  is_deeply [map { $_->{session_id} } @$list], [qw(half whole millis nine offset junk none)],
    'by instant; of one instant, as the strings sort; a time that is no instant the oldest';
  is_deeply [map { $_->{last_activity} } @$list], [@time{qw(half whole millis nine offset junk none)}],
    'each time sent as it was written';
};

subtest 'list_projects: newest activity first' => sub {
  my $list = call(MCP::Hub::Native::ClaudeHistory->new(root => "$projects_root"), 'list_projects');
  is_deeply [map { [$_->{project}, $_->{last_activity}] } @$list], [
    ['/home/tester/half', '2026-11-09T09:00:00.500Z'],
    ['/home/tester/east', '2026-11-09T09:00:00Z'],
    ['/home/tester/west', '2026-11-09T08:00:00Z'],
    ['/home/tester/junk', 'yesterday'],
    ['/home/tester/none', undef],
  ], "by instant, each project's activity that of its newest session by instant";
};

subtest 'list_subagents: in the order they started' => sub {
  my $list = call($h, 'list_subagents', {session_id => 'parent'});
  is_deeply [map { $_->{agent_id} } @$list], [qw(none junk offset anine bnine nine millis whole half)],
    'by instant; of one instant, as the strings sort, then by agent_id; a time that is no instant the oldest';
  is_deeply [map { $_->{started_at} } @$list], [@run{qw(none junk offset anine bnine nine millis whole half)}],
    'each time sent as it was written';
};

subtest 'search_conversations: in the order of the sessions, then of their runs' => sub {
  my $hits = call($h, 'search_conversations', {query => 'hello', include_subagents => \1, limit => 100});
  is_deeply [map { join '/', $_->{session_id}, $_->{agent_id} // () } @$hits], [
    qw(half whole millis parent),
    (map {"parent/$_"} qw(none junk offset anine bnine nine millis whole half)),
    qw(nine offset junk none),
  ], "each session's own match, newest session first, then its runs' in the order they started";
};

# The instant of a session's time is worked out when its file is read, and
# kept with its metadata; a file that grew is read again, and its new time
# sorts as the instant it is. Of half's 10:00:00.500 and whole's 10:00:00,
# nine's new 10:00:00.250 is between them, its string before both.
subtest 'a session whose file grew' => sub {
  open my $fh, '>>', $sessions->child('nine.jsonl') or die $!;
  print {$fh} line('nine', '2026-11-09T10:00:00.250Z', cwd => '/home/tester/sessions');
  close $fh;
  my $list = call($h, 'list_sessions', {project => '/home/tester/sessions'});
  is_deeply [map { $_->{session_id} } @$list], [qw(half nine whole millis offset junk none)],
    'sorts by its new time, as the instant it is';
};

done_testing;
