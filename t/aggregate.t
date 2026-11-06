#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File qw(curfile tempdir);
use MCP::Client;
use MCP::Hub;

use lib curfile->sibling('lib')->to_string;

# An in-process class whose tool and prompt carry what the facade must keep:
# title, icons and _meta. MCP::Server renders none of them on its own, so the
# class adds them to its own tools/list and prompts/list, as a real upstream does.
package ExtraEcho {
  use Mojo::Base 'EchoServer', -signatures;

  sub _handle_tools_list ($self, $context) {
    my ($result, @hints) = $self->SUPER::_handle_tools_list($context);
    for my $tool (grep { $_->{name} eq 'echo' } @{$result->{tools}}) {
      $tool->{title} = 'Echo';
      $tool->{icons} = [{src => 'file://echo.png'}];
      $tool->{_meta} = {'anthropic/maxResultSizeChars' => 1234};
    }
    return ($result, @hints);
  }

  sub _handle_prompts_list ($self, $context) {
    my ($result, @hints) = $self->SUPER::_handle_prompts_list($context);
    for my $prompt (@{$result->{prompts}}) {
      $prompt->{title} = 'Greeting';
      $prompt->{icons} = [{src => 'file://greet.png'}];
      $prompt->{_meta} = {origin => 'extra-echo'};
    }
    return ($result, @hints);
  }
}

sub client ($t, $path) {
  my $base = $t->ua->server->url->to_string;
  $base =~ s{/$}{};
  return MCP::Client->new(ua => $t->ua, url => "$base$path");
}

sub hub ($hub = {}, $server = {class => 'ExtraEcho'}) {
  my $cache = tempdir;
  return MCP::Hub->new(hub_config_input => {
    mcpServers => {extra => $server},
    hub        => {cache_dir => "$cache", %$hub},
  });
}

sub find ($list, $name) { return (grep { $_->{name} eq $name } @$list)[0] }

my $EXTRA = {
  title => 'Echo',
  icons => [{src => 'file://echo.png'}],
  _meta => {'anthropic/maxResultSizeChars' => 1234},
};
my $PEXTRA = {
  title => 'Greeting',
  icons => [{src => 'file://greet.png'}],
  _meta => {origin => 'extra-echo'},
};

subtest 'open mode: /all keeps title, icons and _meta' => sub {
  my $t = Test::Mojo->new(hub());

  my $own = find(client($t, '/extra')->list_tools->{tools}, 'echo');
  is $own->{title}, $EXTRA->{title}, 'control: own endpoint has the title';
  is_deeply $own->{icons}, $EXTRA->{icons}, 'control: own endpoint has icons';
  is_deeply $own->{_meta}, $EXTRA->{_meta}, 'control: own endpoint has _meta';

  my $agg = find(client($t, '/all')->list_tools->{tools}, 'extra__echo');
  ok $agg, 'the prefixed tool is in /all';
  is $agg->{title}, $EXTRA->{title}, '/all keeps the tool title';
  is_deeply $agg->{icons}, $EXTRA->{icons}, '/all keeps the tool icons';
  is_deeply $agg->{_meta}, $EXTRA->{_meta}, '/all keeps the tool _meta';
};

subtest 'open mode: /all keeps title, icons and _meta of prompts' => sub {
  my $t = Test::Mojo->new(hub());

  my $own = find(client($t, '/extra')->list_prompts->{prompts}, 'greet');
  is $own->{title}, $PEXTRA->{title}, 'control: own endpoint has the prompt title';
  is_deeply $own->{icons}, $PEXTRA->{icons}, 'control: own endpoint has the prompt icons';
  is_deeply $own->{_meta}, $PEXTRA->{_meta}, 'control: own endpoint has the prompt _meta';

  my $agg = find(client($t, '/all')->list_prompts->{prompts}, 'extra__greet');
  ok $agg, 'the prefixed prompt is in /all';
  is $agg->{title}, $PEXTRA->{title}, '/all keeps the prompt title';
  is_deeply $agg->{icons}, $PEXTRA->{icons}, '/all keeps the prompt icons';
  is_deeply $agg->{_meta}, $PEXTRA->{_meta}, '/all keeps the prompt _meta';
};

subtest 'clients mode: the profile tool filter leaves extra on what it keeps' => sub {
  my $t = Test::Mojo->new(hub({
    profiles => {limited => {servers => ['extra'], tools => {extra => {allow => ['echo']}}}},
    clients  => {worker  => {token => 'tok-worker', profile => 'limited'}},
  }));
  my $rpc = {jsonrpc => '2.0', id => 1, method => 'tools/list', params => {}};
  my $auth = {Authorization => 'Bearer tok-worker'};

  my $own = find($t->post_ok('/extra' => $auth => json => $rpc)->tx->res->json->{result}{tools}, 'echo');
  is $own->{title}, $EXTRA->{title}, 'control: filtered own endpoint has the title';

  my $tools = $t->post_ok('/all' => $auth => json => $rpc)->tx->res->json->{result}{tools};
  is_deeply [sort map { $_->{name} } @$tools], ['extra__echo'], 'the filter ran: only the allowed tool is left';
  is $tools->[0]{title}, $EXTRA->{title}, 'filtered /all keeps the title';
  is_deeply $tools->[0]{icons}, $EXTRA->{icons}, 'filtered /all keeps the icons';
  is_deeply $tools->[0]{_meta}, $EXTRA->{_meta}, 'filtered /all keeps _meta';
};

# A forked class is listed from the manifest, the way a stdio upstream is: its
# extras reach /all through Facade::Tool, not through an in-process server.
subtest 'fork: /all keeps title, icons and _meta from the manifest' => sub {
  plan skip_all => 'forked class workers need Linux (/proc/self/fd)' unless -d '/proc/self/fd';
  my $t = Test::Mojo->new(hub({}, {class => 'ExtraEcho', hub => {fork => \1}}));

  my $own = find(client($t, '/extra')->list_tools->{tools}, 'echo');
  is $own->{title}, $EXTRA->{title}, 'control: own endpoint has the title';
  is_deeply $own->{icons}, $EXTRA->{icons}, 'control: own endpoint has icons';
  is_deeply $own->{_meta}, $EXTRA->{_meta}, 'control: own endpoint has _meta';

  my $agg = find(client($t, '/all')->list_tools->{tools}, 'extra__echo');
  ok $agg, 'the prefixed tool is in /all';
  is $agg->{title}, $EXTRA->{title}, '/all keeps the tool title';
  is_deeply $agg->{icons}, $EXTRA->{icons}, '/all keeps the tool icons';
  is_deeply $agg->{_meta}, $EXTRA->{_meta}, '/all keeps the tool _meta';

  my $prompt = find(client($t, '/all')->list_prompts->{prompts}, 'extra__greet');
  ok $prompt, 'the prefixed prompt is in /all';
  is $prompt->{title}, $PEXTRA->{title}, '/all keeps the prompt title';
  is_deeply $prompt->{icons}, $PEXTRA->{icons}, '/all keeps the prompt icons';
  is_deeply $prompt->{_meta}, $PEXTRA->{_meta}, '/all keeps the prompt _meta';
};

done_testing;
