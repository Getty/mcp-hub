#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(curfile tempdir);
use Mojo::JSON qw(decode_json encode_json false);
use MCP::Hub::Native::ClaudeHistory;

binmode Test::More->builder->$_, ':encoding(UTF-8)' for qw(output failure_output todo_output);

# Claude Code keeps its prompt history, what the up arrow recalls, in
# history.jsonl beside projects/: a line per prompt typed, {display,
# pastedContents, project, sessionId, timestamp} with the time in epoch
# milliseconds, kept after the session's own file is deleted. list_prompts
# sends it newest first. The history is written here into a copy of the
# fixtures, whose session files say which sessions have their transcript, so
# the fixtures in the checkout, which other tests list, stay as they are.
my $fixtures = curfile->sibling('..', 'fixtures', 'claude');
my $root     = tempdir;
for my $file (@{$fixtures->list_tree}) {
  my $to = $root->child(@{$file->to_rel($fixtures)->to_array});
  $to->dirname->make_path;
  $file->copy_to($to);
}
my $history = $root->child('history.jsonl');

sub prompt ($text, $project, $session_id, $ms, %f) {
  return encode_json({display => $text, pastedContents => {}, project => $project, sessionId => $session_id,
    timestamp => $ms, %f});
}
my ($proj_a, $proj_b, $gone) = map {"/home/tester/$_"} qw(proj-a proj-b gone);

# The prompts, by name, in the order of the file; L5 is older than the three
# before it and L6 of the same millisecond as L4. L4 holds its pasted text
# inline, L10 only by hash. L7 is written with escapes: \u004B is "K", \/ a
# slash. L8's display is a number, L9 has neither time nor project, and L11's
# session id is a path.
my %line = (
  L1 => prompt('Hello, a question about Kubernetes pods', $proj_a, 'a1', 1786356000000),
  L2 => prompt('A deployment question', $proj_b, 'b1', 1786456800250),
  L3 => prompt('/clear', $proj_a, 'a2', 1786525200005),
  L4 => prompt('[Pasted text #1 +12 lines] fix the kubernetes paste', $gone, 'gone-1', 1786579199999,
    pastedContents => {1 => {id => 1, type => 'text', content => "SECRET PASTE kubernetes\n" x 12}}),
  L5 => prompt('say "hi" to the team', $gone, 'gone-2', 1786438800000),
  L6 => prompt('and again, in the same millisecond', $gone, 'gone-1', 1786579199999),
  L7 => qq({"display":"\\u004Bubernetes via an escape, see \\/srv\\/app","pastedContents":{},)
    . qq("project":"$proj_a","sessionId":"a1","timestamp":1786608000000}),
  L8 => qq({"display":1e5,"pastedContents":{},"project":"$proj_a","sessionId":"a2","timestamp":1786611600000}),
  L9 => encode_json({display => 'a prompt without a time', pastedContents => {}, sessionId => 'gone-3'}),
  L10 => prompt("Gr\x{fc}\x{df}e an die \x{c4}rzte", $gone, 'gone-4', 1786615200000,
    pastedContents => {1 => {id => 1, type => 'text', contentHash => '2a95108e01dfd4e6'}}),
  L11 => prompt('a session id that is a path', $proj_a, '../-home-tester-proj-a/a1', 1786618800000),
);

# Lines that hold no prompt: no JSON, JSON but no object, an object without a
# display, or with one that is null, an object or an array; and a blank line.
my @skipped = (
  '{"display":"broken kubernetes', '[1,2]', '42', '"kubernetes"', '',
  encode_json({pastedContents => {}, project => $proj_a, sessionId => 'a1', timestamp => 1786356000001}),
  encode_json({display => undef,                  project => $proj_a, sessionId => 'a1', timestamp => 1786356000002}),
  encode_json({display => {text => 'kubernetes'}, project => $proj_a, sessionId => 'a1', timestamp => 1786356000003}),
  encode_json({display => ['kubernetes'],         project => $proj_a, sessionId => 'a1', timestamp => 1786356000004}),
);
sub spew_history (@names) { $history->spew(join '', map {"$_\n"} map { $line{$_} // $_ } @names) }
spew_history('L1', $skipped[0], 'L2', @skipped[1 .. 3], 'L3', 'L4', @skipped[4 .. 5], 'L5', 'L6', 'L7',
  @skipped[6 .. 8], 'L8', 'L9', 'L10', 'L11');

my $h = MCP::Hub::Native::ClaudeHistory->new(root => "$root");

# A tool's answer, as the hub sends it: its JSON text decoded, checked against
# its structured content. Without the tool, or for an error, a failure and an
# empty list.
sub call ($server, $args = {}) {
  my ($tool) = grep { $_->name eq 'list_prompts' } @{$server->tools};
  unless ($tool) { fail 'there is a tool list_prompts'; return [] }
  my $result = $tool->code->($tool, {%$args});
  if ($result->{isError}) { fail "list_prompts answers: $result->{content}[0]{text}"; return [] }
  my $data = decode_json($result->{content}[0]{text});
  is_deeply decode_json(encode_json($result->{structuredContent})), {results => $data},
    'the structured content is the text';
  return $data;
}
sub names ($prompts) {
  my %name = map { (decode_json($line{$_})->{display} // '') => $_ } keys %line;
  return [map { $name{$_->{text}} // "?$_->{text}" } @$prompts];
}
my @newest = qw(L11 L10 L8 L7 L6 L4 L3 L2 L5 L1 L9);

subtest 'every prompt, newest first' => sub {
  my $prompts = call($h);
  is_deeply names($prompts), \@newest,
    'by time, not by place in the file; a later line of the same time first; one without a time last';

  my %by = map { names([$_])->[0] => $_ } @$prompts;
  is_deeply $by{L4}, {timestamp => '2026-08-12T23:59:59.999Z', project => $gone, session_id => 'gone-1',
    text => '[Pasted text #1 +12 lines] fix the kubernetes paste', has_transcript => false},
    'a prompt: its time, project, session and text; the pasted text only as its placeholder';
  is_deeply [map { $by{$_}{timestamp} } qw(L1 L2 L3 L9)],
    ['2026-08-10T10:00:00.000Z', '2026-08-11T14:00:00.250Z', '2026-08-12T09:00:00.005Z', undef],
    'the time in the ISO 8601 form of the session files, in UTC with milliseconds; null without one';
  is $by{L7}{text}, 'Kubernetes via an escape, see /srv/app', 'the text decoded';
  is $by{L8}{text}, '100000', 'a number as its string';
  is $by{L9}{project}, undef, 'no project: null';
  is $by{L10}{text}, "Gr\x{fc}\x{df}e an die \x{c4}rzte", 'characters, not bytes';

  is_deeply [map { $by{$_}{has_transcript} ? $_ : () } @newest], [qw(L8 L7 L3 L1)],
    'has_transcript where a session file is named after the session: a1 and a2';
  ok !$by{L2}{has_transcript}, 'not for b1, whose file is named sess-b1.jsonl';
  ok !$by{L11}{has_transcript}, 'not for a session id that is a path to one';
};

subtest 'the pasted contents are never sent' => sub {
  my $text = encode_json(call($h, {limit => 1000}));
  unlike $text, qr/SECRET|contentHash|2a95108e01dfd4e6|pastedContents/, 'neither inline nor by hash';
  is_deeply call($h, {query => 'secret paste'}), [], 'nor searched';
};

subtest 'limit' => sub {
  is_deeply names(call($h, {limit => 2})), [qw(L11 L10)], 'the newest ones';
  is_deeply names(call($h, {limit => 5})), [@newest[0 .. 4]], 'of two of the same time at the cut, the later line';
  is_deeply names(call($h, {project => $gone, since => '2026-08-12', until => '2026-08-12', limit => 1})), ['L6'],
    'also where the earlier one is all that is kept when the later one comes';
  is_deeply call($h, {limit => 0}), [], 'none';

  my $many = tempdir;
  $many->child('history.jsonl')
    ->spew(join '', map { prompt("prompt $_", $proj_a, 's', 1786356000000 + $_ * 1000) . "\n" } 1 .. 60);
  my $prompts = call(MCP::Hub::Native::ClaudeHistory->new(root => "$many"));
  is scalar(@$prompts), 50, '50 by default';
  is $prompts->[0]{text}, 'prompt 60', 'the newest first';
  is $prompts->[-1]{text}, 'prompt 11', 'the 50th newest last';
  is_deeply [map { $_->{has_transcript} } @$prompts], [(false) x 50], 'no projects dir: no transcript';
};

subtest 'query' => sub {
  is_deeply names(call($h, {query => 'KUBERNETES'})), [qw(L7 L4 L1)],
    'case-insensitive, in the text alone, an escaped letter too; not in a line that is no prompt';
  is_deeply names(call($h, {query => 'Kubernetes', limit => 2})), [qw(L7 L4)], 'up to the limit, newest first';
  is_deeply names(call($h, {query => '"hi"'})), ['L5'], 'a needle holding a quote, which JSON escapes';
  is_deeply names(call($h, {query => '/srv/app'})), ['L7'], 'a needle holding a slash, escaped as \/ in the line';
  is_deeply names(call($h, {query => '100000'})), ['L8'], 'a display that is a number, as its string';
  is_deeply names(call($h, {query => "\x{e4}RZTE"})), ['L10'], 'a needle beyond ASCII';
  is_deeply names(call($h, {query => '[pasted text'})), ['L4'], 'a needle holding a bracket';
  is_deeply call($h, {query => 'zzz-none'}), [], 'no match: an empty list';
};

subtest 'project, since and until, as for list_sessions' => sub {
  is_deeply names(call($h, {project => $proj_a})), [qw(L11 L8 L7 L3 L1)], 'project';
  is_deeply names(call($h, {project => $proj_b})), ['L2'], 'a prompt without a project is in none';
  is_deeply names(call($h, {project => '/home/tester'})), [], 'the path whole, not a prefix';

  is_deeply names(call($h, {since => '2026-08-12'})), [qw(L11 L10 L8 L7 L6 L4 L3 L9)],
    'since a day: from its start, in UTC; a prompt without a time passes, as a session without one does';
  is_deeply names(call($h, {until => '2026-08-11'})), [qw(L2 L5 L1 L9)], 'until a day: to its end';
  is_deeply names(call($h, {since => '2026-08-12', until => '2026-08-12'})), [qw(L6 L4 L3 L9)],
    'both: the day, its last millisecond too';
  is_deeply names(call($h, {since => '2026-08-12T09:00:00.005Z', until => '2026-08-13T08:00:00.000Z'})),
    [qw(L7 L6 L4 L3 L9)], 'full timestamps, both ends included';
  is_deeply names(call($h, {project => $gone, since => '2026-08-12', query => 'again'})), ['L6'],
    'all of them at once';
};

subtest 'lines that hold no prompt are skipped' => sub {
  is scalar(@{call($h, {limit => 1000})}), 11, 'eleven prompts of twenty lines';

  # Every line is decoded by the decode_json seam; with a needle that has a
  # raw test, only the lines that can hold it are.
  my $decoded = 0;
  {
    no warnings 'redefine';
    my $decode = \&MCP::Hub::Native::ClaudeHistory::decode_json;
    local *MCP::Hub::Native::ClaudeHistory::decode_json = sub { $decoded++; $decode->(@_) };
    call($h);
    is $decoded, 19, 'without a query, every line that is not blank';
    $decoded = 0;
    call($h, {query => 'question'});
    is $decoded, 3, 'with one, only those that can hold it: L1 and L2 hold it raw, L7 has an escape';
  }

  my $tail = tempdir;
  $tail->child('history.jsonl')->spew($line{L1} . "\n" . $line{L2});
  is_deeply names(call(MCP::Hub::Native::ClaudeHistory->new(root => "$tail"))), [qw(L2 L1)],
    'a last line without its newline counts';
  $tail->child('history.jsonl')->spew($line{L1} . "\n" . substr($line{L2}, 0, 20));
  is_deeply names(call(MCP::Hub::Native::ClaudeHistory->new(root => "$tail"))), ['L1'],
    'one cut short does not';
};

subtest 'the time of a prompt' => sub {
  my $times = tempdir;
  $times->child('history.jsonl')->spew(join '', map {"$_\n"}
    prompt('a string of digits', $proj_a, 's', '1786356000000'),
    prompt('an ISO string',      $proj_a, 's', '2026-08-10T10:00:00Z'),
    prompt('a fraction',         $proj_a, 's', 1786356000000.75),
    prompt('the last one there is', $proj_a, 's', 253402300799999),
    prompt('past the year 9999', $proj_a, 's', 253402300800000),
    prompt('negative',           $proj_a, 's', -1),
    prompt('an object',          $proj_a, 's', {ms => 1}),
    prompt('the epoch',          $proj_a, 's', 0));
  my $prompts = call(MCP::Hub::Native::ClaudeHistory->new(root => "$times"));
  is_deeply [map { "$_->{text}: " . ($_->{timestamp} // 'null') } @$prompts], [
    'the last one there is: 9999-12-31T23:59:59.999Z',
    'a fraction: 2026-08-10T10:00:00.000Z',
    'a string of digits: 2026-08-10T10:00:00.000Z',
    'the epoch: 1970-01-01T00:00:00.000Z',
    'an object: null', 'negative: null', 'past the year 9999: null', 'an ISO string: null',
  ], 'a number of milliseconds up to the year 9999; anything else is no time, and sorts last';
};

subtest 'no history' => sub {
  my $empty = MCP::Hub::Native::ClaudeHistory->new(root => "$fixtures");
  ok !-e $fixtures->child('history.jsonl'), 'the fixtures hold none';
  is_deeply call($empty), [], 'an empty list';
  is_deeply call(MCP::Hub::Native::ClaudeHistory->new(root => "@{[tempdir]}/nowhere")), [], 'nor does a missing root';
};

# Claude Code appends to its history and writes it anew when it prunes it.
# Each call reads the file as it is, whatever happened to it in between --
# even a rewrite to the same size and mtime, under the same name.
subtest 'a history rewritten between two calls' => sub {
  my $copy = tempdir;
  my $file = $copy->child('history.jsonl');
  my $hist = MCP::Hub::Native::ClaudeHistory->new(root => "$copy");
  $file->spew(join '', map {"$line{$_}\n"} qw(L1 L2 L3 L4 L5 L6));
  my ($ino, $mtime) = ((stat $file)[1], (stat $file)[9] - 10);
  utime $mtime, $mtime, "$file" or die $!;
  is_deeply names(call($hist)), [qw(L6 L4 L3 L2 L5 L1)], 'the first call';

  $file->spew(join '', map {"$line{$_}\n"} qw(L1 L2));
  utime $mtime, $mtime, "$file" or die $!;
  is +(stat $file)[1], $ino, 'rewritten in place';
  is_deeply names(call($hist)), [qw(L2 L1)], 'rewritten shorter, its mtime as before: what it holds now';

  my $size = -s $file;
  my $n    = $size - length(prompt('x', $proj_b, 'b1', 1786456800250)) - 1;
  my $same = prompt('x' . 'y' x $n, $proj_b, 'b1', 1786456800250) . "\n";
  is length $same, $size, 'a replacement of the same size';
  $copy->child('history.jsonl.tmp')->spew($same)->move_to($file);
  utime $mtime, $mtime, "$file" or die $!;
  isnt +(stat $file)[1], $ino, 'moved over it';
  is_deeply [map { length $_->{text} } @{call($hist)}], [1 + $n],
    'replaced by another file of that size and mtime: its one prompt';

  open my $fh, '>>:raw', "$file" or die $!;
  print {$fh} "$line{L11}\n";
  close $fh;
  is_deeply names([call($hist)->[0]]), ['L11'], 'appended to: the new line too';

  $file->remove;
  is_deeply call($hist), [], 'removed: an empty list';
};

# Where in a value a key starts with "_", and where a string holds $root.
sub leaks ($value, $at = '') {
  return map { leaks($value->[$_], "$at\[$_]") } 0 .. $#$value if ref $value eq 'ARRAY';
  return map { (/\A_/ ? "key $at.$_" : ()), leaks($value->{$_}, "$at.$_") } sort keys %$value if ref $value eq 'HASH';
  return defined $value && !ref $value && index($value, "$root") >= 0 ? "path $at" : ();
}

subtest 'no internal key, no path of this host' => sub {
  my ($tool) = grep { $_->name eq 'list_prompts' } @{$h->tools} or return fail 'there is a tool list_prompts';
  for my $args ({}, {query => 'kubernetes'}, {project => $proj_a, limit => 1}) {
    my $result = $tool->code->($tool, {%$args});
    is_deeply [leaks(decode_json($result->{content}[0]{text}))], [], 'none in the text of ' . encode_json($args);
    is_deeply [leaks($result->{structuredContent})], [], 'none in its structured content';
  }
};

subtest 'registration' => sub {
  my %tool = map { $_->name => $_ } @{$h->tools};
  is_deeply [map { $_->name } @{$h->tools}],
    [qw(list_projects list_sessions search_conversations get_conversation list_subagents list_prompts)],
    'list_prompts comes last';
  is_deeply $tool{list_prompts}->input_schema, {
    type       => 'object',
    properties => {
      query   => {type => 'string', description => 'Only prompts holding this substring (case-insensitive)'},
      project => {type => 'string', description => 'Restrict to this project path'},
      since   => {type => 'string', description => 'Only prompts on or after this date (YYYY-MM-DD or ISO)'},
      until   => {type => 'string', description => 'Only prompts on or before this date'},
      limit   => {type => 'integer', description => 'Maximum prompts to return (default 50)'},
    },
  }, 'its schema: nothing required';
  like $tool{list_prompts}->description, qr/newest first/, 'its description';
};

done_testing;
