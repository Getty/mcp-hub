use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(curfile tempdir path);
use MCP::Hub::Native::ClaudeSessions;

plan skip_all => 'symlink not supported here' unless eval { symlink('', "@{[tempdir]}/x"); 1 };

my $root = curfile->sibling('..', 'fixtures', 'claude')->to_string;

# The session picker uses mtime ("the newest .jsonl"); make it deterministic
# regardless of how the fixtures were copied into place.
my $proj_a = curfile->sibling('..', 'fixtures', 'claude', 'projects', '-home-tester-proj-a');
utime time - 100, time - 100, $proj_a->child('sess-a1.jsonl')->to_string;
utime time,       time,       $proj_a->child('sess-a2.jsonl')->to_string;

# Build a fake /proc: pid 4242 is `claude` with cwd /home/tester/proj-a,
# pid 9999 is something else, pid 4243 is `claude` in an unknown directory.
my $proc = tempdir;
sub fake_proc ($pid, $comm, $cwd = undef) {
  my $dir = path($proc, $pid)->make_path;
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

done_testing;
