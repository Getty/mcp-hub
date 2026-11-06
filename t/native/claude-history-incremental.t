#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(path tempdir);
use Mojo::JSON qw(decode_json encode_json);
use MCP::Hub::Native::ClaudeHistory;

# ClaudeHistory reads session files a line at a time and keeps, per file, where
# its last scan stopped: a file that grew is read only from there. Each step
# below is checked against a fresh instance and against reading every line.
my $root = tempdir;
my $dir  = $root->child('projects', '-home-tester-inc')->make_path;
my $file = $dir->child('inc.jsonl');

my $t = 0;
sub rec (%f) {
  my %r = (sessionId => 'inc', cwd => '/home/tester/inc', gitBranch => 'main', uuid => "u$t",
    timestamp => sprintf('2026-10-02T08:%02d:%02dZ', $t / 60, $t % 60), %f);
  $t++;
  return encode_json(\%r);
}
sub user ($text) { rec(type => 'user', message => {role => 'user', content => $text}) }
sub assistant ($text) { rec(type => 'assistant', message => {role => 'assistant', content => [{type => 'text', text => $text}]}) }
sub append ($bytes) { open my $fh, '>>:raw', "$file" or die $!; print {$fh} $bytes; close $fh }

# The metadata of one file as the scan before line-by-line reading made it.
sub every_line ($f) {
  my ($session_id, $project, $started, $last, $count, $first_prompt, $title, $branch);
  for my $line (split /\n/, $f->slurp) {
    next unless length $line;
    my $rec = eval { decode_json($line) } or next;
    $session_id //= $rec->{sessionId};
    $project    //= $rec->{cwd};
    $branch     //= $rec->{gitBranch};
    $started    //= $rec->{timestamp};
    $last = $rec->{timestamp} if defined $rec->{timestamp};
    my $type = $rec->{type} // '';
    $title = $rec->{aiTitle} if $type eq 'ai-title';
    if ($type eq 'user' || $type eq 'assistant') {
      $count++;
      $first_prompt //= MCP::Hub::Native::ClaudeHistory::_text($rec->{message}) if $type eq 'user';
    }
  }
  return [{session_id => $session_id // 'inc', project => $project // '/home/tester/inc', started_at => $started,
    last_activity => $last // $started, messages => $count // 0, first_prompt => $first_prompt, title => $title,
    git_branch => $branch, _file => "$f"}];
}

my $h = MCP::Hub::Native::ClaudeHistory->new(root => "$root");
sub fresh () { MCP::Hub::Native::ClaudeHistory->new(root => "$root") }
sub same ($name) {
  subtest $name => sub {
    my $sessions = $h->list_sessions;
    is_deeply $sessions, every_line($file), 'as reading every line';
    is_deeply $sessions, fresh->list_sessions, 'as a fresh instance';
    is_deeply $h->list_projects, fresh->list_projects, 'projects as a fresh instance';
    is_deeply $h->get_conversation({session_id => $sessions->[0]{session_id}}),
      fresh->get_conversation({session_id => $sessions->[0]{session_id}}), 'conversation as a fresh instance';
  };
}

my $decoded = 0;
{
  no warnings 'redefine';
  my $decode = \&MCP::Hub::Native::ClaudeHistory::decode_json;
  *MCP::Hub::Native::ClaudeHistory::decode_json = sub { $decoded++; $decode->(@_) };
}
sub decodes ($code) { $decoded = 0; $code->(); return $decoded }

$file->spew(join '', map {"$_\n"} user('first prompt'), assistant('answer'), map { assistant("turn $_") } 1 .. 200);
same 'a new file';
is decodes(sub { $h->list_sessions }), 0, 'an unchanged file is not read';

append(user('later prompt') . "\n" . rec(type => 'ai-title', aiTitle => 'A title') . "\n");
is decodes(sub { $h->list_sessions }), 2, 'only the two appended lines are decoded';
same 'appended lines';

my $half = user('written in two goes');
append(substr $half, 0, 30);
same 'an unterminated, unfinished last line';
append(substr($half, 30) . "\n");
same 'the line finished';

append(assistant('no newline yet'));
same 'an unterminated, complete last line';
append("\n" . assistant('next') . "\n");
same 'its newline and one more line';
is $h->list_sessions->[0]{messages}, fresh->list_sessions->[0]{messages}, 'the unterminated line counted once';

append(assistant('glued'));
append(assistant('to the next') . "\n");
same 'a complete last line with the next one glued on';

append(rec(type => 'ai-title', aiTitle => 'A newer title') . "\n");
same 'a newer title';
is $h->list_sessions->[0]{title}, 'A newer title', 'the last ai-title wins';

$file->spew(join '', map {"$_\n"} user('shorter'), assistant('file'));
same 'the file shrank';

my $tmp = $dir->child('inc.jsonl.tmp');
$tmp->spew(join '', map {"$_\n"} rec(sessionId => 'other', type => 'user', message => {content => 'replaced'}), map { assistant("new $_") } 1 .. 300);
rename "$tmp", "$file" or die $!;
same 'the file was replaced by a bigger one';
is $h->list_sessions->[0]{session_id}, 'other', 'the new content is read from the start';

my $before = $file->slurp;
(my $rewritten = $before) =~ s/replaced/REPLACED/;
$file->spew($rewritten);
utime time + 5, time + 5, "$file";
is length $rewritten, length $before, 'same size';
same 'the file was rewritten without growing';
is $h->list_sessions->[0]{first_prompt}, 'REPLACED', 'rewritten content is read';

subtest 'search after an append' => sub {
  append(user('more') . "\n");
  my @hits = @{$h->search_conversations({query => 'replaced'})};
  is scalar @hits, 1, 'found in the part read before';
  is_deeply \@hits, fresh->search_conversations({query => 'replaced'}), 'as a fresh instance';

  append(user('a needle in the new part') . "\n");
  is decodes(sub { @hits = @{$h->search_conversations({query => 'needle'})} }), 1,
    'the appended line is decoded, the lines before it only if they hold the needle raw';
  is scalar @hits, 1, 'found in the appended part';
  is_deeply \@hits, fresh->search_conversations({query => 'needle'}), 'as a fresh instance';
  same 'the metadata the search brought up to date';
};

subtest 'a file replaced between its stat and its open' => sub {
  $h->list_sessions;
  append(assistant('grown') . "\n");
  my $swap = $dir->child('inc.jsonl.swap');
  $swap->spew(join '', map {"$_\n"} rec(sessionId => 'swapped', type => 'user', message => {content => 'swapped in'}),
    map { assistant("swap $_") } 1 .. 400);
  {
    no warnings 'redefine';
    my $open = \&Mojo::File::open;
    local *Mojo::File::open = sub ($p, @args) {
      if (-e "$swap") { rename "$swap", "$file" or die $! }
      return $open->($p, @args);
    };
    $h->list_sessions;
  }
  is $h->list_sessions->[0]{session_id}, 'swapped', 'the file opened is read from the start';
  same 'the replacement';
};

subtest 'a cold search reads each file once' => sub {
  my $other = tempdir;
  my $od    = $other->child('projects', '-home-tester-cold')->make_path;
  my $lines = 0;
  for my $n (1 .. 3) {
    my @l = (user("prompt $n with a wörd"), map { assistant("reply $n.$_") } 1 .. 50);
    $od->child("s$n.jsonl")->spew(join '', map {"$_\n"} @l);
    $lines += @l;
  }
  my $cold = MCP::Hub::Native::ClaudeHistory->new(root => "$other");
  my @hits;
  is decodes(sub { @hits = @{$cold->search_conversations({query => 'wörd'})} }), $lines, "every line decoded once ($lines)";
  is scalar @hits, 3, 'all three found';
  is_deeply \@hits, MCP::Hub::Native::ClaudeHistory->new(root => "$other")->search_conversations({query => 'wörd'}),
    'same as another cold search';
  is decodes(sub { $cold->search_conversations({query => 'wörd'}) }), $lines, 'a warm search decodes each line once too';
  is_deeply $cold->list_sessions, MCP::Hub::Native::ClaudeHistory->new(root => "$other")->list_sessions,
    'the metadata the search cached is that of a list';

  my $texts = 0;
  {
    no warnings 'redefine';
    my $text = \&MCP::Hub::Native::ClaudeHistory::_text;
    local *MCP::Hub::Native::ClaudeHistory::_text = sub { $texts++; $text->(@_) };
    my $capped = MCP::Hub::Native::ClaudeHistory->new(root => "$other");
    @hits = @{$capped->search_conversations({query => 'reply', roles => ['user', 'assistant'], limit => 1})};
  }
  is scalar @hits, 1, 'a word on every line, limit 1: one hit';
  is $texts, 3 + 3 * 2, 'text is taken from the first prompt of each file and from its lines up to the first hit';
};

done_testing;
