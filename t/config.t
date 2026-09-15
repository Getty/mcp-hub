use Mojo::Base -strict;
use Test::More;
use MCP::Hub::Config;

# --- defaults and mode derivation ------------------------------------------

subtest 'a bare mcpServers block is a valid open-mode config' => sub {
  local $ENV{XDG_CACHE_HOME} = '/tmp/xdg';
  my $c = MCP::Hub::Config->from_data({
    mcpServers => {context7 => {command => 'npx', args => ['-y', '@upstash/context7-mcp']}},
  });
  is $c->mode, 'open', 'no clients -> open mode';
  is $c->listen,          'http://127.0.0.1:3080', 'default listen';
  is $c->idle_timeout,    300,                      'default idle_timeout';
  is $c->request_timeout, 60,                       'default request_timeout';
  is $c->cache_dir, '/tmp/xdg/mcp-hub', 'cache_dir honours XDG_CACHE_HOME';

  my $entry = $c->server('context7');
  is $entry->{type},    'stdio',                'stdio type derived from command';
  is $entry->{command}, 'npx',                  'command kept';
  is_deeply $entry->{args}, ['-y', '@upstash/context7-mcp'], 'args kept';
  is_deeply $entry->{env}, {}, 'env defaults to empty';
};

subtest 'clients make it clients mode' => sub {
  my $c = MCP::Hub::Config->from_data({
    mcpServers => {run => {class => 'MCP::Run'}},
    hub => {
      profiles => {full => {servers => ['*'], admin => \1}},
      clients  => {main => {token => 'secret', profile => 'full'}},
    },
  });
  is $c->mode, 'clients', 'clients present -> clients mode';
  is $c->clients->{main}{token}, 'secret', 'client token kept';
  ok $c->profiles->{full}{admin}, 'admin flag normalized to true';
};

subtest 'perl class upstream' => sub {
  my $c = MCP::Hub::Config->from_data({
    mcpServers => {run => {class => 'MCP::Run', args => {allowed_commands => ['ls']}}},
  });
  my $e = $c->server('run');
  is $e->{type},  'perl',     'class -> perl type';
  is $e->{class}, 'MCP::Run', 'class kept';
  is_deeply $e->{class_args}, {allowed_commands => ['ls']}, 'class args kept';
};

# --- ${VAR} expansion ------------------------------------------------------

subtest '${VAR} expansion' => sub {
  local $ENV{SERPER_API_KEY} = 'sk-123';
  local $ENV{HOME}           = '/home/tester';
  my $c = MCP::Hub::Config->from_data({
    mcpServers => {
      serper => {
        command => 'npx',
        args    => ['serper@${VERSION:-latest}'],
        env     => {SERPER_API_KEY => '${SERPER_API_KEY}'},
        cwd     => '~/work',
      },
    },
  });
  my $e = $c->server('serper');
  is $e->{env}{SERPER_API_KEY}, 'sk-123',           'env var expanded';
  is_deeply $e->{args}, ['serper@latest'],          '${VAR:-default} uses default when unset';
  is $e->{cwd}, '/home/tester/work',                'cwd tilde + expansion';
};

subtest 'unset variable without default is an error' => sub {
  local %ENV = %ENV;
  delete $ENV{DEFINITELY_UNSET_VAR};
  eval {
    MCP::Hub::Config->from_data({
      mcpServers => {x => {command => '${DEFINITELY_UNSET_VAR}'}},
    });
  };
  like $@, qr/DEFINITELY_UNSET_VAR is not set/, 'unset var without default dies';
  like $@, qr/mcpServers\.x\.command/,          'error names the JSON path';
};

# --- validation ------------------------------------------------------------

subtest 'reserved names' => sub {
  for my $name (qw(all _hidden)) {
    eval { MCP::Hub::Config->from_data({mcpServers => {$name => {command => 'x'}}}) };
    like $@, qr/reserved/, "'$name' is reserved";
  }
};

subtest 'bad server name' => sub {
  eval { MCP::Hub::Config->from_data({mcpServers => {'has space' => {command => 'x'}}}) };
  like $@, qr/must match/, 'invalid name rejected';
};

subtest 'url upstreams are rejected' => sub {
  eval { MCP::Hub::Config->from_data({mcpServers => {remote => {url => 'http://x/mcp'}}}) };
  like $@, qr/HTTP upstreams are not supported yet/, 'url rejected';

  eval { MCP::Hub::Config->from_data({mcpServers => {remote => {command => 'x', type => 'sse'}}}) };
  like $@, qr/HTTP upstreams are not supported yet/, 'type: sse rejected';
};

subtest 'exactly one of command or class' => sub {
  eval { MCP::Hub::Config->from_data({mcpServers => {x => {}}}) };
  like $@, qr/exactly one of/, 'neither command nor class';

  eval { MCP::Hub::Config->from_data({mcpServers => {x => {command => 'a', class => 'B'}}}) };
  like $@, qr/exactly one of/, 'both command and class';
};

subtest 'unknown keys surface with their path' => sub {
  eval { MCP::Hub::Config->from_data({mcpServers => {x => {command => 'a', bogus => 1}}}) };
  like $@, qr/unknown key 'bogus'/,     'unknown entry key';
  like $@, qr/mcpServers\.x\.bogus/,    'path in message';

  eval {
    MCP::Hub::Config->from_data({
      mcpServers => {x => {command => 'a', hub => {idle_timeout => 'soon'}}},
    });
  };
  like $@, qr/must be an integer/,               'non-integer idle_timeout';
  like $@, qr/mcpServers\.x\.hub\.idle_timeout/, 'nested hub path';
};

subtest 'per-entry hub overrides' => sub {
  my $c = MCP::Hub::Config->from_data({
    mcpServers => {playwright => {command => 'npx', hub => {idle_timeout => 120, always_on => \1}}},
  });
  my $e = $c->server('playwright');
  is $e->{idle_timeout}, 120, 'per-entry idle_timeout';
  is $e->{always_on},    1,   'always_on normalized';
};

subtest 'public_profile must exist' => sub {
  eval {
    MCP::Hub::Config->from_data({
      mcpServers => {x => {command => 'a'}},
      hub => {clients => {}, public_profile => 'ghost'},
    });
  };
  like $@, qr/unknown profile 'ghost'/, 'public_profile validated';
};

done_testing;
