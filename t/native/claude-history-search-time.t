#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(tempdir);
use Mojo::JSON qw(encode_json);
use MCP::Hub::Native::ClaudeHistory;

# search_conversations keeps a match by its own time: since and until mean
# "matches in this range", not "matches of the sessions active in it". A
# session's last_activity is the time of its last line that has one, which is
# not always the newest of its times; so no session is passed over for it.
# Each session holds the needle on some lines, "other" on the rest; the runs
# of "parent" are searched with include_subagents only.
my $root = tempdir;
my $dir  = $root->child('projects', '-home-tester-when')->make_path;
my $n    = 0;
sub day ($d) { sprintf '2026-11-%02dT10:00:00.000Z', $d }
sub line ($id, $time, $text) {
  return encode_json({type => 'user', sessionId => $id, cwd => '/home/tester/when', uuid => 'u' . $n++,
    (defined $time ? (timestamp => $time) : ()), message => {role => 'user', content => "the $text here"}});
}
sub lines (@lines) { join '', map {"$_\n"} @lines }

my $offset = '2026-11-04T01:00:00+02:00';    # 2026-11-03T23:00:00Z, before a since of 2026-11-04
$dir->child('after-until.jsonl')->spew(lines(map { line('after-until', @$_) } [day(2), 'needle'], [day(15), 'needle'], [day(20), 'other']));
$dir->child('late.jsonl')->spew(lines(map { line('late', @$_) } [day(1), 'needle'], [$offset, 'needle'], [day(5), 'needle'], [day(12), 'other']));
$dir->child('parent.jsonl')->spew(lines(map { line('parent', @$_) } [day(1), 'other'], [day(9), 'other']));
$dir->child('parent', 'subagents')->make_path->child('agent-r1.jsonl')
  ->spew(lines(map { line('parent', @$_) } [day(2), 'needle'], [day(7), 'needle']));
$dir->child('early.jsonl')->spew(lines(map { line('early', @$_) } [day(1), 'needle'], [day(6), 'other']));
$dir->child('unordered.jsonl')->spew(lines(map { line('unordered', @$_) } [day(8), 'needle'], [day(3), 'other']));
$dir->child('timeless.jsonl')->spew(lines(map { line('timeless', @$_) } [undef, 'needle'], ['yesterday', 'needle']));

my $h = MCP::Hub::Native::ClaudeHistory->new(root => "$root");

# The matches found, as "session[/agent] time"; the sessions newest first by
# last_activity (after-until, late, parent, early, unordered, timeless), each
# one's matches in file order, then those of its runs.
sub hits (%args) {
  my $hits = $h->search_conversations({query => 'needle', limit => 100, %args});
  return [map { $_->{session_id} . (defined $_->{agent_id} ? "/$_->{agent_id}" : '') . ' ' . ($_->{timestamp} // 'none') } @$hits];
}

my @timeless = ('timeless none', 'timeless yesterday');

subtest 'without since or until, every match' => sub {
  is_deeply hits(include_subagents => 1), ['after-until ' . day(2), 'after-until ' . day(15), 'late ' . day(1),
    "late $offset", 'late ' . day(5), 'parent/r1 ' . day(2), 'parent/r1 ' . day(7), 'early ' . day(1),
    'unordered ' . day(8), @timeless], 'all of them';
};

subtest 'since keeps the matches on or after it' => sub {
  is_deeply hits(since => '2026-11-04', include_subagents => 1), ['after-until ' . day(15), 'late ' . day(5),
    'parent/r1 ' . day(7), 'unordered ' . day(8), @timeless],
    'a session active after since sends none of its older matches; an offset is compared as the instant it is';
  is_deeply hits(since => '2026-11-04'), ['after-until ' . day(15), 'late ' . day(5), 'unordered ' . day(8), @timeless],
    'without include_subagents, no run';
  is_deeply [grep {/^early /} @{hits(since => '2026-11-04')}], [],
    'a session active after since whose matches are all before it sends none';
  is_deeply [grep {/^unordered /} @{hits(since => '2026-11-04')}], ['unordered ' . day(8)],
    'a session whose last line is before since sends its match after since';
};

subtest 'until keeps the matches on or before it' => sub {
  is_deeply hits(until => '2026-11-10', include_subagents => 1), ['after-until ' . day(2), 'late ' . day(1),
    "late $offset", 'late ' . day(5), 'parent/r1 ' . day(2), 'parent/r1 ' . day(7), 'early ' . day(1),
    'unordered ' . day(8), @timeless], 'a session active after until sends its matches before it';
};

subtest 'since and until together' => sub {
  is_deeply hits(since => '2026-11-04', until => '2026-11-07T10:00:00Z', include_subagents => 1),
    ['late ' . day(5), 'parent/r1 ' . day(7), @timeless], 'both ends included';
};

subtest 'the limit counts the matches kept' => sub {
  is_deeply hits(since => '2026-11-04', limit => 2), ['after-until ' . day(15), 'late ' . day(5)], 'limit 2';
  is_deeply hits(since => '2026-11-04', limit => 1, project => '/home/tester/when'), ['after-until ' . day(15)],
    'limit 1, with a project';
};

subtest 'a since or until that is no time is still an error' => sub {
  is $h->search_conversations({query => 'needle', since => 'last week'}), undef, 'undef from the method';
};

done_testing;
