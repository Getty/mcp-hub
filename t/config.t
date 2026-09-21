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

subtest '${VAR} expansion in the hub block' => sub {
  local %ENV = %ENV;
  delete $ENV{HUB_CACHE};
  $ENV{HUB_TOKEN} = 'sk-hub';
  $ENV{HUB_PORT}  = '3999';
  $ENV{HOME}      = '/home/tester';

  my $c = MCP::Hub::Config->from_data({
    mcpServers => {x => {command => 'a'}},
    hub        => {
      listen    => 'http://0.0.0.0:${HUB_PORT}',
      cache_dir => '${HUB_CACHE:-~/.cache/hub}',
      profiles  => {full => {servers => ['*'], admin => \1}},
      clients   => {main => {token => '${HUB_TOKEN}', profile => 'full'}},
    },
  });
  is $c->listen,                 'http://0.0.0.0:3999',     'hub.listen expanded';
  is $c->cache_dir,              '/home/tester/.cache/hub', 'hub.cache_dir default expanded, then tilde';
  is $c->clients->{main}{token}, 'sk-hub',                  'client token expanded';
  is $c->mode,                   'clients',                 'mode still derived from the clients block';
};

subtest 'an unset variable in a hub value is an error' => sub {
  local %ENV = %ENV;
  delete $ENV{DEFINITELY_UNSET_VAR};
  eval {
    MCP::Hub::Config->from_data({
      mcpServers => {x => {command => 'a'}},
      hub        => {
        profiles => {full => {servers => ['*']}},
        clients  => {main => {token => '${DEFINITELY_UNSET_VAR}', profile => 'full'}},
      },
    });
  };
  like $@, qr/DEFINITELY_UNSET_VAR is not set/, 'unset var in a token dies';
  like $@, qr/hub\.clients\.main\.token/,       'error names the JSON path';
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

subtest 'http and sse url upstreams' => sub {
  my $c = MCP::Hub::Config->from_data({
    mcpServers => {
      remote => {url => 'http://x/mcp', headers => {Authorization => 'Bearer t'}},
      legacy => {url => 'http://y/mcp/sse', type => 'sse'},
    },
  });
  my $r = $c->server('remote');
  is $r->{type}, 'http', 'url with no type -> streamable http';
  is $r->{url},  'http://x/mcp', 'url kept';
  is $r->{headers}{Authorization}, 'Bearer t', 'headers kept';

  my $l = $c->server('legacy');
  is $l->{type}, 'sse', 'type: sse -> sse transport';

  eval { MCP::Hub::Config->from_data({mcpServers => {bad => {url => 'http://z', type => 'ftp'}}}) };
  like $@, qr/unknown transport type 'ftp'/, 'unknown transport type rejected';
};

subtest 'exactly one of command, class or url' => sub {
  eval { MCP::Hub::Config->from_data({mcpServers => {x => {}}}) };
  like $@, qr/exactly one of/, 'none given';

  eval { MCP::Hub::Config->from_data({mcpServers => {x => {command => 'a', class => 'B'}}}) };
  like $@, qr/exactly one of/, 'command and class';

  eval { MCP::Hub::Config->from_data({mcpServers => {x => {command => 'a', url => 'http://z'}}}) };
  like $@, qr/exactly one of/, 'command and url';
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
