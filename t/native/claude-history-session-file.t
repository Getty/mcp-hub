#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(tempdir);
use Mojo::JSON qw(encode_json);
use MCP::Hub::Native::ClaudeHistory;

# Claude Code names a session's file after the session: <session_id>.jsonl.
# get_conversation reads that file first and, if it holds the session, no
# other -- on a cold cache too. A session in a file named otherwise is found by
# reading the others. The session_id is only ever compared with file names, so
# it cannot lead to a file outside the projects dir.
my $root = tempdir;

sub session ($dir, $name, $id, $text) {
  my $file = $root->child('projects', $dir)->make_path->child("$name.jsonl");
  $file->spew(join '', map { encode_json($_) . "\n" }
    {type => 'user', sessionId => $id, cwd => "/home/tester/$dir", timestamp => '2026-10-04T08:00:00Z',
      uuid => "$name-1", message => {role => 'user', content => $text}},
    {type => 'assistant', sessionId => $id, timestamp => '2026-10-04T08:00:01Z', uuid => "$name-2",
      message => {role => 'assistant', content => [{type => 'text', text => "re: $text"}]}});
  return $file;
}

# The project dirs and their files are read in sorted order: every file of
# "a" comes before any of "b".
session('a', "a$_", "a$_", "session a$_") for 1 .. 5;
session('a', 'copy',    'target',    'a copy of the target');    # another file that starts as the target
session('b', 'decoy',   'not-decoy', 'not the decoy');           # named after "decoy", holding another session
session('b', 'renamed', 'moved',     'the moved session');       # named after no session
session('b', 'target',  'target',    'the target');
session('b', 'zz-real', 'decoy',     'the real decoy');
$root->child('secret.jsonl')->spew($root->child('projects', 'b', 'target.jsonl')->slurp =~ s/"target"/"..\/..\/secret"/gr);

# The files get_conversation opens, and its first entry's text.
sub reads ($h, $session_id) {
  my @read;
  no warnings 'redefine';
  my $open = \&Mojo::File::open;
  local *Mojo::File::open = sub ($p, @args) { push @read, "$p"; $open->($p, @args) };
  my $conv = $h->get_conversation({session_id => $session_id});
  return $conv->{entries}[0]{text}, [map { s{^\Q$root\E/projects/}{}r } @read];
}
sub cold () { MCP::Hub::Native::ClaudeHistory->new(root => "$root") }

subtest 'the file named after the session' => sub {
  my $h = cold;
  my ($text, $read) = reads($h, 'target');
  is $text, 'the target', 'is the one read';
  is_deeply $read, ['b/target.jsonl', 'b/target.jsonl'], 'and the only one, on a cold cache: its metadata, then its lines';

  ($text, $read) = reads($h, 'target');
  is $text, 'the target', 'again';
  is_deeply $read, ['b/target.jsonl'], 'on a warm cache only for its lines';
  is((reads(cold, 'a3'))[0], 'session a3', 'in another project dir too');
};

subtest 'a session in a file named otherwise' => sub {
  my ($text, $read) = reads(cold, 'moved');
  is $text, 'the moved session', 'is found';
  is $read->[-1], 'b/renamed.jsonl', 'in the file that holds it';

  ($text, $read) = reads(cold, 'decoy');
  is $text, 'the real decoy', 'when the file of its name holds another session';
  is_deeply [@$read[0, -1]], ['b/decoy.jsonl', 'b/zz-real.jsonl'], 'that file is read first, then the others';

  my $missing = cold->get_conversation({session_id => 'nope'});
  is $missing->{total}, 0, 'a session in no file is empty';
};

subtest 'a session_id is no path' => sub {
  for my $id ('../../secret', "$root/secret", 'b/../../../secret', '..', '.', 'b/target', '/') {
    my ($text, $read) = reads(cold, $id);
    is $text, undef, "'$id' finds nothing";
    is_deeply [grep { m{^/|\.\.} } @$read], [], "'$id' reads nothing outside the projects dir";
  }
};

done_testing;
