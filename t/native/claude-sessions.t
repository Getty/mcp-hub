#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(curfile tempdir path);
use Mojo::JSON qw(encode_json);
use MCP::Hub::Native::ClaudeSessions;

plan skip_all => 'symlink not supported here' unless eval { symlink('', "@{[tempdir]}/x"); 1 };

# The session picker uses mtime ("the newest .jsonl"); make it deterministic
# regardless of how the fixtures were copied into place. The mtimes are set on
# a copy, so the fixtures in the checkout keep theirs and a run beside this one
# sees no change; $copy holds the tempdir until the test ends.
my $fixtures = curfile->sibling('..', 'fixtures', 'claude');
my %mtime    = map { ("$_" => (stat $_)[9]) } @{$fixtures->list_tree};
my $copy     = tempdir;
for my $file (@{$fixtures->list_tree}) {
  my $to = $copy->child(@{$file->to_rel($fixtures)->to_array});
  $to->dirname->make_path;
  $file->copy_to($to);
}
my $root   = $copy->to_string;
my $proj_a = $copy->child('projects', '-home-tester-proj-a');
utime time - 100, time - 100, $proj_a->child('a1.jsonl')->to_string or die "a1.jsonl: $!";
utime time,       time,       $proj_a->child('a2.jsonl')->to_string or die "a2.jsonl: $!";

# Build a fake /proc: pid 4242 is `claude` with cwd /home/tester/proj-a,
# pid 9999 is something else, pid 4243 is `claude` in an unknown directory.
my $proc = tempdir;
sub fake_proc ($pid, $comm, $cwd = undef, $in = $proc) {
  my $dir = path($in, $pid)->make_path;
  $dir->child('comm')->spew("$comm\n");
  symlink($cwd, "@{[$dir->child('cwd')]}") if defined $cwd;
}
fake_proc(4242, 'claude', '/home/tester/proj-a');
fake_proc(9999, 'node',   '/home/tester/proj-a');
fake_proc(4243, 'claude', '/home/tester/elsewhere');

my $s = MCP::Hub::Native::ClaudeSessions->new(root => $root, proc_root => "$proc");

subtest 'discovers claude processes only' => sub {
  my $sessions = $s->list_running_sessions;
  is scalar(@$sessions), 2, 'two claude processes (node ignored)';
  is_deeply [map { $_->{pid} } @$sessions], [4242, 4243], 'sorted by pid';
};

subtest 'matches the session file for a known cwd' => sub {
  my ($session) = grep { $_->{pid} == 4242 } @{$s->list_running_sessions};
  is $session->{cwd},        '/home/tester/proj-a', 'cwd read from /proc';
  is $session->{project},    '/home/tester/proj-a', 'project is the cwd';
  is $session->{session_id}, 'a2',                  'newest session file matched';
  is $session->{git_branch}, 'feature/widget',      'git branch from the session';
  is $session->{last_prompt}, 'Debug the widget renderer', 'last user prompt';
};

subtest 'unknown cwd yields a bare row' => sub {
  my ($session) = grep { $_->{pid} == 4243 } @{$s->list_running_sessions};
  is $session->{cwd}, '/home/tester/elsewhere', 'cwd still reported';
  is $session->{session_id}, undef, 'no session file, no session id';
};

# A pid is read from /proc as text; it goes out as a JSON number however many
# sessions run, in the tool's text and its structured content alike.
subtest 'pid is a number on the wire' => sub {
  my $one = tempdir;
  fake_proc(4242, 'claude', '/home/tester/proj-a', $one);
  for my $case (['one session', $one, [4242]], ['two sessions', $proc, [4242, 4243]]) {
    my ($name, $in, $pids) = @$case;
    my $server = MCP::Hub::Native::ClaudeSessions->new(root => $root, proc_root => "$in");
    my ($tool) = @{$server->tools};
    my $result = $tool->code->($tool, {});
    is_deeply [$result->{content}[0]{text} =~ /"pid":([^,}]*)/g], $pids, "$name: a number in the text";
    is_deeply [encode_json($result->{structuredContent}) =~ /"pid":([^,}]*)/g], $pids,
      "$name: a number in the structured content";
  }
};

my %now = map { ("$_" => (stat $_)[9]) } @{$fixtures->list_tree};
is_deeply \%now, \%mtime, 'the fixtures in the checkout keep their mtimes';

done_testing;
