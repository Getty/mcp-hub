#!/usr/bin/env perl
# Mojo::JSON decodes in pure Perl in this test, whatever is installed: a line
# the natives left to Mojo::JSON would never reach JSON::MaybeXS's backend.
BEGIN { $ENV{MOJO_NO_JSON_XS} = 1 }
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(tempdir);
use JSON::MaybeXS ();
use MCP::Hub::Native::ClaudeHistory;
use MCP::Hub::Native::ClaudeSessions;

# The natives decode the lines of a session file with JSON::MaybeXS, which
# picks Cpanel::JSON::XS where it is installed -- on a history of many
# megabytes the difference between seconds and a fraction of one. Every decode
# of the backend JSON::MaybeXS picked is counted here.
my $backend = JSON::MaybeXS::JSON();
my $decodes = 0;
{
  no strict 'refs';
  no warnings 'redefine';
  my $decode = $backend->can('decode');
  *{"${backend}::decode"} = sub { $decodes++; goto &$decode };
}
ok !Mojo::JSON::JSON_XS, 'Mojo::JSON decodes in pure Perl here';
note "JSON::MaybeXS backend: $backend " . $backend->VERSION;

# Two lines hold a key twice. Mojo::JSON reads such a line, the last value
# winning; so must the natives, although Cpanel::JSON::XS refuses one unless
# told to allow it.
my @lines = (
  '{"type":"user","sessionId":"dup","cwd":"/home/tester/dup","gitBranch":"main","uuid":"u1",'
    . '"timestamp":"2026-10-04T08:00:00Z","message":{"role":"user","content":"a draft"},'
    . '"message":{"role":"user","content":"the first prompt"}}',
  '{"type":"assistant","sessionId":"dup","cwd":"/home/tester/dup","uuid":"u2","timestamp":"2026-10-04T08:00:05Z",'
    . '"message":{"role":"assistant","content":[{"type":"text","text":"an answer"}]}}',
  '{"type":"user","sessionId":"dup","cwd":"/home/tester/dup","uuid":"u3","timestamp":"2026-10-04T08:01:00Z",'
    . '"message":{"role":"user","content":"stale","content":"the last prompt"}}',
);
my $root = tempdir;
$root->child('projects', '-home-tester-dup')->make_path->child('dup.jsonl')->spew(join '', map {"$_\n"} @lines);

subtest 'claude-history' => sub {
  $decodes = 0;
  my $sessions = MCP::Hub::Native::ClaudeHistory->new(root => "$root")->list_sessions;
  ok $decodes, 'list_sessions decodes with JSON::MaybeXS';
  is $sessions->[0]{messages},     3,                  'every line counts';
  is $sessions->[0]{first_prompt}, 'the first prompt', 'the last of a key held twice';

  $decodes = 0;
  my $conv = MCP::Hub::Native::ClaudeHistory->new(root => "$root")->get_conversation({session_id => 'dup'});
  ok $decodes, 'get_conversation decodes with JSON::MaybeXS';
  is_deeply [map { $_->{text} } @{$conv->{entries}}], ['the first prompt', 'an answer', 'the last prompt'],
    'every message, the last of a key held twice';
};

subtest 'claude-sessions' => sub {
  plan skip_all => 'symlink not supported here' unless eval { symlink('', "@{[tempdir]}/x"); 1 };

  my $proc = tempdir;
  my $pid  = $proc->child('4242')->make_path;
  $pid->child('comm')->spew("claude\n");
  symlink('/home/tester/dup', $pid->child('cwd')->to_string) or die $!;

  $decodes = 0;
  my $sessions
    = MCP::Hub::Native::ClaudeSessions->new(root => "$root", proc_root => "$proc")->list_running_sessions;
  ok $decodes, 'list_running_sessions decodes with JSON::MaybeXS';
  is $sessions->[0]{session_id},  'dup',             'the session id from the head';
  is $sessions->[0]{last_prompt}, 'the last prompt', 'the last of a key held twice';
};

done_testing;
