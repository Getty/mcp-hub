#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;

# Opt-in: the one real-world class the forked workers were built for. It needs
# MCP::Wiki and Git::Raw, a git binary, and MCP_HUB_TEST_WIKI=1. The wiki is a
# throwaway git repository in a temp dir; nothing else is touched.
plan skip_all => 'set MCP_HUB_TEST_WIKI=1 to run the MCP::Wiki live test' unless $ENV{MCP_HUB_TEST_WIKI};
plan skip_all => 'forked class workers need Linux (/proc/self/fd)' unless -d '/proc/self/fd';
for my $module (qw(MCP::Wiki::Server Git::Raw)) {
  plan skip_all => "$module is not installed" unless eval "require $module; 1";
}
plan skip_all => 'git is not installed' unless system('git --version >/dev/null 2>&1') == 0;

use Test::Mojo;
use Mojo::File    qw(tempdir);
use Mojo::Promise;
use MCP::Client;
use MCP::Hub;
use Time::HiRes qw(time);

sub git ($wiki, @args) { system('git', '-C', "$wiki", @args) == 0 or die "git @args failed\n" }

sub wait_until ($cond, $timeout = 8) {
  my $deadline = time + $timeout;
  Mojo::Promise->timer(0.05)->wait until $cond->() || time > $deadline;
  return $cond->();
}

my $dir  = tempdir;
my $wiki = $dir->child('wiki')->make_path;
git($wiki, 'init', '-q');
git($wiki, 'config', 'user.name',  'mcp-hub test');
git($wiki, 'config', 'user.email', 'test@localhost');
$wiki->child('index.md')->spew("# Index\n\nThe start page.\n\n## Notes\n\nNothing yet.\n");
git($wiki, 'add', 'index.md');
git($wiki, 'commit', '-q', '-m', 'initial');

my $app = MCP::Hub->new(hub_config_input => {
  mcpServers => {
    wiki => {class => 'MCP::Wiki::Server', args => {wiki_root => "$wiki", use_git => \1},
             hub => {fork => \1, idle_timeout => 1}},
  },
  hub => {cache_dir => $dir->child('cache')->to_string},
});
my $t  = Test::Mojo->new($app);
my $up = $app->upstreams_by_name->{wiki};

my $base = $t->ua->server->url->to_string;
$base =~ s{/$}{};
my $c = MCP::Client->new(ua => $t->ua, url => "$base/wiki");

is $up->type, 'fork', 'the wiki is a forked class';
is $up->stats->{pid}, undef, 'no worker after startup';

my $names = [map { $_->{name} } @{$c->list_tools->{tools}}];
ok scalar(grep { $_ eq 'write_page' } @$names) && scalar(grep { $_ eq 'get_section_history' } @$names),
  'tools/list has the wiki tools (' . scalar(@$names) . ')';
is $up->stats->{pid}, undef, 'and forked nothing';

my $res = $c->call_tool('write_page', {
  page    => 'index.md',
  content => "# Index\n\nThe start page, rewritten.\n\n## Notes\n\nFirst note.\n",
  reason  => 'write_page through a forked worker',
});
ok !$res->{isError}, 'write_page succeeds' or diag $res->{content}[0]{text};
my $pid = $up->stats->{pid};
ok $pid && $pid != $$, 'in a worker of its own';

$res = $c->call_tool('update_paragraph', {
  page => 'index.md', heading_path => 'Index#Notes', content => "Second note.\n", reason => 'update_paragraph',
});
ok !$res->{isError}, 'update_paragraph succeeds' or diag $res->{content}[0]{text};
is $up->stats->{pid}, $pid, 'in the same worker';

my $log = `git -C $wiki log --format=%s`;
like $log, qr/write_page through a forked worker/, 'the write is committed with its reason';
like $log, qr/update_paragraph/, 'and so is the next';

$res = $c->call_tool('get_section_history', {page => 'index.md', heading_path => 'Index#Notes'});
ok !$res->{isError}, 'get_section_history succeeds' or diag $res->{content}[0]{text};
cmp_ok $res->{structuredContent}{count} // 0, '>=', 2, 'and sees the history of the section';

ok wait_until(sub { $up->state eq 'stopped' }), 'the idle worker is stopped';
ok wait_until(sub { !kill 0, $pid }), 'and gone';
is scalar(@{$c->list_tools->{tools}}), scalar(@$names), 'tools/list still answers';
is $up->stats->{pid}, undef, 'without a worker';

$app->shutdown_p->wait;
done_testing;
