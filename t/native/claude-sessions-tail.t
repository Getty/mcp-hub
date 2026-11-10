#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(tempdir);
use Mojo::JSON qw(decode_json encode_json);
use MCP::Hub::Native::ClaudeSessions;

binmode Test::More->builder->$_, ':encoding(UTF-8)' for qw(output failure_output todo_output);

# list_running_sessions reads only the head and the tail of a session file.
# Each case here is compared with reading every line, the way it did before.
# The last prompt is the text of the last user line whose text is not empty: a
# user line that holds only tool results is passed over. It is sent cut to its
# first 500 characters, followed by an ellipsis (U+2026) where it is longer.
# The rules are written out here, in every_line and _cut, not asked of the
# code under test.
my $CHUNK = MCP::Hub::Native::ClaudeSessions::TAIL_CHUNK;
my $s     = MCP::Hub::Native::ClaudeSessions->new(root => "@{[tempdir]}", proc_root => "@{[tempdir]}");
my $dir   = tempdir;
my $more  = "\x{2026}";

sub _cut ($text) {
  return $text if !defined $text || length($text) <= 500;
  return substr($text, 0, 500) . $more;
}

sub every_line ($file) {
  my ($session_id, $started, $last, $branch, $last_prompt);
  for my $line (split /\n/, $file->slurp) {
    next unless length $line;
    my $rec = eval { decode_json($line) } or next;
    my $timestamp = MCP::Hub::Native::ClaudeSessions::_string($rec->{timestamp});
    $session_id //= MCP::Hub::Native::ClaudeSessions::_string($rec->{sessionId});
    $branch     //= $rec->{gitBranch};
    $started    //= $timestamp;
    $last = $timestamp if defined $timestamp;
    my $text = ($rec->{type} // '') eq 'user' ? MCP::Hub::Native::ClaudeSessions::_text($rec->{message}) : undef;
    $last_prompt = $text if defined $text && length $text;
  }
  return {session_id => $session_id // $file->basename =~ s/\.jsonl$//r, started_at => $started,
    last_activity => $last // $started, last_prompt => _cut($last_prompt), git_branch => $branch};
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
sub result ($bytes) { tool_result(message => {role => 'user', content => [{type => 'tool_result', tool_use_id => 't', content => 'r' x $bytes}]}) }
sub beside ($text) {
  tool_result(message => {role => 'user', content => [{type => 'tool_result', tool_use_id => 't', content => 'x'}, {type => 'text', text => $text}]});
}

# The last turn of a session: tool calls and their results, $bytes of each.
sub turn ($bytes, $n) { map { (filler($bytes), result($bytes)) } 1 .. $n }

my %cases = (
  'typical'                           => [user('first'), assistant('a'), user('second'), assistant('b')],
  'the last prompt two chunks back'   => [user('early'), user('the last prompt'), map { filler(1000) } 1 .. 2 * $CHUNK / 1000],
  'a line longer than a chunk at the end' => [user('one'), user('two'), filler(3 * $CHUNK)],
  'a line longer than a chunk before the prompt' => [user('one'), user('long ' . 'y' x (2 * $CHUNK)), filler(10)],
  'the last user line is a tool result'   => [user('prompt'), assistant('a'), tool_result()],
  'tool results two chunks back to the prompt' => [user('early'), user('the typed prompt'), turn(1000, 2 * $CHUNK / 2000 + 1)],
  'tool results back to the head'     => [user('the head'), turn(1000, $CHUNK / 1000)],
  'text beside a tool result'         => [user('prompt'), assistant('a'), beside('[Request interrupted by user]'), filler(10)],
  'an empty and a null prompt'        => [user('kept'), assistant('a'), user(''), user(undef), tool_result()],
  'only tool results as user lines'   => [tool_result(), assistant('a'), turn(1000, $CHUNK / 1000)],
  'no gitBranch anywhere'             => [user('one', gitBranch => undef), filler(2 * $CHUNK), user('two', gitBranch => undef)],
  'gitBranch first on a later line'   => [rec(type => 'file-history-snapshot', timestamp => undef, sessionId => undef, gitBranch => undef),
    user('one', gitBranch => undef), user('two', gitBranch => 'late'), filler($CHUNK), user('three')],
  'no user line'                      => [assistant('a'), filler($CHUNK), assistant('b')],
  'an object or array as id or time'  => [user('one', sessionId => {id => 'x'}, timestamp => ['x']), user('two', timestamp => {}),
    filler($CHUNK), user('three'), assistant('a', timestamp => [])],
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

# The claim every_line makes, spelt out for the cases with a user line that
# carries no text. A tool result as the last user line made the prompt ''.
subtest 'the last prompt is that of the last user line that carries text' => sub {
  for my $case (
    ['the last user line is a tool result',        'prompt'],
    ['tool results two chunks back to the prompt', 'the typed prompt'],
    ['tool results back to the head',              'the head'],
    ['text beside a tool result',                  '[Request interrupted by user]'],
    ['an empty and a null prompt',                 'kept'],
    ['only tool results as user lines',            undef],
  ) {
    my ($name, $prompt) = @$case;
    is $s->_session_meta($dir->child("$name.jsonl" =~ tr/ /_/r))->{last_prompt}, $prompt, $name;
  }
};

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

subtest 'a last prompt over 500 characters is cut' => sub {
  my $tick = "\x{1F600}";
  for my $case (
    ['499 characters',                  'a' x 499,                   'a' x 499],
    ['500 characters',                  'b' x 500,                   'b' x 500],
    ['501 characters',                  'c' x 501,                   'c' x 500 . $more],
    ['500 wide characters',             "\x{f6}" x 500,              "\x{f6}" x 500],
    ['501 wide characters',             "\x{f6}" x 501,              "\x{f6}" x 500 . $more],
    ['an emoji as the 500th character', 'x' x 499 . $tick . 'tail', 'x' x 499 . $tick . $more],
    ['a briefing of 40 KB',             'y' x 40_000,                'y' x 500 . $more],
  ) {
    my ($name, $prompt, $want) = @$case;
    my $file = $dir->child('cut.jsonl');
    $file->spew(join '', map {"$_\n"} user('first'), user($prompt), assistant('an answer'));
    is $s->_session_meta($file)->{last_prompt}, $want, $name;
  }

  SKIP: {
    skip 'symlink not supported here', 1 unless eval { symlink('', "@{[tempdir]}/x"); 1 };
    my $root = tempdir;
    $root->child('projects', '-home-tester-cut')->make_path->child('cut.jsonl')
      ->spew(join '', map {"$_\n"} user('z' x 600), tool_result());
    my $proc = tempdir;
    my $pid  = $proc->child('4242')->make_path;
    $pid->child('comm')->spew("claude\n");
    symlink('/home/tester/cut', $pid->child('cwd')->to_string) or die $!;
    my $server = MCP::Hub::Native::ClaudeSessions->new(root => "$root", proc_root => "$proc");
    my ($tool) = @{$server->tools};
    is decode_json($tool->code->($tool, {})->{content}[0]{text})->[0]{last_prompt}, 'z' x 500 . $more,
      'list_running_sessions sends it so';
  }
};

subtest 'the tail is decoded back to the last prompt, no further' => sub {
  my $file = $dir->child('long-turn.jsonl');
  $file->spew(join '', map {"$_\n"} user('start'), (map { assistant("turn $_ " . 'z' x 500) } 1 .. 2000),
    user('the typed prompt'), turn(200, 20));
  my $decoded = 0;
  no warnings 'redefine';
  local *MCP::Hub::Native::ClaudeSessions::decode_json = sub { $decoded++; decode_json(@_) };
  is $s->_session_meta($file)->{last_prompt}, 'the typed prompt', 'past the 20 tool results of the last turn';
  ok $decoded <= 1 + 41, "decoded $decoded of 2042 lines: the head's, and the tail's back to the prompt";
};

done_testing;
