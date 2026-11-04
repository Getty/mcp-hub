#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::JSON qw(false true);
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

subtest 'auto_reload' => sub {
  my $off = MCP::Hub::Config->from_data({mcpServers => {}});
  my $on  = MCP::Hub::Config->from_data({mcpServers => {}, hub => {auto_reload => \1}});
  # false as JSON decodes it, and as the YAML reader's 'perl' booleans spell it
  my $no   = MCP::Hub::Config->from_data({mcpServers => {}, hub => {auto_reload => false}});
  my $nope = MCP::Hub::Config->from_data({mcpServers => {}, hub => {auto_reload => ''}});
  is $off->auto_reload,  0, 'off by default';
  is $on->auto_reload,   1, 'switched on from the hub block';
  is $no->auto_reload,   0, 'and off again explicitly';
  is $nope->auto_reload, 0, 'a YAML false is false too';

  eval { MCP::Hub::Config->from_data({mcpServers => {}, hub => {auto_relod => \1}}) };
  like $@, qr/unknown key 'auto_relod'/, 'a typo is a configuration error, not a silent no-op';
  like $@, qr/hub\.auto_relod/,          'with its path';
};

# --- docker and compose entries --------------------------------------------

sub config_error ($entry, $hub = {}) {
  eval { MCP::Hub::Config->from_data({mcpServers => {x => $entry}, hub => $hub}) };
  return $@;
}

subtest 'a docker entry, normalized' => sub {
  local $ENV{HOME} = '/home/tester';
  my $c = MCP::Hub::Config->from_data({
    mcpServers => {
      fetch => {
        docker      => 'mcp/fetch:${FETCH_TAG:-latest}',
        args        => ['--ignore-robots-txt'],
        env         => {TZ => '${TZ:-UTC}'},
        volumes     => ['~/data:/data:ro'],
        docker_args => ['--read-only'],
        port        => 8080,
        path        => '/rpc',
        type        => 'sse',
        hub         => {idle_timeout => 60},
      },
      plain => {docker => 'mcp/time'},
    },
    hub => {docker_command => '~/bin/podman', docker_network => 'mcp-hub'},
  });
  is $c->docker_command, '/home/tester/bin/podman', 'hub.docker_command, with ~ expanded';
  is $c->docker_network, 'mcp-hub',                 'hub.docker_network';

  my $e = $c->server('fetch');
  is $e->{type},  'docker',           'docker -> docker type';
  is $e->{image}, 'mcp/fetch:latest', 'the image, ${VAR} expanded';
  is_deeply $e->{args},        ['--ignore-robots-txt'],     'args go to the image';
  is_deeply $e->{env},         {TZ => 'UTC'},               'env expanded';
  is_deeply $e->{volumes},     ['/home/tester/data:/data:ro'], 'a volume host path may start with ~';
  is_deeply $e->{docker_args}, ['--read-only'],             'docker_args kept';
  is $e->{port},           8080,                       'port';
  is $e->{path},           '/rpc',                     'path';
  is $e->{transport},      'sse',                      'type is the HTTP transport';
  is $e->{stdio},          0,                          'stdio off by default';
  is $e->{idle_timeout},   60,                         'hub block applies';
  is $e->{docker_command}, '/home/tester/bin/podman',  'the docker command rides on the entry';
  is $e->{docker_network}, 'mcp-hub',                  'as does the network';

  my $p = $c->server('plain');
  is $p->{port},      undef, 'no port: the image decides at start';
  is $p->{transport}, undef, 'no type: undef, not a default';
  is_deeply $p->{args}, [], 'args default to empty';

  is(MCP::Hub::Config->from_data({mcpServers => {}})->docker_command, 'docker', 'docker_command defaults to docker');
};

subtest 'docker entry errors name the key' => sub {
  my $err = config_error({docker => 'mcp/time', cwd => '/tmp'});
  like $err, qr/mcpServers\.x\.cwd: 'cwd' does not apply to a 'docker' entry/, 'cwd is not for docker';

  $err = config_error({command => 'x', port => 8080});
  like $err, qr/mcpServers\.x\.port: 'port' only applies to a 'compose' or a 'docker' entry/,
    'port is not for a command';

  $err = config_error({docker => 'mcp/time', stdio => \1, port => 8080});
  like $err, qr/mcpServers\.x\.port: 'port' cannot be combined with "stdio": true/, 'stdio and port';
  $err = config_error({docker => 'mcp/time', stdio => \1, path => '/mcp'});
  like $err, qr/mcpServers\.x\.path: 'path' cannot be combined with "stdio": true/, 'stdio and path';
  $err = config_error({docker => 'mcp/time', stdio => \1, type => 'sse'});
  like $err, qr/mcpServers\.x\.type: 'type' cannot be combined/, 'stdio and type';

  like config_error({docker => 'mcp/time', port => 70000}), qr/mcpServers\.x\.port: must be a port number/,
    'port out of range';
  like config_error({docker => 'mcp/time', port => 'http'}), qr/mcpServers\.x\.port: must be an integer/,
    'port not a number';
  like config_error({docker => 'mcp/time', port => true}), qr/mcpServers\.x\.port: must be an integer/,
    'port: true is not port 1';
  like config_error({command => 'a', hub => {idle_timeout => true}}),
    qr/mcpServers\.x\.hub\.idle_timeout: must be an integer/, 'nor is idle_timeout: true one second';
  like config_error({docker => 'mcp/time', path => 'mcp'}), qr/mcpServers\.x\.path: must be a string starting with '\/'/,
    'path must be absolute';
  like config_error({docker => 'mcp/time', env => {'BAD-NAME' => 1}}),
    qr/mcpServers\.x\.env\.BAD-NAME: not a valid environment variable name/, 'env key is a variable name';
  like config_error({docker => 'mcp/time', volumes => '/a:/b'}), qr/mcpServers\.x\.volumes: must be a JSON array/,
    'volumes is a list';
  like config_error({docker => 'mcp/time', docker_args => [['--rm']]}),
    qr/mcpServers\.x\.docker_args\[0\]: must be a string/, 'docker_args are strings';
  like config_error({docker => ''}), qr/mcpServers\.x\.docker: must be a non-empty string/, 'an image is needed';
  like config_error({docker => 'mcp/time', command => 'x'}), qr/exactly one of/, 'docker and command';
  like config_error({docker => 'mcp/time', url => 'http://x/mcp'}), qr/exactly one of/, 'docker and url';
};

subtest 'a compose entry, normalized' => sub {
  local $ENV{HOME} = '/home/tester';
  my $c = MCP::Hub::Config->from_data({
    mcpServers => {
      stack => {compose => '~/mcp/stack', service => 'mcp', env => {TOKEN => 't'}},
      web   => {compose => '/srv/web', service => 'api', url => 'http://localhost:8080/mcp'},
    },
    hub => {docker_network => 'mcp-hub'},
  });
  my $e = $c->server('stack');
  is $e->{type},    'compose',               'compose -> compose type';
  is $e->{compose}, '/home/tester/mcp/stack', 'the project directory, with ~ expanded';
  is $e->{service}, 'mcp',                   'the service';
  is_deeply $e->{env}, {TOKEN => 't'},       'env kept';
  is $e->{docker_command}, 'docker',         'the docker command rides on the entry';
  ok !exists $e->{docker_network},           'the network is a docker-entry setting only';

  my $w = $c->server('web');
  is $w->{type}, 'compose',                   'a url does not make a compose entry an http one';
  is $w->{url},  'http://localhost:8080/mcp', 'url kept';
};

subtest 'compose entry errors name the key' => sub {
  my $err = config_error({compose => '/srv/stack'});
  like $err, qr/mcpServers\.x\.service: 'service' is required/, 'service is required';

  like config_error({compose => '/srv/stack', service => ''}), qr/mcpServers\.x\.service: must be a non-empty string/,
    'service must be a name';
  like config_error({compose => '/srv/stack', service => 'mcp', url => 'http://x/mcp', port => 80}),
    qr/mcpServers\.x\.port: 'port' cannot be combined with 'url'/, 'port and url';
  like config_error({compose => '/srv/stack', service => 'mcp', stdio => \1, url => 'http://x/mcp'}),
    qr/mcpServers\.x\.url: 'url' cannot be combined with "stdio": true/, 'stdio and url';
  like config_error({compose => '/srv/stack', service => 'mcp', volumes => []}),
    qr/mcpServers\.x\.volumes: 'volumes' does not apply to a 'compose' entry/, 'volumes belong in the compose file';
  like config_error({docker => 'mcp/time', service => 'mcp'}),
    qr/mcpServers\.x\.service: 'service' does not apply to a 'docker' entry/, 'service is for compose';
  like config_error({command => 'x', service => 'mcp'}),
    qr/mcpServers\.x\.service: 'service' only applies to a 'compose' entry/, 'service is for compose only';
  like config_error({compose => '/srv/stack', service => 'mcp', docker => 'mcp/time'}), qr/exactly one of/,
    'compose and docker';
};

# --- class entries: in process and forked ---------------------------------

subtest 'a forked class entry, normalized' => sub {
  my $c = MCP::Hub::Config->from_data({
    mcpServers => {
      wiki => {
        class => 'MCP::Wiki::Server',
        args  => {wiki_root => '/srv/wiki', use_git => true},
        hub   => {fork => true, idle_timeout => 600, request_timeout => 30, always_on => true},
      },
      plain => {class => 'MCP::Run', hub => {fork => false}},
    },
  });
  my $e = $c->server('wiki');
  is $e->{type},  'fork',              'hub.fork makes it the fork type';
  is $e->{class}, 'MCP::Wiki::Server', 'class kept';
  is_deeply $e->{class_args}, {wiki_root => '/srv/wiki', use_git => true}, 'args kept as they are';
  is $e->{idle_timeout},    600, 'idle_timeout applies to a forked class';
  is $e->{request_timeout}, 30,  'request_timeout applies to a forked class';
  is $e->{always_on},       1,   'always_on applies to a forked class';
  ok !exists $e->{fork}, 'hub.fork itself is not kept, the type says it';

  is $c->server('plain')->{type}, 'perl', '"fork": false is an in-process class';
};

subtest 'hub.fork only applies to a class entry' => sub {
  for my $entry (
    {command => 'x'},
    {url     => 'http://127.0.0.1:1/mcp'},
    {docker  => 'mcp/time'},
    {compose => '/srv/stack', service => 'mcp'},
  ) {
    my ($kind) = grep { $_ ne 'service' } keys %$entry;
    like config_error({%$entry, hub => {fork => true}}),
      qr/mcpServers\.x\.hub\.fork: 'fork' only applies to a 'class' entry/, "not on a '$kind' entry";
  }
};

subtest 'a class entry refuses what it would ignore' => sub {
  for my $fork (0, 1) {
    my $what = $fork ? "a forked 'class' entry" : "a 'class' entry";
    my %hub  = $fork ? (hub => {fork => true}) : ();
    like config_error({class => 'X', env => {A => 1}, %hub}),
      qr/mcpServers\.x\.env: 'env' does not apply to \Q$what\E, which takes its settings through 'args'/,
      "env on $what";
    like config_error({class => 'X', cwd => '/tmp', %hub}),
      qr/mcpServers\.x\.cwd: 'cwd' does not apply to \Q$what\E/, "cwd on $what";
    like config_error({class => 'X', headers => {A => 1}, %hub}),
      qr/mcpServers\.x\.headers: 'headers' does not apply to \Q$what\E/, "headers on $what";
    like config_error({class => 'X', type => 'http', %hub}),
      qr/mcpServers\.x\.type: 'type' does not apply to \Q$what\E/, "type on $what";
  }

  for my $key (qw(idle_timeout request_timeout always_on)) {
    my $value = $key eq 'always_on' ? true : 60;
    like config_error({class => 'X', hub => {$key => $value}}),
      qr/mcpServers\.x\.hub\.$key: '$key' does not apply to an in-process 'class' entry, only with "fork": true/,
      "hub.$key on an in-process class";
  }

  like config_error({class => 'X', hub => {fork => true, bogus => 1}}), qr/mcpServers\.x\.hub\.bogus: unknown key/,
    'an unknown hub key is still named first';
  like config_error({class => 'X', args => ['a'], hub => {fork => true}}),
    qr/mcpServers\.x\.args: must be a JSON object for a 'class' upstream/, 'args stays an object when forked';
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
