#!/usr/bin/env perl
# A host without a C compiler has no Cpanel::JSON::XS, and JSON::MaybeXS falls
# back to JSON::PP there. Both XS backends are hidden here before anything
# loads them, so JSON::MaybeXS picks JSON::PP and Mojo::JSON decodes in pure
# Perl, as on such a host.
BEGIN {
  unshift @INC, sub {
    my (undef, $file) = @_;
    die "$file hidden by the test\n" if $file eq 'Cpanel/JSON/XS.pm' || $file eq 'JSON/XS.pm';
    return;
  };
}
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(tempdir);
use Mojo::JSON ();
use JSON::MaybeXS ();
use JSON::PP ();
use MCP::Hub::Native::ClaudeHistory;
use MCP::Hub::Native::ClaudeSessions;

binmode Test::More->builder->$_, ':encoding(UTF-8)' for qw(output failure_output todo_output);

is JSON::MaybeXS::JSON(), 'JSON::PP', 'JSON::MaybeXS falls back to JSON::PP';
ok !Mojo::JSON::JSON_XS, 'Mojo::JSON decodes in pure Perl';

# There the natives decode with Mojo::JSON, so a line reads as it does on a
# host with Cpanel::JSON::XS, which decodes as Mojo::JSON does. JSON::PP reads
# these two lines otherwise: it takes the noncharacter U+FFFF, raw in UTF-8,
# which Mojo::JSON refuses, and refuses the number "1.", which Mojo::JSON reads
# as 1. The first line holds a key twice, of which the last value wins.
my $at   = 0;
my $line = sub ($content) {
  $at++;
  return qq({"type":"user","sessionId":"pp","cwd":"/home/tester/pp","gitBranch":"main","uuid":"u$at",)
    . qq("timestamp":"2026-10-08T08:0$at:00Z","message":{"role":"user","content":$content}});
};
my @lines = ($line->(q("a draft","content":"the first prompt")), $line->(qq("a\xEF\xBF\xBFb")), $line->(q(1.)));

# A line decoded by $code: the structure, or "dies".
sub decoded ($code, $bytes) { my $rec = eval { $code->($bytes) }; return $@ ? 'dies' : $rec }
my $pp   = JSON::PP->new->utf8;
my $mojo = \&Mojo::JSON::decode_json;

# Whether JSON::PP and Mojo::JSON read a line otherwise.
sub differ ($bytes) {
  return !Test::More::eq_array([decoded($mojo, $bytes)], [decoded(sub ($b) { $pp->decode($b) }, $bytes)]);
}

subtest 'JSON::PP reads two of these lines otherwise' => sub {
  ok !differ($lines[0]), 'not the first';
  ok differ($lines[1]), 'the raw noncharacter';
  ok differ($lines[2]), 'the number "1."';
};

subtest 'the seam decodes as Mojo::JSON does' => sub {
  for my $package (qw(MCP::Hub::Native::ClaudeHistory MCP::Hub::Native::ClaudeSessions)) {
    my $seam = $package->can('decode_json');
    is_deeply [map { decoded($seam, $_) } @lines], [map { decoded($mojo, $_) } @lines], $package;
  }
};

my $root = tempdir;
my $file = $root->child('projects', '-home-tester-pp')->make_path->child('pp.jsonl');
$file->spew(join '', map {"$_\n"} @lines);

# Every decode of JSON::PP and of Mojo::JSON, while $code runs.
sub decodes ($code) {
  my %count = (pp => 0, mojo => 0);
  no warnings 'redefine';
  my $pp_decode = JSON::PP->can('decode');
  local *JSON::PP::decode          = sub { $count{pp}++;   goto &$pp_decode };
  local *Mojo::JSON::decode_json   = sub { $count{mojo}++; goto &$mojo };
  my @out = $code->();
  return {%count, out => $out[0]};
}

subtest 'claude-history' => sub {
  my $got = decodes(sub { MCP::Hub::Native::ClaudeHistory->new(root => "$root")->list_sessions });
  is $got->{pp}, 0, 'JSON::PP decodes no line';
  is $got->{mojo}, 3, 'Mojo::JSON every line';
  is $got->{out}[0]{messages},     2,                  'the line Mojo::JSON refuses is skipped, "1." counts';
  is $got->{out}[0]{first_prompt}, 'the first prompt', 'the last of a key held twice';

  my $conv = MCP::Hub::Native::ClaudeHistory->new(root => "$root")->get_conversation({session_id => 'pp'});
  is_deeply [map { $_->{text} } @{$conv->{entries}}], ['the first prompt', '1'], 'get_conversation reads them so';
};

subtest 'claude-sessions' => sub {
  my $got = decodes(sub {
    MCP::Hub::Native::ClaudeSessions->new(root => "$root", proc_root => "@{[tempdir]}")->_session_meta($file);
  });
  is $got->{pp}, 0, 'JSON::PP decodes no line';
  ok $got->{mojo}, 'Mojo::JSON does';
  is $got->{out}{session_id},  'pp', 'the session id from the head';
  is $got->{out}{last_prompt}, '1',  'the last prompt: "1." read as 1';
};

done_testing;
