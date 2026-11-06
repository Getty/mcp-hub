#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(tempdir);
use Mojo::JSON qw(encode_json);
use MCP::Hub::Native::ClaudeHistory;
use MCP::Hub::Native::ClaudeSessions;

# The text of a message is a string on the wire, whatever JSON its content is,
# and reading it warns about nothing. Each session is written raw, so the test
# controls every value. A user line carries a gitBranch, so ClaudeSessions takes
# the first user line from the head of the file and the last from its tail.
my $n = 0;
sub ts () { sprintf '2026-10-06T08:%02d:00Z', $n++ }
sub user ($content) { qq({"type":"user","sessionId":"vals","cwd":"/home/tester/vals","gitBranch":"main","uuid":"u$n","timestamp":"@{[ts]}","message":{"role":"user","content":$content}}) }
sub assistant ($content) { qq({"type":"assistant","sessionId":"vals","uuid":"u$n","timestamp":"@{[ts]}","message":{"role":"assistant","content":$content}}) }

sub session (@lines) {
  $n = 0;
  my $root = tempdir;
  $root->child('projects', '-home-tester-vals')->make_path->child('vals.jsonl')->spew(join '', map {"$_\n"} @lines);
  return $root;
}

# What a tool puts on the wire: the JSON text of its result.
sub wire ($server, $name, $args = {}) {
  my ($tool) = grep { $_->name eq $name } @{$server->tools};
  return $tool->code->($tool, $args)->{content}[0]{text};
}

# The JSON of one value, as it appears after its key.
sub json ($value) { substr encode_json([$value]), 1, -1 }

subtest 'a tool_use block without a name' => sub {
  my @warnings;
  local $SIG{__WARN__} = sub { push @warnings, @_ };
  my $root = session(
    user(q("run it")),
    assistant(q([{"type":"text","text":"Running it"},{"type":"tool_use","id":"t1","input":{}}])),
    assistant(q([{"type":"tool_use","id":"t2","name":null,"input":{}},{"type":"text","text":"done"}])),
  );
  my $h    = MCP::Hub::Native::ClaudeHistory->new(root => "$root");
  my $conv = $h->get_conversation({session_id => 'vals'});
  is_deeply [map { $_->{text} } @{$conv->{entries}}], ['run it', "Running it\n[tool_use]", "[tool_use]\ndone"],
    'renders as [tool_use], name missing or null';
  my $hits = $h->search_conversations({query => 'tool_use]', roles => ['assistant']});
  is_deeply [map { $_->{snippet} } @$hits], ['Running it [tool_use]', '[tool_use] done'], 'and is searched so';
  is_deeply \@warnings, [], 'reading it warns about nothing';
};

# Content that is not an array, then an array of one text block whose text is
# not a string: [JSON, the text it is, what the case shows].
my @cases = (
  [q("a plain string"), 'a plain string', 'a string stays as it is'],
  [q("1e5"),            '1e5',            'a string that looks like a number too'],
  [q(""),               '',               'an empty string too'],
  [q(1e5),              '100000',         'a number becomes its string'],
  [q(42),               '42',             'an integer too'],
  [q(-1.5),             '-1.5',           'a negative fraction too'],
  [q(true),             '1',              'true becomes "1"'],
  [q(false),            '0',              'false becomes "0"'],
  [q({"text":"in an object"}), '',        'an object becomes no text'],
  [q({}),               '',               'an empty object too'],
  [q(null),             undef,            'null stays null'],
  [q([{"type":"text","text":{"text":"in an object"}}]), '',         'an object as block text becomes no text'],
  [q([{"type":"text","text":{}}]),                      '',         'an empty object too'],
  [q([{"type":"text","text":["in an array"]}]),         '',         'an array too'],
  [q([{"type":"text","text":[]}]),                      '',         'an empty array too'],
  [q([{"type":"text","text":7e7}]),                     '70000000', 'a number becomes its string'],
  [q([{"type":"text","text":true}]),                    '1',        'true becomes "1"'],
  [q([{"type":"text","text":false}]),                   '0',        'false becomes "0"'],
  [q([{"type":"text","text":null}]),                    '',         'null becomes no text'],
);

for my $case (@cases) {
  my ($content, $text, $name) = @$case;
  subtest "content $content" => sub {
    my $root = session(user($content), assistant(q("an answer")), user($content));
    my $h    = MCP::Hub::Native::ClaudeHistory->new(root => "$root");
    my $want = json($text);

    my $entries = $h->get_conversation({session_id => 'vals', roles => ['user']})->{entries};
    is_deeply [map { $_->{text} } @$entries], [$text, $text], $name;
    like wire($h, 'get_conversation', {session_id => 'vals', roles => ['user']}), qr/"text":\Q$want\E,.*"text":\Q$want\E,/,
      'get_conversation sends it so';
    like wire($h, 'list_sessions'), qr/"first_prompt":\Q$want\E[,}]/, 'list_sessions sends it so as first_prompt';

    SKIP: {
      skip 'symlink not supported here', 2 unless eval { symlink('', "@{[tempdir]}/x"); 1 };
      my $proc = tempdir;
      my $pid  = $proc->child('4242')->make_path;
      $pid->child('comm')->spew("claude\n");
      symlink('/home/tester/vals', $pid->child('cwd')->to_string) or die $!;
      my $s = MCP::Hub::Native::ClaudeSessions->new(root => "$root", proc_root => "$proc");
      is $s->list_running_sessions->[0]{last_prompt}, $text, 'ClaudeSessions makes the same text of it';
      like wire($s, 'list_running_sessions'), qr/"last_prompt":\Q$want\E[,}]/, 'and sends it so as last_prompt';
    }
  };
}

# A tool_use block whose name is not a string: [JSON of the name, the marker it
# renders as, what the case shows].
my @names = (
  [q({"name":"Bash"}), '[tool_use]',      'an object as name renders as a tool_use without one'],
  [q({}),              '[tool_use]',      'an empty object too'],
  [q(["Bash"]),        '[tool_use]',      'an array too'],
  [q([]),              '[tool_use]',      'an empty array too'],
  [q(3e3),             '[tool_use 3000]', 'a number as its string'],
  [q(true),            '[tool_use 1]',    'true as "1"'],
  [q(false),           '[tool_use 0]',    'false as "0"'],
);

for my $case (@names) {
  my ($json, $marker, $name) = @$case;
  subtest "tool_use name $json" => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $root = session(user(q("run it")),
      assistant(qq([{"type":"text","text":"Running it"},{"type":"tool_use","id":"t1","name":$json,"input":{}}])));
    my $h    = MCP::Hub::Native::ClaudeHistory->new(root => "$root");
    my $args = {session_id => 'vals', roles => ['assistant']};
    my $want = json("Running it\n$marker");

    is_deeply [map { $_->{text} } @{$h->get_conversation($args)->{entries}}], ["Running it\n$marker"], $name;
    like wire($h, 'get_conversation', $args), qr/"text":\Q$want\E[,}]/, 'get_conversation sends it so';
    is_deeply [map { $_->{snippet} } @{$h->search_conversations({query => 'running', roles => ['assistant']})}],
      ["Running it $marker"], 'and search_conversations finds it so';
    is_deeply \@warnings, [], 'reading it warns about nothing';
  };
}

done_testing;
