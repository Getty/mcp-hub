#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File qw(tempdir);
use MCP::Client;
use MCP::Hub;

binmode Test::More->builder->$_, ':encoding(UTF-8)' for qw(output failure_output todo_output);

# What an agent learns of the natives' tools is what tools/list says of them.
# The prompts list_sessions and list_running_sessions send are cut, and the
# descriptions say so, and where the whole text is; read here as the hub sends
# them, from each native's own endpoint.
my ($root, $proc, $cache) = (tempdir, tempdir, tempdir);
my $app = MCP::Hub->new(hub_config_input => {
  mcpServers => {
    history  => {class => 'MCP::Hub::Native::ClaudeHistory',  args => {root => "$root"}},
    sessions => {class => 'MCP::Hub::Native::ClaudeSessions', args => {root => "$root", proc_root => "$proc"}},
  },
  hub => {cache_dir => "$cache"},
});
my $t = Test::Mojo->new($app);

# The tools/list of one endpoint, by name.
sub tools ($path) {
  my $base = $t->ua->server->url->to_string =~ s{/$}{}r;
  return +{map { $_->{name} => $_ } @{MCP::Client->new(ua => $t->ua, url => "$base$path")->list_tools->{tools}}};
}

subtest 'list_sessions says that first_prompt is cut' => sub {
  my $description = tools('/history')->{list_sessions}{description};
  like $description, qr/\AList conversation sessions, newest first\./, 'what it lists';
  like $description, qr/A first_prompt over 500 characters is cut to 500 plus "\x{2026}"/, 'first_prompt is cut';
  like $description, qr/get_conversation has the whole text/, 'where the whole text is';
};

subtest 'list_running_sessions says that last_prompt is cut' => sub {
  my $description = tools('/sessions')->{list_running_sessions}{description};
  like $description, qr/\AList the Claude Code sessions currently running on this machine\./, 'what it lists';
  like $description, qr/A last_prompt over 500 characters is cut to 500 plus "\x{2026}"/, 'last_prompt is cut';
  like $description, qr/the history server's get_conversation has the whole text/, 'where the whole text is';
};

# search_conversations keeps a match by its own time, not by its session's.
subtest "search_conversations' since and until are of the matches" => sub {
  my $input = tools('/history')->{search_conversations}{inputSchema}{properties};
  is $input->{since}{description}, 'Only matches on or after this date (YYYY-MM-DD or ISO)', 'since';
  is $input->{until}{description}, 'Only matches on or before this date',                    'until';
};

done_testing;
