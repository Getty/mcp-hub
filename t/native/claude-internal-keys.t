#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(curfile path tempdir);
use Mojo::JSON qw(decode_json);
use MCP::Hub::Native::ClaudeHistory;
use MCP::Hub::Native::ClaudeSessions;

# What a tool sends is what its POD documents: no key of it starts with "_",
# so no internal field -- like the path of a session file on this host -- goes
# out on the wire. Every tool of both natives is called over the fixtures, its
# JSON text and its structured content alike.
my $root = curfile->sibling('..', 'fixtures', 'claude')->to_string;

# Where in a value a key starts with "_", and where a string holds $root.
sub leaks ($value, $at = '') {
  return map { leaks($value->[$_], "$at\[$_]") } 0 .. $#$value if ref $value eq 'ARRAY';
  return map { (/\A_/ ? "key $at.$_" : ()), leaks($value->{$_}, "$at.$_") } sort keys %$value if ref $value eq 'HASH';
  return defined $value && !ref $value && index($value, $root) >= 0 ? "path $at" : ();
}

sub sends_nothing_internal ($server, $name, $args = {}) {
  my ($tool) = grep { $_->name eq $name } @{$server->tools};
  my $result = $tool->code->($tool, $args);
  my $data   = decode_json($result->{content}[0]{text});
  ok ref $data eq 'HASH' || @$data, "$name answers with something";
  is_deeply [leaks($data)], [], "$name sends no internal key and no path of this host in its text";
  is_deeply [leaks($result->{structuredContent})], [], "$name sends none in its structured content";
}

my $h = MCP::Hub::Native::ClaudeHistory->new(root => $root);
sends_nothing_internal($h, 'list_projects');
sends_nothing_internal($h, 'list_sessions');
sends_nothing_internal($h, 'list_sessions', {project => '/home/tester/proj-a', limit => 1});
sends_nothing_internal($h, 'search_conversations', {query => 'kubernetes', roles => ['user', 'assistant']});
sends_nothing_internal($h, 'get_conversation', {session_id => 'a1'});

SKIP: {
  skip 'symlink not supported here', 3 unless eval { symlink('', "@{[tempdir]}/x"); 1 };
  my $proc = tempdir;
  my $pid  = path($proc, 4242)->make_path;
  $pid->child('comm')->spew("claude\n");
  symlink('/home/tester/proj-a', $pid->child('cwd')->to_string) or die $!;
  sends_nothing_internal(MCP::Hub::Native::ClaudeSessions->new(root => $root, proc_root => "$proc"), 'list_running_sessions');
}

done_testing;
