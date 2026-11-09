#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(tempdir);
use Mojo::JSON qw(decode_json encode_json);
use MCP::Hub::Native::ClaudeHistory;

binmode Test::More->builder->$_, ':encoding(UTF-8)' for qw(output failure_output todo_output);

# Of a session's first prompt, list_sessions sends the first 500 characters,
# followed by "…" (U+2026) where the prompt is longer, and the metadata cache
# keeps only that: a first prompt is often a briefing of many KB, and the
# whole of it is the first message get_conversation returns. Characters are
# counted, not bytes, so a cut never splits one.
my $more = "\x{2026}";
my $root = tempdir;
my $dir  = $root->child('projects', '-home-tester-cut')->make_path;

my $t = 0;
sub ts () { my $s = $t++; sprintf '2026-10-07T08:%02d:%02dZ', $s / 60, $s % 60 }
sub rec ($id, %f) { encode_json({sessionId => $id, cwd => '/home/tester/cut', uuid => "u$t", timestamp => ts, %f}) }
sub user ($id, $text) { rec($id, type => 'user', message => {role => 'user', content => $text}) }
sub assistant ($id, $text) { rec($id, type => 'assistant', message => {role => 'assistant', content => [{type => 'text', text => $text}]}) }
sub file_of ($id) { $dir->child("$id.jsonl") }
sub append ($id, @bytes) { open my $fh, '>>:raw', file_of($id) or die $!; print {$fh} @bytes; close $fh }

# [session, its first prompt as get_conversation gives it, as list_sessions
# sends it, the JSON line of the prompt if not that of user()]. In bytes, the
# "ä" and the emoji at the 500th character reach past the 500th byte; written
# as an escaped surrogate pair, the emoji is two UTF-16 units.
my $tail  = ' and the end of the briefing, past the cut';
my $tick  = "\x{1F600}";
my @cases = (
  ['short',      'a short prompt',                         'a short prompt'],
  ['under',      'x' x 499,                                'x' x 499],
  ['exactly',    'x' x 500,                                'x' x 500],
  ['over',       'x' x 501,                                'x' x 500 . $more],
  ['long',       'b' x 4000 . $tail,                       'b' x 500 . $more],
  ['umlaut-500', 'x' x 499 . "\x{e4}",                     'x' x 499 . "\x{e4}"],
  ['umlaut-cut', 'x' x 499 . "\x{e4}" . 'y' x 20,          'x' x 499 . "\x{e4}" . $more],
  ['emoji-500',  'x' x 499 . $tick,                        'x' x 499 . $tick],
  ['emoji-cut',  'x' x 499 . $tick . 'tail',               'x' x 499 . $tick . $more],
  ['escaped',    'x' x 499 . $tick . 'tail',               'x' x 499 . $tick . $more,
    qq({"type":"user","sessionId":"escaped","cwd":"/home/tester/cut","uuid":"esc","timestamp":"@{[ts]}",)
      . qq("message":{"role":"user","content":"@{['x' x 499]}\\ud83d\\ude00tail"}})],
  ['blocks',     'c' x 300 . "\n" . 'd' x 300,             'c' x 300 . "\n" . 'd' x 199 . $more,
    rec('blocks', type => 'user', message => {role => 'user', content => [{type => 'text', text => 'c' x 300},
      {type => 'text', text => 'd' x 300}]})],
);
for my $case (@cases) {
  my ($id, $prompt, undef, $line) = @$case;
  file_of($id)->spew(join '', map {"$_\n"} $line // user($id, $prompt), assistant($id, 'an answer'), user($id, 'later'));
}

my $decoded = 0;
{
  no warnings 'redefine';
  my $decode = \&MCP::Hub::Native::ClaudeHistory::decode_json;
  *MCP::Hub::Native::ClaudeHistory::decode_json = sub { $decoded++; $decode->(@_) };
}
sub decodes ($code) { $decoded = 0; $code->(); return $decoded }

sub history () { MCP::Hub::Native::ClaudeHistory->new(root => "$root") }
sub sessions ($h) { +{map { $_->{session_id} => $_ } @{$h->list_sessions({limit => 100})}} }

# The JSON text list_sessions puts on the wire, decoded.
sub wire ($h) {
  my ($tool) = grep { $_->name eq 'list_sessions' } @{$h->tools};
  return +{map { $_->{session_id} => $_ } @{decode_json($tool->code->($tool, {limit => 100})->{content}[0]{text})}};
}

# Every string the metadata cache holds for one session file.
sub strings ($value) {
  return map { strings($_) } values %$value if ref $value eq 'HASH';
  return defined $value && !ref $value ? $value : ();
}
sub cached ($h, $id) { $h->meta_cache->{file_of($id)} }

my $h = history;
my ($listed, $sent) = (sessions($h), wire($h));
for my $case (@cases) {
  my ($id, $prompt, $want) = @$case;
  subtest "$id, @{[length $prompt]} characters" => sub {
    is $listed->{$id}{first_prompt}, $want, 'list_sessions gives its first 500 characters, and U+2026 if there are more';
    is $sent->{$id}{first_prompt},   $want, 'and sends them so';
    is cached($h, $id)->{state}{first_prompt}, $want, 'the cache keeps them in the scan state';
    is cached($h, $id)->{meta}{first_prompt},  $want, 'and in the metadata';
    is_deeply [grep { length > 501 } strings(cached($h, $id))], [], 'and no string longer than that';
    is history->get_conversation({session_id => $id})->{entries}[0]{text}, $prompt,
      'get_conversation gives the whole prompt';
  };
}

subtest 'the end of a long prompt' => sub {
  is_deeply [grep { index($_, $tail) >= 0 } map { strings(cached($h, $_->[0])) } @cases], [],
    'is nowhere in the cache';
  my $hits = $h->search_conversations({query => 'the end of the briefing'});
  is_deeply [map { $_->{session_id} } @$hits], ['long'], 'search_conversations finds it';
  like $hits->[0]{snippet}, qr/\Q$tail\E\z/, 'and gives it in its snippet';
  is_deeply sessions($h), $listed, 'and leaves list_sessions as it was';
};

subtest 'an appended line' => sub {
  my $before = cached($h, 'long')->{offset};
  my $longer = 'e' x 900;
  is decodes(sub { append('long', user('long', $longer) . "\n", assistant('long', 'reply') . "\n"); sessions($h) }), 2,
    'is read from where the scan stopped: the two appended lines';
  ok cached($h, 'long')->{offset} > $before, 'past it';
  my $now = sessions($h)->{long};
  is $now->{first_prompt}, 'b' x 500 . $more, 'and leaves the first prompt as it was';
  is $now->{messages}, 5, 'while it counts';
  is cached($h, 'long')->{state}{first_prompt}, 'b' x 500 . $more, 'the cache too';
  is_deeply sessions($h), sessions(history), 'as a fresh instance';
  is_deeply [map { $_->{text} } @{$h->get_conversation({session_id => 'long', roles => ['user']})->{entries}}],
    ['b' x 4000 . $tail, 'later', $longer], 'get_conversation gives every prompt whole';
};

# A last line without its newline counts for now, and is read again once the
# file grows.
subtest 'a first prompt on an unterminated last line' => sub {
  file_of('open')->spew(user('open', 'o' x 600));
  is sessions($h)->{open}{first_prompt}, 'o' x 500 . $more, 'is cut';
  is_deeply [grep { length > 501 } strings(cached($h, 'open'))], [], 'and cached cut';
  append('open', "\n" . user('open', 'p' x 600) . "\n");
  is sessions($h)->{open}{first_prompt}, 'o' x 500 . $more, 'and stays so once its newline and another prompt follow';
  is_deeply sessions($h), sessions(history), 'as a fresh instance';
};

done_testing;
