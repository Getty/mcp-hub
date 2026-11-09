#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(tempdir);
use Mojo::JSON qw(decode_json encode_json);
use MCP::Hub::Native::ClaudeHistory;

# since and until compare times as the instants they are, in list_sessions,
# search_conversations and list_prompts alike. Claude Code writes the times of a
# session file with milliseconds (2026-11-09T00:00:00.500Z) and the prompt
# history's in epoch milliseconds, while a bound is often written without them
# (2026-11-09T10:00:00Z) or with an offset; as strings these do not sort as
# their times do -- "." sorts before "Z" -- so a time in the first second of a
# since was dropped, one in the second after a full until kept. The same
# moments are written here as a session file each and as a line of the prompt
# history, named alike; "late" is written with an offset in its session file
# (2026-11-10T01:00:00+02:00 is 2026-11-09T23:00:00Z), "junk" holds a time
# that is no time and "none" none at all.
my $day = 1794182400000;    # 2026-11-09T00:00:00Z
my @moments = (
  [before  => '2026-11-08T23:59:59.999Z',  $day - 1],
  [start   => '2026-11-09T00:00:00.500Z',  $day + 500],
  [ten     => '2026-11-09T10:00:00.000Z',  $day + 36_000_000],
  [tenhalf => '2026-11-09T10:00:00.500Z',  $day + 36_000_500],
  [late    => '2026-11-10T01:00:00+02:00', $day + 82_800_000],
  [end     => '2026-11-09T23:59:59.999Z',  $day + 86_399_999],
  [next    => '2026-11-10T00:00:00.000Z',  $day + 86_400_000],
  [junk    => 'yesterday',                 'yesterday'],
  [none    => undef,                       undef],
);
my @all = sort map { $_->[0] } @moments;

my $root     = tempdir;
my $projects = $root->child('projects', '-home-tester-range')->make_path;
for my $moment (@moments) {
  my ($name, $iso, $ms) = @$moment;
  $projects->child("$name.jsonl")->spew(encode_json({type => 'user', sessionId => $name, cwd => '/home/tester/range',
    uuid => "$name-1", (defined $iso ? (timestamp => $iso) : ()), message => {role => 'user', content => "hello $name"}})
    . "\n");
}
$root->child('history.jsonl')->spew(join '', map {
  my ($name, undef, $ms) = @$_;
  encode_json({display => "hello $name", pastedContents => {}, project => '/home/tester/range', sessionId => $name,
    (defined $ms ? (timestamp => $ms) : ())}) . "\n";
} @moments);
my $h = MCP::Hub::Native::ClaudeHistory->new(root => "$root");

my @tools = qw(list_sessions search_conversations list_prompts);

# What a tool answers, as the hub sends it: the names of the sessions or
# prompts it lists, sorted -- the filters, not the order, are tested here -- or
# {error => TEXT} for an error result.
sub call ($server, $name, $args = {}) {
  my ($tool) = grep { $_->name eq $name } @{$server->tools};
  my $result = $tool->code->($tool, {($name eq 'search_conversations' ? (query => 'hello') : ()), %$args, limit => 100});
  return {error => $result->{content}[0]{text}} if $result->{isError};
  my $data = decode_json($result->{content}[0]{text});
  is_deeply decode_json(encode_json($result->{structuredContent})), {results => $data},
    "$name: the structured content is the text";
  return [sort map { $_->{session_id} } @$data];
}
sub without (@names) {
  my %out = map { $_ => 1 } @names;
  return [grep { !$out{$_} } @all];
}

# Each tool, for each of these bounds, keeps the moments listed.
sub kept ($label, $args, $kept) {
  is_deeply call($h, $_, $args), $kept, "$_: $label" for @tools;
}

subtest 'the moments are those of the session files' => sub {
  my %iso = map { $_->{session_id} => $_->{timestamp} } @{$h->list_prompts({limit => 100})};
  is_deeply [map { $iso{$_->[0]} } grep { $_->[1] && $_->[1] =~ /Z\z/ } @moments],
    [map { $_->[1] } grep { $_->[1] && $_->[1] =~ /Z\z/ } @moments],
    'list_prompts sends the time of each prompt as its session file holds it';
  kept('without since or until, all of them', {}, \@all);
};

subtest 'a date is a whole day in UTC' => sub {
  kept('since a day: from its first millisecond, in its first second too', {since => '2026-11-09'}, without('before'));
  kept('until a day: to its last millisecond, not the next day', {until => '2026-11-09'}, without('next'));
  kept('both: the day', {since => '2026-11-09', until => '2026-11-09'}, without('before', 'next'));
  kept('a time with an offset falls on its day in UTC', {since => '2026-11-10'}, ['junk', 'next', 'none']);
};

subtest 'a full time is an instant, both ends included' => sub {
  my $from_ten = without(qw(before start));
  my $to_ten   = [sort qw(before start ten junk none)];
  kept('since a time without a fraction keeps that instant with one', {since => '2026-11-09T10:00:00Z'}, $from_ten);
  kept('until a time without a fraction drops the half second after it', {until => '2026-11-09T10:00:00Z'}, $to_ten);
  kept('since a time with an offset: its instant in UTC', {since => '2026-11-09T12:00:00+02:00'}, $from_ten);
  kept('until a time with an offset: its instant in UTC', {until => '2026-11-09T12:00:00+02:00'}, $to_ten);
  kept('an offset without a colon, west of UTC', {until => '2026-11-09T04:30:00-0530'}, $to_ten);
  kept('a space for the T', {since => '2026-11-09 10:00:00Z'}, $from_ten);
  kept('a fraction of any length', {until => '2026-11-09T10:00:00.0001Z'}, $to_ten);
  kept('no seconds and no offset: UTC', {until => '2026-11-09T10:00'}, $to_ten);
  kept('both at once', {since => '2026-11-09T00:00:00.500Z', until => '2026-11-09T23:59:59.999Z'},
    without(qw(before next)));
};

subtest 'a time that is no time passes, as none does' => sub {
  for my $value (1e5, 'yesterday', '2026-02-30T10:00:00Z') {
    my $other = tempdir;
    $other->child('projects', '-home-tester-x')->make_path->child('x.jsonl')->spew(encode_json({type => 'user',
      sessionId => 'x', cwd => '/home/tester/x', timestamp => $value, message => {role => 'user', content => 'hello'}})
      . "\n");
    my $x = MCP::Hub::Native::ClaudeHistory->new(root => "$other");
    for my $args ({since => '2026-11-09'}, {until => '2026-11-09'}) {
      is_deeply call($x, $_, $args), ['x'], "$_: a session of the time $value, " . encode_json($args)
        for qw(list_sessions search_conversations);
    }
  }
};

subtest 'a since or until that is no date or time is an error' => sub {
  my $no_file = MCP::Hub::Native::ClaudeHistory->new(root => "@{[tempdir]}");
  for my $case (
    [{since => 'yesterday'},                         'since "yesterday"'],
    [{since => '2026-11-09', until => '2026-13-01'}, 'until "2026-13-01"'],
    [{until => '2026-11-09T10:00:00+24:00'},         'until "2026-11-09T10:00:00+24:00"'],
    [{since => ''},                                  'since ""'],
    [{since => 20261109},                            'since 20261109'],
  ) {
    my ($args, $named) = @$case;
    my $error = "claude-history: $named is not a date (YYYY-MM-DD) or an ISO 8601 time";
    for my $tool (@tools) {
      is_deeply call($h, $tool, $args), {error => $error}, "$tool: " . encode_json($args);
      is $h->$tool({%$args}), undef, "$tool, as a method: undef";
    }
    is_deeply call($no_file, 'list_prompts', $args), {error => $error}, 'list_prompts without its file too';
  }
  kept('null is no bound', {since => undef, until => undef}, \@all);
};

done_testing;
