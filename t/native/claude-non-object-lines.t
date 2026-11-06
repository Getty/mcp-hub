#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(path tempdir);
use Mojo::JSON qw(encode_json);
use MCP::Hub::Native::ClaudeHistory;
use MCP::Hub::Native::ClaudeSessions;

# A line of a session file can be JSON that is not an object -- [1], 42, "x".
# It is skipped like a line that is not JSON at all: every tool still answers,
# and the session's other lines still count. Each result is compared with the
# same session written without those lines.
my @odd = ('[1]', '42', '"x"', 'true', 'null', '["needle"]', '"a needle"', '[{"type":"user","message":{"content":"needle"}}]');

my $t = 0;
sub rec (%f) {
  my %r = (sessionId => 'odd', cwd => '/home/tester/odd', gitBranch => 'main', uuid => "u$t",
    timestamp => sprintf('2026-10-03T08:%02d:%02dZ', $t / 60, $t % 60), %f);
  $t++;
  return encode_json(\%r);
}
sub user ($text) { rec(type => 'user', message => {role => 'user', content => $text}) }
sub assistant ($text) { rec(type => 'assistant', message => {role => 'assistant', content => [{type => 'text', text => $text}]}) }

# The odd lines come first -- before the head fields are known --, between the
# others and last, after the last prompt.
my @lines = (
  @odd[0, 1], user('first prompt with a needle'), $odd[2], assistant('an answer'), @odd[3 .. 5],
  rec(type => 'ai-title', aiTitle => 'Odd lines'), assistant('a needle in the answer'), $odd[6],
  user('the last prompt'), @odd[7, 0, 1, 2],
);
my %odd = map { $_ => 1 } @odd;

my ($with, $without) = (tempdir, tempdir);
my %file;
sub write_lines ($root, @l) {
  my $file = $root->child('projects', '-home-tester-odd')->make_path->child('odd.jsonl');
  $file->spew(join '', map {"$_\n"} @l);
  return $file;
}
$file{$with}    = write_lines($with,    @lines);
$file{$without} = write_lines($without, grep { !$odd{$_} } @lines);
sub append ($root, @l) { open my $fh, '>>:raw', "$file{$root}" or die $!; print {$fh} map {"$_\n"} @l; close $fh }

sub answers ($name, $code) {
  my $got = eval { $code->() };
  is $@, '', "$name answers";
  return $got;
}

my $h     = MCP::Hub::Native::ClaudeHistory->new(root => "$with");
my $clean = sub { MCP::Hub::Native::ClaudeHistory->new(root => "$without") };

subtest 'claude-history' => sub {
  my $needle = {query => 'needle', roles => ['user', 'assistant']};
  is_deeply answers('a cold search_conversations', sub { $h->search_conversations($needle) }),
    $clean->()->search_conversations($needle), 'the same hits as without the odd lines';
  is_deeply answers('a warm search_conversations', sub { $h->search_conversations($needle) }),
    $clean->()->search_conversations($needle), 'the same hits from the cache';

  my $sessions = answers('list_sessions', sub { $h->list_sessions });
  is_deeply $sessions, $clean->()->list_sessions, 'the same sessions as without the odd lines';
  is $sessions->[0]{messages},     4,                            'the other lines count';
  is $sessions->[0]{first_prompt}, 'first prompt with a needle', 'the first prompt';
  is $sessions->[0]{title},        'Odd lines',                  'the title';

  is_deeply answers('list_projects', sub { $h->list_projects }), $clean->()->list_projects, 'the same projects';

  my $conv = answers('get_conversation', sub { $h->get_conversation({session_id => 'odd'}) });
  is_deeply $conv, $clean->()->get_conversation({session_id => 'odd'}), 'the same conversation';
  is $conv->{total}, 4, 'of every message';

  # A grown file: the lines before the offset are searched raw, the new ones
  # read for the metadata too.
  my @more = (user('one more needle'), $odd[5], $odd[1]);
  append($with,    @more);
  append($without, grep { !$odd{$_} } @more);
  is_deeply answers('a search_conversations after an append', sub { $h->search_conversations($needle) }),
    $clean->()->search_conversations($needle), 'the same hits as without the odd lines';
  is_deeply answers('list_sessions after an append', sub { $h->list_sessions }), $clean->()->list_sessions,
    'the same sessions';
};

subtest 'claude-sessions' => sub {
  plan skip_all => 'symlink not supported here' unless eval { symlink('', "@{[tempdir]}/x"); 1 };

  my $running = sub ($root) {
    my $proc = tempdir;
    my $pid  = $proc->child('4242')->make_path;
    $pid->child('comm')->spew("claude\n");
    symlink('/home/tester/odd', $pid->child('cwd')->to_string) or die $!;
    my $s = MCP::Hub::Native::ClaudeSessions->new(root => "$root", proc_root => "$proc");
    return $s->list_running_sessions;
  };

  my $sessions = answers('list_running_sessions', sub { $running->($with) });
  is_deeply $sessions, $running->($without), 'the same as without the odd lines';
  is $sessions->[0]{session_id},  'odd',             'the session id from the head';
  is $sessions->[0]{git_branch},  'main',            'the branch from the head';
  is $sessions->[0]{last_prompt}, 'one more needle', 'the last prompt from the tail';
};

done_testing;
