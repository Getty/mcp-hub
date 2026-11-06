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

# Run bin/mcp-hub with the @INC of this test (lib/ first, not an installed
# MCP::Hub): STDOUT, STDERR and the exit code.
sub mcp_hub (@args) {
  my $err = $DIR->child('stderr');
  my $pid = open(my $out, '-|') // die "fork: $!";
  unless ($pid) {
    open STDERR, '>', "$err" or die $!;
    exec $^X, (map {"-I$_"} grep { !ref } @INC), $BIN, @args or die "exec: $!";
  }
  my $stdout = do { local $/; <$out> };
  close $out;
  return {out => $stdout, err => $err->slurp, exit => $? >> 8};
}

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
