#!/usr/bin/env perl
# bin/mcp-hub itself, run as a child: the global --config is parsed there, before
# any command sees the arguments.
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(curfile tempdir);
use Mojo::JSON qw(decode_json encode_json);

my $BIN = curfile->dirname->sibling('bin', 'mcp-hub')->to_string;
my $DIR = tempdir;

# Nothing from this machine may reach the child: no real config, no real cache,
# no CGI/PSGI detection.
$ENV{HOME} = $ENV{XDG_CONFIG_HOME} = $ENV{XDG_CACHE_HOME} = "$DIR";
delete @ENV{qw(MCP_HUB_CONFIG MCP_HUB_CONFIG_DIR MCP_HUB_TOKEN CLAUDE_CONFIG_DIR
  PLACK_ENV PATH_INFO GATEWAY_INTERFACE MOJO_NO_DETECT MOJO_MODE MOJO_HOME)};

# Two configs that differ in the one server they mount, so the output names the
# file that was read.
my %config;
for my $name (qw(alpha beta)) {
  my $file = $DIR->child("$name.json");
  $file->spew(encode_json({mcpServers => {$name => {class => 'MCP::Hub::Native::Status'}}}));
  $config{$name} = "$file";
}

# Run perl with the @INC of this test (lib/ first, not an installed MCP::Hub):
# STDOUT, STDERR and the exit code.
sub perl_child (@args) {
  my $err = $DIR->child('stderr');
  my $pid = open(my $out, '-|') // die "fork: $!";
  unless ($pid) {
    open STDERR, '>', "$err" or die $!;
    exec $^X, (map {"-I$_"} grep { !ref } @INC), @args or die "exec: $!";
  }
  my $stdout = do { local $/; <$out> };
  close $out;
  return {out => $stdout, err => $err->slurp, exit => $? >> 8};
}

# Run bin/mcp-hub.
sub mcp_hub (@args) { perl_child($BIN, @args) }

# The answer to the initialize request -- only /alpha, mounted by alpha.json,
# can give it, and only if the JSON arrived as the request body.
sub initialized ($r) {
  my $res = eval { decode_json($r->{out}) } // {};
  return ($res->{id} // 0) == 1 && ($res->{result}{protocolVersion} // '') eq '2025-06-18';
}

sub servers ($r) {
  my $data = eval { decode_json($r->{out}) } or return [];
  return [sort keys %{$data->{mcpServers}}];
}

subtest 'the global forms before the command select the config file' => sub {
  for my $form (['--config', $config{alpha}], ['-c', $config{alpha}], ["--config=$config{alpha}"]) {
    my $r = mcp_hub(@$form, 'config');
    is $r->{exit}, 0, "mcp-hub @$form config exits 0" or diag $r->{err};
    is_deeply servers($r), ['alpha'], '...and prints the servers of that file';
  }

  local $ENV{MCP_HUB_CONFIG} = $config{alpha};
  my $r = mcp_hub('config');
  is_deeply servers($r), ['alpha'], '$MCP_HUB_CONFIG selects it too';
  $r = mcp_hub('--config', $config{beta}, 'config');
  is_deeply servers($r), ['beta'], '...and --config wins over it';
  $r = mcp_hub('-c', $config{alpha}, '--config', $config{beta}, 'config');
  is_deeply servers($r), ['beta'], 'several global options: the last one wins';
};

subtest 'a global --config without a PATH fails instead of reading another file' => sub {
  # Regression: a missing PATH left MCP_HUB_CONFIG undef, so the hub read the
  # default file instead; an empty one made it read no file, without a word.
  local $ENV{MCP_HUB_CONFIG} = $config{alpha};
  for my $case (
    ['--config', '--config'], ['-c', '-c'], ['--config', '--config='],
    ['--config', '--config', ''], ['-c', '-c', ''],
    ['--config', '--config', '', 'config'], ['--config', '--config=', 'config'],
    ['-c', '-c', $config{beta}, '-c'],
  ) {
    my ($opt, @args) = @$case;
    my $r = mcp_hub(@args);
    isnt $r->{exit}, 0, "mcp-hub @args fails";
    is $r->{err}, "option $opt needs a PATH\n", "...saying option $opt needs a PATH";
    is $r->{out}, '', '...and prints nothing';
  }
};

subtest 'hypnotoad cannot load mcp-hub to serve it pre-forked' => sub {
  delete local @ENV{grep {/^HYPNOTOAD_/} keys %ENV};
  local $ENV{MCP_HUB_CONFIG} = $config{alpha};
  my $refused = qr/mcp-hub refuses to run under hypnotoad: the hub is one process that owns every upstream and all state; /;
  my $load    = 'my $app = Mojo::Server->new->load_app(shift); print ref $app';

  # Hypnotoad's own run, as "hypnotoad bin/mcp-hub" reaches it: HYPNOTOAD_REV
  # skips its clean-start re-exec, and should the refusal ever stop working,
  # HYPNOTOAD_TEST makes it exit once the app is loaded, before it forks.
  {
    local @ENV{qw(HYPNOTOAD_REV HYPNOTOAD_TEST)} = (1, 1);
    my $r = perl_child('-MMojo::Server::Hypnotoad', '-e', 'Mojo::Server::Hypnotoad->new->run(shift)', $BIN);
    isnt $r->{exit}, 0, 'hypnotoad bin/mcp-hub fails';
    like $r->{err}, $refused, '...refused, saying why';
    like $r->{err}, qr/Run "mcp-hub daemon" instead\.\n\z/, '...and pointing at mcp-hub daemon';
    unlike $r->{out}, qr/Everything looks good/, '...and hypnotoad never got the app';
  }

  # Either sign alone is enough.
  {
    local $ENV{HYPNOTOAD_APP} = $BIN;
    my $r = perl_child('-MMojo::Server', '-e', $load, $BIN);
    isnt $r->{exit}, 0,      'loaded as an app with HYPNOTOAD_APP set: fails';
    like $r->{err}, $refused, '...refused';
    is $r->{out}, '',         '...and no app';
  }
  my $r = perl_child('-MMojo::Server::Hypnotoad', '-e', $load, $BIN);
  isnt $r->{exit}, 0,      'loaded as an app with Mojo::Server::Hypnotoad loaded: fails';
  like $r->{err}, $refused, '...refused';
  is $r->{out}, '',         '...and no app';

  # Neither: a one-process loader (Test::Mojo->new($script), morbo) still gets
  # the app, and HYPNOTOAD_APP inherited by a command line stops nothing.
  $r = perl_child('-MMojo::Server', '-e', $load, $BIN);
  is $r->{exit}, 0, 'loaded as an app without hypnotoad: works' or diag $r->{err};
  is $r->{out}, 'MCP::Hub', '...and hands over the hub';

  local $ENV{HYPNOTOAD_APP} = $BIN;
  $r = mcp_hub('config');
  is $r->{exit}, 0, 'mcp-hub config with HYPNOTOAD_APP set but not loaded as an app: works' or diag $r->{err};
  is_deeply servers($r), ['alpha'], '...and prints the configuration';
};

subtest "after the command, -c is the command's own option" => sub {
  my $rpc = encode_json({
    jsonrpc => '2.0', id => 1, method => 'initialize',
    params  => {protocolVersion => '2025-06-18', capabilities => {}, clientInfo => {name => 't', version => '1'}},
  });
  my @get = ('get', '-M', 'POST', '-H', 'Content-Type: application/json', '-c', $rpc, '/alpha');

  # Regression: -c anywhere in argv was taken as the config path, so the JSON
  # became a (missing) config file and get posted nothing to a hub with no
  # servers.
  for my $global (['--config', $config{alpha}], ['-c', $config{alpha}]) {
    my $r = mcp_hub(@$global, @get);
    is $r->{exit}, 0, "mcp-hub @$global get -c JSON /alpha exits 0" or diag $r->{err};
    unlike $r->{err}, qr/no configuration file/, '...the JSON is not read as a config path';
    ok initialized($r), '...it is the request body /alpha answers';
  }

  local $ENV{MCP_HUB_CONFIG} = $config{alpha};
  ok initialized(mcp_hub(@get)), 'with $MCP_HUB_CONFIG and no global option as well';

  # No global option after the command any more: config has no --config of
  # its own, so the option is refused rather than quietly reading a file.
  my $r = mcp_hub('config', '--config', $config{beta});
  isnt $r->{exit}, 0,               'mcp-hub config --config FILE fails';
  like $r->{err}, qr/Unknown option: config/, '...on an unknown option';
  is_deeply servers($r), [],        '...and prints no configuration';
};

done_testing;
