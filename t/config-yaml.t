use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(tempdir);
use MCP::Hub;
use MCP::Hub::Config;

# YAML is a second spelling of the same configuration, never a second
# configuration surface: everything here checks that a .yml file lands in the
# same data model, with the same messages, as its JSON twin.

my $dir = tempdir;

sub write_config ($name, $text) {
  my $file = $dir->child($name);
  $file->spurt($text);
  return "$file";
}

# Carp appends the caller's line to every message, so two loads compared for
# equality have to be made from the same line.
sub error_from ($file) {
  eval { MCP::Hub::Config->from_file($file) };
  return $@;
}

# --- the JSON twin ---------------------------------------------------------

subtest 'a YAML config and its JSON twin normalize identically' => sub {
  local $ENV{HUB_TOKEN} = 'sk-hub';

  my $yaml = write_config('twin.yml', <<'YAML');
# the hub my agents talk to
mcpServers:
  context7:
    command: npx
    args: ["-y", "@upstash/context7-mcp"]
  playwright:
    command: npx
    args: ["-y", "@playwright/mcp@latest"]
    hub:
      idle_timeout: 120
      always_on: false
  run:
    class: MCP::Run
    args:
      allowed_commands: ["ls", "cat"]
  remote:
    url: http://example.test/mcp
    headers:
      Authorization: Bearer xyz
hub:
  listen: http://127.0.0.1:3080
  idle_timeout: 600
  profiles:
    full:
      servers: ["*"]
      admin: true
    reader:
      servers: ["context7"]
      tools:
        context7:
          deny: ["dangerous"]
  clients:
    main:
      token: ${HUB_TOKEN}
      profile: full
YAML

  my $json = write_config('twin.json', <<'JSON');
{
  "mcpServers": {
    "context7":   {"command": "npx", "args": ["-y", "@upstash/context7-mcp"]},
    "playwright": {"command": "npx", "args": ["-y", "@playwright/mcp@latest"],
                   "hub": {"idle_timeout": 120, "always_on": false}},
    "run":        {"class": "MCP::Run", "args": {"allowed_commands": ["ls", "cat"]}},
    "remote":     {"url": "http://example.test/mcp",
                   "headers": {"Authorization": "Bearer xyz"}}
  },
  "hub": {
    "listen": "http://127.0.0.1:3080",
    "idle_timeout": 600,
    "profiles": {
      "full":   {"servers": ["*"], "admin": true},
      "reader": {"servers": ["context7"], "tools": {"context7": {"deny": ["dangerous"]}}}
    },
    "clients": {"main": {"token": "${HUB_TOKEN}", "profile": "full"}}
  }
}
JSON

  my $y = MCP::Hub::Config->from_file($yaml);
  my $j = MCP::Hub::Config->from_file($json);

  is_deeply $y->servers,  $j->servers,  'servers normalize identically';
  is_deeply $y->profiles, $j->profiles, 'profiles normalize identically';
  is_deeply $y->clients,  $j->clients,  'clients normalize identically';
  is $y->mode,         $j->mode,         'same derived mode';
  is $y->listen,       $j->listen,       'same listen';
  is $y->idle_timeout, $j->idle_timeout, 'same idle_timeout';

  # Not just "equal to each other" -- equal to what the file says.
  is $y->mode, 'clients', 'clients block derives clients mode';
  is_deeply $y->server_names, [qw(context7 playwright remote run)], 'all four servers';
  is $y->clients->{main}{token}, 'sk-hub', '${VAR} expanded in a YAML value';
};

subtest 'booleans and integers mean what JSON means' => sub {
  my $file = write_config('scalars.yml', <<'YAML');
mcpServers:
  eager:
    command: a
    hub:
      always_on: true
      idle_timeout: 120
  lazy:
    command: b
    hub:
      always_on: false
hub:
  profiles:
    boss:
      servers: ["*"]
      admin: true
    guest:
      servers: ["eager"]
      admin: false
YAML

  my $c = MCP::Hub::Config->from_file($file);
  is $c->server('eager')->{always_on},    1,   'always_on: true -> 1';
  is $c->server('eager')->{idle_timeout}, 120, 'idle_timeout: 120 passes the integer check';
  is $c->server('lazy')->{always_on},     0,   'always_on: false -> 0, not a true string';
  is $c->profiles->{boss}{admin},  1, 'admin: true -> 1';
  is $c->profiles->{guest}{admin}, 0, 'admin: false -> 0';
};

subtest '${VAR} expansion works in YAML values' => sub {
  local %ENV = %ENV;
  delete $ENV{MCP_HUB_TEST_UNSET};
  $ENV{MCP_HUB_TEST_KEY} = 'sk-yaml';
  $ENV{HOME}             = '/home/tester';

  my $file = write_config('expand.yml', <<'YAML');
mcpServers:
  serper:
    command: npx
    args: ["serper@${MCP_HUB_TEST_UNSET:-latest}"]
    env:
      SERPER_API_KEY: ${MCP_HUB_TEST_KEY}
    cwd: ~/work
YAML

  my $e = MCP::Hub::Config->from_file($file)->server('serper');
  is $e->{env}{SERPER_API_KEY}, 'sk-yaml', 'env var expanded from a YAML value';
  is_deeply $e->{args}, ['serper@latest'], '${VAR:-default} works in YAML';
  is $e->{cwd}, '/home/tester/work', 'tilde still expanded';
};

subtest 'a commented-out entry is simply absent' => sub {
  my $file = write_config('commented.yml', <<'YAML');
mcpServers:
  keep:
    command: a
  # noisy, off for the afternoon:
  # drop:
  #   command: b
YAML

  my $c = MCP::Hub::Config->from_file($file);
  is_deeply $c->server_names, ['keep'], 'only the uncommented server is configured';
  is $c->server('drop'), undef, 'the commented-out entry is gone, not empty';
};

# --- errors ----------------------------------------------------------------

subtest 'a validation error reads exactly as it does for JSON' => sub {
  my $yaml = write_config('bad.yml', <<'YAML');
mcpServers:
  playwright:
    command: npx
    hub:
      idle_timeout: soon
YAML
  my $json = write_config('bad.json',
    '{"mcpServers":{"playwright":{"command":"npx","hub":{"idle_timeout":"soon"}}}}');

  my $from_yaml = error_from($yaml);
  my $from_json = error_from($json);

  like $from_yaml, qr/mcpServers\.playwright\.hub\.idle_timeout/, 'dotted path in the YAML error';
  like $from_yaml, qr/must be an integer/,                        'same complaint';
  is $from_yaml, $from_json, 'byte for byte the message the JSON twin produces';
};

subtest 'a syntax error names the file and the line' => sub {
  my $file = write_config('broken.yml', <<'YAML');
mcpServers:
  echo:
    command: npx
     args: [1]
YAML

  eval { MCP::Hub::Config->from_file($file) };
  my $err = $@;
  like $err, qr/^invalid YAML in \Q$file\E: /, 'names the file, in the JSON error style';
  like $err, qr/Line\s*:\s*4/,                 "carries the parser's line number";
  unlike $err, qr{YAML/PP/Parser\.pm},         "not the parser's own source line";
};

subtest 'YAML that JSON could not express is refused' => sub {
  my $multi = write_config('multi.yml', "mcpServers: {}\n---\nmcpServers: {}\n");
  eval { MCP::Hub::Config->from_file($multi) };
  like $@, qr/^invalid YAML in \Q$multi\E: expected a single document, found 2$/m,
    'more than one document is refused';

  # The parser is configured so that no tag can build one, but the guard that
  # keeps the data model JSON-expressible is checked on its own terms.
  eval { MCP::Hub::Config::_assert_json_expressible({mcpServers => {x => bless({}, 'Foo')}}, '') };
  like $@, qr/at mcpServers\.x: unsupported YAML value \(Foo\)/, 'a blessed value is refused with its path';
  eval { MCP::Hub::Config::_assert_json_expressible({hub => [sub { 1 }]}, '') };
  like $@, qr/at hub\[0\]: unsupported YAML value \(CODE\)/, 'a code reference is refused with its path';
  is eval { MCP::Hub::Config::_assert_json_expressible({a => [1, {b => 'c'}]}, ''); 'ok' }, 'ok',
    'plain JSON-shaped data passes';
};

subtest 'duplicate keys are an error, not a silent last-one-wins' => sub {
  my $file = write_config('dup.yml', "mcpServers:\n  a:\n    command: x\n  a:\n    command: y\n");
  eval { MCP::Hub::Config->from_file($file) };
  like $@, qr/^invalid YAML in \Q$file\E: .*Duplicate key/s, 'duplicate key refused';
};

# --- extension dispatch ----------------------------------------------------

subtest 'the extension picks the parser' => sub {
  my $yaml_text = "mcpServers:\n  a:\n    command: x\n";
  my $json_text = '{"mcpServers":{"a":{"command":"x"}}}';

  for my $name (qw(pick.yml pick.yaml PICK.YAML)) {
    my $file = write_config($name, $yaml_text);
    my $c    = eval { MCP::Hub::Config->from_file($file) };
    is_deeply +($c ? $c->server_names : "died: $@"), ['a'], "$name is parsed as YAML";
  }

  for my $name (qw(pick.json pick.mcp pick)) {
    my $file = write_config($name, $json_text);
    my $c    = eval { MCP::Hub::Config->from_file($file) };
    is_deeply +($c ? $c->server_names : "died: $@"), ['a'], "$name is parsed as JSON";

    # and really JSON: YAML block syntax in it is a JSON syntax error
    my $wrong = write_config($name, $yaml_text);
    eval { MCP::Hub::Config->from_file($wrong) };
    like $@, qr/^invalid JSON in \Q$wrong\E/, "$name does not fall back to YAML";
  }

  my $missing = $dir->child('nope.yml')->to_string;
  eval { MCP::Hub::Config->from_file($missing) };
  like $@, qr/^config file not found: \Q$missing\E/, 'a missing YAML file reports as missing';
};

# --- the default path ------------------------------------------------------

subtest 'the default config path tries json, then yml, then yaml' => sub {
  local %ENV = %ENV;
  delete $ENV{MCP_HUB_CONFIG};
  my $home = tempdir;
  my $conf = $home->child('mcp-hub')->make_path;
  $ENV{XDG_CONFIG_HOME} = "$home";
  $ENV{XDG_CACHE_HOME}  = $home->child('cache')->to_string;
  $ENV{MOJO_LOG_LEVEL}  = 'fatal';

  # Least preferred first, so each step proves the *order*, not just existence.
  $conf->child('config.yaml')->spurt("mcpServers:\n  fromyaml:\n    command: x\n");
  my $yaml_only = MCP::Hub->new->hub_config;
  is_deeply $yaml_only->server_names, ['fromyaml'], 'config.yaml is found';

  $conf->child('config.yml')->spurt("mcpServers:\n  fromyml:\n    command: x\n");
  my $yml_too = MCP::Hub->new->hub_config;
  is_deeply $yml_too->server_names, ['fromyml'], 'config.yml wins over config.yaml';

  $conf->child('config.json')->spurt('{"mcpServers":{"fromjson":{"command":"x"}}}');
  my $json_too = MCP::Hub->new->hub_config;
  is_deeply $json_too->server_names, ['fromjson'], 'config.json wins over both';
  is $json_too->source, $conf->child('config.json')->to_string,
    'the resolved source is the file that was actually read';
};

subtest 'nothing in the config dir still names config.json' => sub {
  local %ENV = %ENV;
  delete $ENV{MCP_HUB_CONFIG};
  my $home = tempdir;
  $home->child('mcp-hub')->make_path;
  $ENV{XDG_CONFIG_HOME} = "$home";
  $ENV{XDG_CACHE_HOME}  = $home->child('cache')->to_string;
  $ENV{MOJO_LOG_LEVEL}  = 'fatal';

  my $app = MCP::Hub->new;
  is $app->hub_config->{_missing}, $home->child('mcp-hub', 'config.json')->to_string,
    'the warning points at config.json';
  is_deeply $app->hub_config->server_names, [], 'and the hub starts empty';
};

subtest 'an explicitly given path is used as is' => sub {
  local %ENV = %ENV;
  my $home = tempdir;
  my $conf = $home->child('mcp-hub')->make_path;
  $conf->child('config.json')->spurt('{"mcpServers":{"fromjson":{"command":"x"}}}');
  $ENV{XDG_CONFIG_HOME} = "$home";
  $ENV{XDG_CACHE_HOME}  = $home->child('cache')->to_string;
  $ENV{MOJO_LOG_LEVEL}  = 'fatal';

  my $elsewhere = write_config('explicit.yml', "mcpServers:\n  explicit:\n    command: x\n");
  $ENV{MCP_HUB_CONFIG} = $elsewhere;
  my $explicit = MCP::Hub->new->hub_config;
  is_deeply $explicit->server_names, ['explicit'],
    '$MCP_HUB_CONFIG wins over the default lookup, and keeps its YAML parser';
  is $explicit->source, $elsewhere, 'the explicit path is used exactly as given';
};

done_testing;
