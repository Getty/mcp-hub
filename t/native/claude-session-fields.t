#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(tempdir);
use Mojo::JSON qw(decode_json);
use MCP::Hub::Native::ClaudeHistory;
use MCP::Hub::Native::ClaudeSessions;

# A record's sessionId, cwd and timestamp are strings in a Claude Code session
# file. One that is an object or array counts as absent: a later record's value
# fills it, or the session goes without, and the lookup, the filters and the
# sorts that compare these fields never see it stringified as HASH(0x...). A
# number or boolean counts as its string. Each line is written raw, so the test
# controls every value.
my $n = 0;
sub ts ($min) { sprintf '"2026-10-07T08:%02d:00Z"', $min }
sub message ($role, $text) { qq({"role":"$role","content":"$text"}) }

# A line from its fields, each value JSON as written.
sub line (%f) {
  my %r = (type => '"user"', uuid => qq("u@{[$n++]}"), message => message('user', 'a prompt'), %f);
  return '{' . join(',', map {qq("$_":$r{$_})} sort keys %r) . '}';
}

# A session file NAME.jsonl in the project dir of /home/tester/NAME.
sub session ($root, $name, @lines) {
  $root->child('projects', "-home-tester-$name")->make_path->child("$name.jsonl")->spew(join '', map {"$_\n"} @lines);
}

# What a tool puts on the wire: the JSON text of its result, and that decoded.
sub text ($server, $name, $args = {}) {
  my ($tool) = grep { $_->name eq $name } @{$server->tools};
  return $tool->code->($tool, $args)->{content}[0]{text};
}
sub wire (@args) { decode_json(text(@args)) }

sub ids ($sessions) { [map { $_->{session_id} } @$sessions] }

# The JSON text list_running_sessions sends for claude processes in these
# cwds, by pid; $proc holds the fake /proc until it has answered.
sub running ($root, %cwd) {
  my $proc = tempdir;
  for my $pid (sort keys %cwd) {
    my $dir = $proc->child($pid)->make_path;
    $dir->child('comm')->spew("claude\n");
    symlink($cwd{$pid}, $dir->child('cwd')->to_string) or die $!;
  }
  return text(MCP::Hub::Native::ClaudeSessions->new(root => "$root", proc_root => "$proc"), 'list_running_sessions');
}

my $symlink = eval { symlink('', "@{[tempdir]}/x"); 1 };

for my $value ('{"id":"filled"}', '{}', '["filled"]', '[]') {
  subtest "sessionId, cwd and timestamp $value" => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };

    # "fill" has the value first and last, a string between; "absent" only the
    # value; "other" only strings, a day before; "early", in the dir of
    # "absent" and a file older than its, only strings, two days before.
    my $root = tempdir;
    session($root, 'fill',
      line(sessionId => $value, cwd => $value, timestamp => $value, gitBranch => '"main"',
        message => message('user', 'the first prompt')),
      line(type => '"assistant"', sessionId => '"filled"', cwd => '"/work/filled"', timestamp => ts(1),
        message => message('assistant', 'an answer')),
      line(sessionId => '"filled"', timestamp => ts(5), message => message('user', 'the last prompt')),
      line(type => '"assistant"', sessionId => $value, cwd => $value, timestamp => $value,
        message => message('assistant', 'a last answer')));
    session($root, 'absent', map { line(sessionId => $value, cwd => $value, timestamp => $value) } 1 .. 2);
    session($root, 'other', line(sessionId => '"other"', cwd => '"/home/tester/other"', timestamp => '"2026-10-06T08:00:00Z"'));
    my $early = $root->child('projects', '-home-tester-absent', 'early.jsonl');
    $early->spew(line(sessionId => '"early"', cwd => '"/home/tester/absent"', timestamp => '"2026-10-05T08:00:00Z"') . "\n");
    utime time - 100, time - 100, "$early" or die "$early: $!";
    my $h = MCP::Hub::Native::ClaudeHistory->new(root => "$root");

    is_deeply [map { [@$_{qw(session_id project started_at last_activity)}] } @{wire($h, 'list_sessions')}], [
      ['filled', '/work/filled',        '2026-10-07T08:01:00Z', '2026-10-07T08:05:00Z'],
      ['other',  '/home/tester/other',  '2026-10-06T08:00:00Z', '2026-10-06T08:00:00Z'],
      ['early',  '/home/tester/absent', '2026-10-05T08:00:00Z', '2026-10-05T08:00:00Z'],
      ['absent', '/home/tester/absent', undef,                  undef],
    ], 'list_sessions sends the later string, or the file name, the project dir or null; newest first';
    is_deeply [map { [@$_{qw(project last_activity)}] } @{wire($h, 'list_projects')}], [
      ['/work/filled',        '2026-10-07T08:05:00Z'],
      ['/home/tester/other',  '2026-10-06T08:00:00Z'],
      ['/home/tester/absent', '2026-10-05T08:00:00Z'],
    ], 'list_projects too, a session without a time older than one with';

    is $h->get_conversation({session_id => 'filled'})->{total}, 4, 'get_conversation finds a session by the later id';
    is $h->get_conversation({session_id => 'absent'})->{total}, 2, 'and one without an id by its file name';
    is_deeply ids($h->list_sessions({project => '/work/filled'})),        ['filled'], 'the project filter compares the later cwd';
    is_deeply ids($h->list_sessions({project => '/home/tester/absent'})), ['early', 'absent'], 'or the project dir';
    is_deeply ids($h->list_sessions({since => '2026-10-07'})), ['filled', 'absent'], 'since compares the later time';
    is_deeply ids($h->list_sessions({until => '2026-10-06'})), ['other', 'early', 'absent'], 'until too';
    is_deeply [map { [@$_{qw(session_id project)}] } @{$h->search_conversations({query => 'the last prompt'})}],
      [['filled', '/work/filled']], 'search_conversations sends the later id and cwd';

    SKIP: {
      skip 'symlink not supported here', 1 unless $symlink;
      my $running = decode_json(running($root, 4242 => '/home/tester/fill', 4243 => '/home/tester/absent'));
      is_deeply [map { [@$_{qw(session_id started_at last_activity last_prompt git_branch)}] } @$running], [
        ['filled', '2026-10-07T08:01:00Z', '2026-10-07T08:05:00Z', 'the last prompt', 'main'],
        ['absent', undef,                  undef,                  'a prompt',        undef],
      ], 'list_running_sessions takes the later string, from the head and the tail alike';
    }

    is_deeply \@warnings, [], 'reading it warns about nothing';
  };
}

# A sessionId that is a number or boolean: [JSON, its string].
for my $case (['42', '42'], ['-1.5', '-1.5'], ['true', '1'], ['false', '0']) {
  my ($json, $string) = @$case;
  subtest "sessionId $json" => sub {
    my $root = tempdir;
    session($root, 'num', line(sessionId => $json, cwd => '"/home/tester/num"', timestamp => ts(0)));
    my $h = MCP::Hub::Native::ClaudeHistory->new(root => "$root");

    like text($h, 'list_sessions'), qr/"session_id":"\Q$string\E"/, qq(list_sessions sends it as the string "$string");
    is $h->get_conversation({session_id => $string})->{total}, 1, 'get_conversation finds the session so';
    SKIP: {
      skip 'symlink not supported here', 1 unless $symlink;
      like running($root, 4242 => '/home/tester/num'), qr/"session_id":"\Q$string\E"/, 'list_running_sessions too';
    }
  };
}

done_testing;
