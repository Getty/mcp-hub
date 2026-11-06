#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(tempdir);
use Mojo::JSON qw(encode_json);
use MCP::Hub::Native::ClaudeHistory;
use MCP::Hub::Native::ClaudeSessions;

plan skip_all => 'symlink not supported here' unless eval { symlink('', "@{[tempdir]}/x"); 1 };

# A block of a message's content can be JSON that is not an object -- "x", 1,
# null, [1]. It is skipped, as ClaudeHistory skips it: list_running_sessions
# still answers, with the text of the other blocks. Each result is compared
# with the same session written without those blocks, and the last prompt with
# the text ClaudeHistory gives for the same line.
my @odd = ('x', 1, 1.5, undef, \1, \0, [1], ['text'], [{type => 'text', text => 'inside an array'}]);

my $t = 0;
sub rec (%f) {
  my %r = (sessionId => 'blocks', cwd => '/home/tester/blocks', gitBranch => 'main', uuid => "u$t",
    timestamp => sprintf('2026-10-05T08:%02d:%02dZ', $t / 60, $t % 60), %f);
  $t++;
  return encode_json(\%r);
}
sub text (@t) { map { {type => 'text', text => $_} } @t }
sub user (@content) { rec(type => 'user', message => {role => 'user', content => [@content]}) }
sub assistant ($text) { rec(type => 'assistant', message => {role => 'assistant', content => [text($text)]}) }

# The same session with and without the odd blocks: the user line with them
# is the first line, which the head scan reads, or the last, which the tail
# scan reads.
my %cases = (
  'the head' => {
    with    => sub { user($odd[0], text('the first'), @odd[1 .. 4], text('prompt'), @odd[5 .. 8]), assistant('an answer') },
    without => sub { user(text('the first', 'prompt')), assistant('an answer') },
    prompt  => "the first\nprompt",
  },
  'the tail' => {
    with    => sub { user(text('first')), assistant('an answer'), user(@odd, text('the last', 'prompt'), $odd[0]) },
    without => sub { user(text('first')), assistant('an answer'), user(text('the last', 'prompt')) },
    prompt  => "the last\nprompt",
  },
  'a single line' => {
    with    => sub { user(text('only'), @odd) },
    without => sub { user(text('only')) },
    prompt  => 'only',
  },
  'only odd blocks' => {
    with    => sub { user(text('first')), user(@odd) },
    without => sub { user(text('first')), user() },
    prompt  => '',
  },
);

# Each session's lines are numbered from 0, so both copies get the same
# timestamps and uuids.
sub session ($lines) {
  $t = 0;
  my $root = tempdir;
  $root->child('projects', '-home-tester-blocks')->make_path->child('blocks.jsonl')->spew(join '', map {"$_\n"} $lines->());
  return $root;
}

sub running ($root) {
  my $proc = tempdir;
  my $pid  = $proc->child('4242')->make_path;
  $pid->child('comm')->spew("claude\n");
  symlink('/home/tester/blocks', $pid->child('cwd')->to_string) or die $!;
  return MCP::Hub::Native::ClaudeSessions->new(root => "$root", proc_root => "$proc")->list_running_sessions;
}

for my $name (sort keys %cases) {
  subtest "odd blocks in $name" => sub {
    my $case = $cases{$name};
    my $with = session($case->{with});

    my $got = eval { running($with) };
    is $@, '', 'list_running_sessions answers';
    is_deeply $got, running(session($case->{without})), 'as without the odd blocks';
    is $got->[0]{last_prompt}, $case->{prompt}, 'the last prompt is the text of the other blocks';

    my $conv = MCP::Hub::Native::ClaudeHistory->new(root => "$with")->get_conversation({session_id => 'blocks', roles => ['user']});
    is $got->[0]{last_prompt}, $conv->{entries}[-1]{text}, 'as ClaudeHistory gives it';
  };
}

done_testing;
