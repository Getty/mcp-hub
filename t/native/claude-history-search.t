#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(tempdir);
use Mojo::JSON qw(decode_json);
use MCP::Hub::Native::ClaudeHistory;

binmode Test::More->builder->$_, ':encoding(UTF-8)' for qw(output failure_output todo_output);

# search_conversations tests a printable-ASCII needle against the raw JSON line
# before decoding it. These lines are written raw, so the test controls every
# escape; $U is JSON's backslash-u escape prefix.
my $U = "\x5Cu";
my $n = 0;
sub ts () { sprintf '2026-09-01T10:%02d:00Z', $n++ }
sub user ($content) { qq({"type":"user","sessionId":"edge","cwd":"/home/tester/edge","uuid":"u$n","timestamp":"@{[ts]}","message":{"role":"user","content":$content}}) }
sub assistant ($content) { qq({"type":"assistant","sessionId":"edge","uuid":"u$n","timestamp":"@{[ts]}","message":{"role":"assistant","content":$content}}) }

my @edge = (
  user(q("He said \"hello\" to me")),                     # escaped quotes
  user(q("first line\nsecond line")),                     # escaped newline
  user(qq("Gr\xC3\xBC\xC3\x9Fe aus der Stra\xC3\x9Fe, caf\xC3\xA9")),    # raw UTF-8
  user(qq("caf${U}00e9 cr${U}00e8me")),                   # non-ASCII, escaped
  user(qq("${U}0041BC tool")),                             # ASCII, escaped: "ABC tool"
  user(q("edit lib\/MCP\/Hub.pm")),                       # escaped slash
  user(qq("\xE2\x84\xAAelvin scale")),                    # KELVIN SIGN, raw: lc is "kelvin"
  user(qq("${U}212Aelvin units")),                         # KELVIN SIGN, escaped
  user(qq("TAKS\xC4\xB0 stand")),                          # U+0130, raw: lc is "taksi\x{307}"
  user(qq("${U}0130stanbul")),                             # U+0130, escaped
  assistant(q([{"type":"text","text":"Let me look"},{"type":"tool_use","id":"t1","name":"Bash","input":{}}])),
  user(q([{"type":"tool_result","tool_use_id":"t1","content":"exit 0"}])),
  user('1e5'),                                             # a number, stringified "100000"
  user('true'),                                            # a boolean, stringified "1"
  assistant(q([{"type":"text","text":42}])),               # a number as block text
  assistant(q([{"type":"text","text":7e7}])),              # block text stringified "70000000"
  assistant(q([{"type":"tool_use","id":"t2","name":3e3,"input":{}}])),    # tool name "3000"
  assistant(q([{"type":"text","text":"Nameless"},{"type":"tool_use","id":"t3","input":{}}])),    # "[tool_use]"
  user('false'),                                           # a boolean, stringified "0"
  user('null'),                                            # no text
  user(q({"text":"hash(0x1) in an object"})),              # an object as content: no text
  user(q([{"type":"text","text":{"k":1}}])),               # an object as block text: no text
  assistant(q([{"type":"text","text":["array",1]}])),      # an array as block text: no text
  assistant(q([{"type":"tool_use","id":"t4","name":{"n":"Bash"},"input":{}}])),    # "[tool_use]"
  assistant(q([{"type":"tool_use","id":"t5","name":["x"],"input":{}}])),           # "[tool_use]"
  assistant(q([{"type":"text","text":1e20}])),             # block text stringified "1e+20"
  user('15e-1'),                                           # a number, stringified "1.5"
  user('1e-7'),                                            # a number, stringified "1e-07"
  user('1e999'),                                           # a number too large, stringified "Inf"
  assistant(q([{"type":"tool_use","id":"t6","name":-1e999,"input":{}}])),          # "[tool_use -Inf]"
  user(q("path C:\\\\Users\\\\tester")),                 # escaped backslashes
  user(q("the needle is only in a field","x":"zanzibar")), # a raw hit that is no text hit
  '{"type":"user", not json zanzibar',
  user(q("plain zanzibar quux")),
  assistant(q([{"type":"text","text":"plain zanzibar answer"}])),
);

my $root = tempdir;
my $dir  = $root->child('projects', '-home-tester-edge')->make_path;
$dir->child('edge.jsonl')->spew(join("\n", @edge) . "\n");

# Today's search, decoding every line: the oracle the raw test must agree with.
sub decode_all ($h, $args) {
  my $needle = lc $args->{query};
  my %roles  = map { $_ => 1 } @{$args->{roles} // ['user']};
  my @hits;
  for my $s (@{$h->_sessions({limit => 1e9})}) {
    for my $line (split /\n/, Mojo::File->new($s->{_file})->slurp) {
      my $rec = eval { decode_json($line) } or next;
      my $type = $rec->{type} // '';
      next unless ($type eq 'user' || $type eq 'assistant') && $roles{$type};
      my $text = MCP::Hub::Native::ClaudeHistory::_text($rec->{message}) // '';
      next unless (my $pos = index(lc $text, $needle)) >= 0;
      push @hits, {session_id => $s->{session_id}, project => $s->{project}, timestamp => $rec->{timestamp},
        role => $type, snippet => MCP::Hub::Native::ClaudeHistory::_snippet($text, $pos, length $args->{query})};
    }
  }
  return \@hits;
}

my $h = MCP::Hub::Native::ClaudeHistory->new(root => "$root");

my @queries = (
  'hello', 'said "hello', 'second line', "line\nsecond", 'grüße', 'café', 'caf', 'crème', 'abc', 'lib/mcp',
  'kelvin', "\x{212A}elvin", 'taksi', 'i', 'use bash', '[tool_use bash]', 'bash]', 'e bash', 'tool_use',
  '[tool_result]', 'tool_result', '100000', '1', '42', '70000000', '3000', 'c:\\users', 'zanzibar', 'ZANZIBAR', 'quux', ' ', '',
  'nameless', '[tool_use]', 'tool_use]', 'e]', '0', 'null', 'hash(0x', 'hash', '0x1', 'in an object',
  'array(0x', 'array', '(0x', '(', ')', 'x', 'y', 's', 'r', 'b', 'd', 'k', 'n', 'e+', '1e+20', '1.5', 'e-0',
  'inf', '-inf', 'nan',
);
for my $q (@queries) {
  for my $roles (['user'], ['user', 'assistant']) {
    my $args = {query => $q, roles => $roles, limit => 1e9};
    my $name = $q =~ s/\n/\\n/gr;
    is_deeply $h->search_conversations($args), decode_all($h, $args), "'$name' in [@$roles] matches decoding every line";
  }
}

subtest 'words that only match after decoding still match' => sub {
  my %count = map {
    my ($q, @roles) = @$_;
    ("$q" => scalar @{$h->search_conversations({query => $q, roles => [@roles ? @roles : 'user']})});
  } (['abc'], ['lib/mcp'], ['kelvin'], ['taksi'], ['café'], ['use bash', 'assistant'], ['[tool_result]'],
     ['100000'], ['42', 'assistant'], ['70000000', 'assistant'], ['3000', 'assistant'], ['zanzibar'],
     ['nameless', 'assistant'], ['hash(0x'], ['(0x', 'assistant'], ['1e+20', 'assistant'], ['1.5'], ['e-0'],
     ['inf'], ['-inf', 'assistant']);
  is $count{abc},             1, 'an escaped ASCII letter';
  is $count{'lib/mcp'},       1, 'an escaped slash';
  is $count{kelvin},          2, 'KELVIN SIGN, raw and escaped';
  is $count{taksi},           1, 'U+0130';
  is $count{'café'},          2, 'non-ASCII, raw and escaped';
  is $count{'use bash'},      1, 'across the tool_use marker';
  is $count{'[tool_result]'}, 1, 'the tool_result marker';
  is $count{100000},          1, 'a number stringified';
  is $count{42},              1, 'a number as block text';
  is $count{70000000},        1, 'a number as block text, stringified';
  is $count{3000},            1, 'a number as tool name, stringified';
  is $count{zanzibar},        1, 'a plain word, not the field-only or broken line';
  is $count{nameless},        1, 'next to a tool_use marker without a name';
  is $count{'hash(0x'},       0, 'not an object as content or block text, which is no text';
  is $count{'(0x'},           0, 'not an object or array as block text or name, which is no text';
  is $count{'1e+20'},         1, 'a number as block text, stringified with an exponent';
  is $count{'1.5'},           1, 'a number stringified with a point';
  is $count{'e-0'},           1, 'a number stringified with a negative exponent';
  is $count{inf},             1, 'a number too large, stringified';
  is $count{'-inf'},          1, 'a number too large as tool name, stringified';
};

subtest 'only candidate lines are decoded' => sub {
  my $plain = tempdir;
  my $pd    = $plain->child('projects', '-home-tester-plain')->make_path;
  $n = 0;
  my @lines = map { user(qq("ordinary prompt number $_")) } 1 .. 40;
  $lines[17] = user(q("this one has the needle in it"));
  $lines[23] = user(qq("${U}0041 escaped, decoded for any word"));
  $lines[30] = user(q("a path a\/b, decoded for a word with a slash"));
  $lines[31] = user('1e5');
  $pd->child('plain.jsonl')->spew(join("\n", @lines) . "\n");

  my $p = MCP::Hub::Native::ClaudeHistory->new(root => "$plain");
  $p->list_sessions;    # fill the metadata cache, so only the search decodes

  my $decoded = 0;
  no warnings 'redefine';
  local *MCP::Hub::Native::ClaudeHistory::decode_json = sub { $decoded++; decode_json(@_) };
  my $count = sub ($q) { $decoded = 0; my $hits = $p->search_conversations({query => $q}); ($decoded, scalar @$hits) };

  is_deeply [$count->('needle')],      [2, 1],  'a raw ASCII needle decodes the hit and the escaped line only';
  is_deeply [$count->('NEEDLE')],      [2, 1],  'the raw test lowercases like the search';
  is_deeply [$count->('absent')],      [1, 0],  'a missing needle decodes only the escaped line';
  is_deeply [$count->('a/b')],         [2, 1],  'a needle with a slash decodes the escaped slash too';
  is_deeply [$count->('100000')],      [2, 1],  'a needle that could be a number decodes the number too';
  is_deeply [$count->('nëedle')],      [40, 0], 'a non-ASCII needle decodes every line';
  is_deeply [$count->('the "needle')], [40, 0], 'a needle with a quote decodes every line';
  is_deeply [$count->('back\\slash')], [40, 0], 'a needle with a backslash decodes every line';
  is_deeply [$count->("needle\n")],    [40, 0], 'a needle with a control character decodes every line';
  is_deeply [$count->('use bash')],    [40, 0], 'a needle that can match a tool_use marker decodes every line';
  is_deeply [$count->('[x')],          [40, 0], 'a needle with a bracket decodes every line';
};

done_testing;
