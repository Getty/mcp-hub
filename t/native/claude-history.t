#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(curfile);
use MCP::Hub::Native::ClaudeHistory;

my $root = curfile->sibling('..', 'fixtures', 'claude')->to_string;
my $h    = MCP::Hub::Native::ClaudeHistory->new(root => $root);

subtest 'list_projects' => sub {
  my $projects = $h->list_projects;
  is scalar(@$projects), 2, 'two projects';
  is $projects->[0]{project}, '/home/tester/proj-a', 'newest-active project first';
  is $projects->[0]{sessions}, 2, 'proj-a has two sessions';
  is $projects->[1]{project}, '/home/tester/proj-b', 'proj-b second';
  is $projects->[1]{sessions}, 1, 'proj-b has one session';
};

subtest 'list_sessions newest first' => sub {
  my $sessions = $h->list_sessions;
  is scalar(@$sessions), 3, 'three sessions total';
  is $sessions->[0]{session_id}, 'a2', 'a2 newest';
  is $sessions->[0]{first_prompt}, 'Debug the widget renderer', 'first prompt from block content';
  is $sessions->[0]{git_branch}, 'feature/widget', 'git branch captured';
  is $sessions->[-1]{session_id}, 'a1', 'a1 oldest';
  is $sessions->[-1]{title}, 'Kubernetes pods help', 'ai-title captured';
  is $sessions->[-1]{messages}, 2, 'message count';
};

subtest 'list_sessions filters' => sub {
  my $only_a = $h->list_sessions({project => '/home/tester/proj-a'});
  is_deeply [map { $_->{session_id} } @$only_a], ['a2', 'a1'], 'project filter';

  my $since = $h->list_sessions({since => '2026-08-11'});
  is_deeply [map { $_->{session_id} } @$since], ['a2', 'b1'], 'since filter excludes the 08-10 session';

  my $limited = $h->list_sessions({limit => 1});
  is scalar(@$limited), 1, 'limit honoured';
};

subtest 'search_conversations' => sub {
  my $hits = $h->search_conversations({query => 'kubernetes'});
  is scalar(@$hits), 2, 'two user matches for kubernetes';
  my %by = map { $_->{session_id} => $_ } @$hits;
  ok $by{a1}, 'a1 matched';
  ok $by{b1}, 'b1 matched';
  like $by{a1}{snippet}, qr/kubernetes/i, 'snippet contains the term';
  is $by{a1}{role}, 'user', 'default role is user';

  my $assistant = $h->search_conversations({query => 'help', roles => ['assistant']});
  is scalar(@$assistant), 1, 'assistant role search';
  is $assistant->[0]{session_id}, 'a1', 'found in a1 assistant text';
};

subtest 'get_conversation' => sub {
  my $conv = $h->get_conversation({session_id => 'a1'});
  is $conv->{total}, 2, 'two messages';
  ok !${$conv->{has_more}}, 'no more';
  is $conv->{entries}[0]{role}, 'user', 'first is user';
  like $conv->{entries}[1]{text}, qr/\[tool_use Bash\]/, 'tool_use rendered';

  my $page = $h->get_conversation({session_id => 'a1', offset => 1, limit => 1});
  is scalar(@{$page->{entries}}), 1, 'offset+limit paginates';
  is $page->{entries}[0]{role}, 'assistant', 'second entry';

  my $missing = $h->get_conversation({session_id => 'nope'});
  is $missing->{total}, 0, 'unknown session is empty';
};

# Claude Code names a session's file <session_id>.jsonl, as a1 and a2 are named
# here; b1 sits in sess-b1.jsonl on purpose, so the scan of the other files is
# covered too.
subtest 'get_conversation finds the file of a session' => sub {
  my $reads = sub ($session_id) {
    my @read;
    no warnings 'redefine';
    my $open = \&Mojo::File::open;
    local *Mojo::File::open = sub ($p, @args) { push @read, "$p"; $open->($p, @args) };
    my $conv = MCP::Hub::Native::ClaudeHistory->new(root => $root)->get_conversation({session_id => $session_id});
    return $conv->{total}, [map { s{^\Q$root\E/projects/}{}r } @read];
  };

  my ($total, $read) = $reads->('a2');
  is $total, 2, 'a session in the file named after it';
  is_deeply $read, ['-home-tester-proj-a/a2.jsonl'], 'is read from that file alone';

  ($total, $read) = $reads->('b1');
  is $total, 2, 'a session in a file named otherwise';
  is $read->[-1], '-home-tester-proj-b/sess-b1.jsonl', 'is read from it';
  is_deeply [grep { !/sess-b1/ } @$read], ['-home-tester-proj-a/a1.jsonl', '-home-tester-proj-a/a2.jsonl'],
    'after the other files';
};

subtest 'metadata cache' => sub {
  # Two identical calls should reuse the cache; assert the cache is populated.
  $h->list_sessions;
  ok scalar(keys %{$h->meta_cache}) >= 3, 'metadata cached per file';
};

done_testing;
