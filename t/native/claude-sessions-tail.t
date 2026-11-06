#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(tempdir);
use Mojo::JSON qw(decode_json encode_json);
use MCP::Hub::Native::ClaudeSessions;

# list_running_sessions reads only the head and the tail of a session file.
# Each case here is compared with reading every line, the way it did before.
my $CHUNK = MCP::Hub::Native::ClaudeSessions::TAIL_CHUNK;
my $s     = MCP::Hub::Native::ClaudeSessions->new(root => "@{[tempdir]}", proc_root => "@{[tempdir]}");
my $dir   = tempdir;

sub every_line ($file) {
  my ($session_id, $started, $last, $branch, $last_prompt);
  for my $line (split /\n/, $file->slurp) {
    next unless length $line;
    my $rec = eval { decode_json($line) } or next;
    $session_id //= $rec->{sessionId};
    $branch     //= $rec->{gitBranch};
    $started    //= $rec->{timestamp};
    $last = $rec->{timestamp} if defined $rec->{timestamp};
    $last_prompt = MCP::Hub::Native::ClaudeSessions::_text($rec->{message}) if ($rec->{type} // '') eq 'user';
  }
  return {session_id => $session_id // $file->basename =~ s/\.jsonl$//r, started_at => $started,
    last_activity => $last // $started, last_prompt => $last_prompt, git_branch => $branch};
}

my $t = 0;
sub rec (%f) {
  my %r = (sessionId => 'sess', gitBranch => 'main', timestamp => sprintf('2026-10-01T09:%02d:%02dZ', $t / 60, $t % 60), %f);
  $t++;
  delete @r{grep { !defined $r{$_} } keys %r};
  return encode_json(\%r);
}
sub user ($text, %f) { rec(type => 'user', message => {role => 'user', content => $text}, %f) }
sub assistant ($text, %f) { rec(type => 'assistant', message => {role => 'assistant', content => [{type => 'text', text => $text}]}, %f) }
sub tool_result (%f) { rec(type => 'user', message => {role => 'user', content => [{type => 'tool_result', tool_use_id => 't', content => 'x' x 50}]}, %f) }
sub filler ($bytes) { assistant('f' x $bytes) }

my %cases = (
  'typical'                           => [user('first'), assistant('a'), user('second'), assistant('b')],
  'the last prompt two chunks back'   => [user('early'), user('the last prompt'), map { filler(1000) } 1 .. 2 * $CHUNK / 1000],
  'a line longer than a chunk at the end' => [user('one'), user('two'), filler(3 * $CHUNK)],
  'a line longer than a chunk before the prompt' => [user('one'), user('long ' . 'y' x (2 * $CHUNK)), filler(10)],
  'the last user line is a tool result'   => [user('prompt'), assistant('a'), tool_result()],
  'no gitBranch anywhere'             => [user('one', gitBranch => undef), filler(2 * $CHUNK), user('two', gitBranch => undef)],
  'gitBranch first on a later line'   => [rec(type => 'file-history-snapshot', timestamp => undef, sessionId => undef, gitBranch => undef),
    user('one', gitBranch => undef), user('two', gitBranch => 'late'), filler($CHUNK), user('three')],
  'no user line'                      => [assistant('a'), filler($CHUNK), assistant('b')],
  'trailing lines without a timestamp' => [user('one'), user('two'), map { rec(type => 'summary', timestamp => undef) } 1 .. 3],
  'blank, broken and CRLF lines'      => [user('one'), '', '{"broken', user('crlf') . "\r", '', 'not json'],
  'non-ASCII prompt'                  => [user('one'), user("Grüße \x{2192} caf\x{e9} \x{1F600}"), assistant('done')],
  'a single line'                     => [user('only')],
  'empty'                             => [],
);

for my $name (sort keys %cases) {
  my $file = $dir->child("$name.jsonl" =~ tr/ /_/r);
  $file->spew(join('', map {"$_\n"} @{$cases{$name}}));
  is_deeply $s->_session_meta($file), every_line($file), $name;
}

subtest 'an unterminated last line' => sub {
  for my $tail (user('written in full'), substr(user('half written'), 0, 40)) {
    my $file = $dir->child('unterminated.jsonl');
    $file->spew(join("\n", user('one'), filler($CHUNK), $tail));
    is_deeply $s->_session_meta($file), every_line($file), length $tail > 40 ? 'whole' : 'half';
  }
};

subtest 'only the head and the tail are decoded' => sub {
  my $file = $dir->child('big.jsonl');
  $file->spew(join('', map {"$_\n"} user('start'), (map { assistant("turn $_ " . 'z' x 500) } 1 .. 2000), user('the end'), assistant('ok')));
  my $decoded = 0;
  no warnings 'redefine';
  local *MCP::Hub::Native::ClaudeSessions::decode_json = sub { $decoded++; decode_json(@_) };
  my $meta = $s->_session_meta($file);
  is $meta->{last_prompt}, 'the end', 'last prompt from the tail';
  is $meta->{started_at},  every_line($file)->{started_at}, 'start from the head';
  ok $decoded <= 4, "decoded $decoded of 2003 lines";
};

done_testing;
