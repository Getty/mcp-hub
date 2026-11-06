#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(tempdir);
use Mojo::JSON qw(encode_json);
use MCP::Hub::Native::ClaudeHistory;

# Claude Code names a session's file after the session: <session_id>.jsonl.
# get_conversation reads that file first and, if it holds the session, no
# other -- on a cold cache too, and then only once, for its metadata and its
# messages together. A session in a file named otherwise is found by reading
# the others. The session_id is only ever compared with file names, so it
# cannot lead to a file outside the projects dir.
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
  is_deeply $read, ['b/target.jsonl'], 'and the only one, once on a cold cache: for its metadata and its lines together';

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

# Every line of the file read is decoded once: for the metadata and the
# entries together where the metadata is out of date, for the entries alone
# where it is current.
subtest 'each line decoded once' => sub {
  my $decoded = 0;
  no warnings 'redefine';
  my $decode = \&MCP::Hub::Native::ClaudeHistory::decode_json;
  local *MCP::Hub::Native::ClaudeHistory::decode_json = sub { $decoded++; $decode->(@_) };
  my $decodes = sub ($h, $session_id) {
    $decoded = 0;
    my $conv = $h->get_conversation({session_id => $session_id});
    return $decoded, $conv;
  };

  my $one = tempdir;
  my $dir = $one->child('projects', '-home-tester-one')->make_path;
  my $n   = 0;
  my $add = sub ($name, $id, $count) {
    open my $fh, '>>:raw', $dir->child("$name.jsonl")->to_string or die $!;
    for (1 .. $count) {
      my $role = $n % 2 ? 'assistant' : 'user';
      print {$fh} encode_json({type => $role, sessionId => $id, cwd => '/home/tester/one', uuid => "u$n",
        timestamp => sprintf('2026-10-04T09:%02d:%02dZ', $n / 60, $n % 60), message => {role => $role, content => "line $n"}}) . "\n";
      $n++;
    }
  };
  $add->('one', 'one', 20);
  $add->('other', 'other', 10);
  $add->('renamed', 'moved', 10);
  my $h     = MCP::Hub::Native::ClaudeHistory->new(root => "$one");
  my $fresh = sub ($id) { MCP::Hub::Native::ClaudeHistory->new(root => "$one")->get_conversation({session_id => $id}) };

  my ($count, $conv) = $decodes->($h, 'one');
  is $count, 20, 'a cold cache: the lines of the named file, once';
  is $conv->{total}, 20, 'all of them entries';
  is_deeply $h->list_sessions, MCP::Hub::Native::ClaudeHistory->new(root => "$one")->list_sessions,
    'the metadata that pass cached is that of a list';

  ($count, $conv) = $decodes->($h, 'one');
  is $count, 20, 'a warm cache: once, for the entries';
  is_deeply $conv, $fresh->('one'), 'as on a cold cache';

  $add->('one', 'one', 3);
  ($count, $conv) = $decodes->($h, 'one');
  is $count, 23, 'the named file grew: once, for the metadata of the new lines and every entry';
  is $conv->{total}, 23, 'with the new lines';
  is_deeply $conv, $fresh->('one'), 'as on a cold cache';
  is_deeply $h->list_sessions, MCP::Hub::Native::ClaudeHistory->new(root => "$one")->list_sessions, 'and so is the metadata';

  # A file not named after the session is read only for its metadata, so one
  # that grew is read from where its last read stopped.
  $decodes->($h, 'moved');
  $add->('one', 'one', 2);
  ($count, $conv) = $decodes->($h, 'moved');
  is $count, 2 + 10, 'a session in a file named otherwise: the lines appended elsewhere, then its own';
  is_deeply $conv, $fresh->('moved'), 'as on a cold cache';
};

done_testing;
