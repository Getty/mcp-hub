#!/usr/bin/env perl
# Keeps the fixtures of the binary checks true against the Perl code:
# scripts/binary-verify.sh and scripts/binary-smoke.sh compare `mcp-hub config`
# with t/fixtures/binary/config.expected, the smoke mounts t/upstream/echo.sh
# -- a stdio MCP server in POSIX sh, for hosts without Perl -- as the upstream it
# starts on tools/call, the TLS checks of both (and scripts/loaded-modules.pl)
# serve https with t/fixtures/binary/tls/server.crt, trusting tls/ca.crt, and the
# smoke verifies tls/le-r11.crt against the binary's trust store.
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(curfile tempdir);
use Mojo::Log;
use Mojo::Promise;
use MCP::Hub;
use MCP::Hub::Upstream::Stdio;

my $FIXTURE = curfile->sibling('fixtures', 'binary');
my $ECHO    = curfile->sibling('upstream', 'echo.sh');
my $HOME    = tempdir;

# What `mcp-hub --config FILE config` prints, and what it logged on the way --
# the upstreams are built inside new(), so the log goes in with it.
sub config_output ($file) {
  local $ENV{MCP_HUB_CONFIG} = "$file";
  local $ENV{HOME}           = "$HOME";
  my @log;
  my $log = Mojo::Log->new;
  $log->unsubscribe('message')->on(message => sub ($l, $level, @lines) { push @log, "[$level] @lines" });
  my $app = MCP::Hub->new(cli => 1, log => $log);
  open my $fh, '>', \my $out or die $!;
  my $old = select $fh;
  my $ok  = eval { $app->start('config'); 1 };
  select $old;
  die $@ unless $ok;
  return ($out, \@log);
}

subtest 'config.json and config.yaml print config.expected' => sub {
  my $want = $FIXTURE->child('config.expected')->slurp;
  for my $name (qw(config.json config.yaml)) {
    my ($out, $log) = config_output($FIXTURE->child($name));
    is $out, $want, "$name prints config.expected";
    is_deeply [grep {/failed to build upstream/} @$log], [], "$name builds every upstream";
  }
};

# A request that is never settled must fail the test instead of hanging it.
sub _await ($promise, $seconds = 10) {
  my $out;
  Mojo::Promise->race(Mojo::Promise->timeout($seconds), $promise)
    ->then(sub { $out = shift })->catch(sub { $out = {err => shift} })->wait;
  return $out;
}

subtest 't/upstream/echo.sh is a stdio MCP server' => sub {
  plan skip_all => 'no sh on PATH' unless grep { -x "$_/sh" } split /:/, $ENV{PATH} // '';
  my $dir    = tempdir;
  my $marker = $dir->child('starts');
  my $up     = MCP::Hub::Upstream::Stdio->new(
    name      => 'echo',
    config    => {type => 'stdio', command => 'sh', args => ["$ECHO", "$marker"]},
    cache_dir => "$dir",
  );

  my $started = _await($up->start_p);
  ok !(ref $started eq 'HASH' && $started->{err}), 'handshake' or diag explain $started;
  is $up->state, 'ready', 'ready after the handshake';
  is_deeply [map { $_->name } @{$up->server->tools}], ['echo'], 'one tool: echo';
  like $marker->slurp, qr/\Astart \d+\n\z/, 'the marker records one start';

  my $r = _await($up->call_tool('echo', {msg => 'hi there'}));
  is $r->{content}[0]{text}, 'hi there', 'echo answers with msg';

  $up->stop;
  Mojo::Promise->timer(0.2)->wait;
  is $up->state, 'stopped', 'stopped';
};

subtest 'the TLS fixtures serve https, verified against their CA only' => sub {
  require Mojo::IOLoop::TLS;
  plan skip_all => 'IO::Socket::SSL 2.009+ required' unless Mojo::IOLoop::TLS->can_tls;
  require IO::Socket::SSL::Utils;
  require Mojo::IOLoop::Server;
  require Mojo::Server::Daemon;
  require Mojo::URL;
  require Mojo::UserAgent;
  require Mojolicious;
  my $tls = $FIXTURE->child('tls');
  my ($ca, $cert, $key) = map { $tls->child($_)->to_string } qw(ca.crt server.crt server.key);

  # No expiry and no clock may break the checks: valid now and for long after.
  for my $file ($ca, $cert) {
    my $c = IO::Socket::SSL::Utils::PEM_file2cert($file);
    my $h = IO::Socket::SSL::Utils::CERT_asHash($c);
    IO::Socket::SSL::Utils::CERT_free($c);
    ok $h->{not_before} <= time && $h->{not_after} > time + 50 * 365 * 86400,
      "$file is valid now and for 50 years more";
  }

  # Nothing from the environment may add the test CA or switch verification off.
  delete local @ENV{qw(MOJO_CA_FILE MOJO_INSECURE SSL_CERT_FILE SSL_CERT_DIR)};
  my $app = Mojolicious->new;
  $app->log->level('fatal');
  $app->routes->get('/' => {text => 'tls ok'});
  my $port   = Mojo::IOLoop::Server->generate_port;
  my $listen = Mojo::URL->new("https://127.0.0.1:$port")->query(cert => $cert, key => $key);
  my $daemon = Mojo::Server::Daemon->new(app => $app, listen => ["$listen"], silent => 1)->start;
  my $url    = "https://127.0.0.1:$port/";

  my %ua = (ioloop => Mojo::IOLoop->singleton, request_timeout => 10);
  my $res = Mojo::UserAgent->new(%ua, ca => $ca)->get($url)->result;
  is $res->body, 'tls ok', 'verified against ca.crt: server.crt names 127.0.0.1 and chains to ca.crt';

  my $tx = Mojo::UserAgent->new(%ua)->get($url);
  like $tx->error && $tx->error->{message}, qr/certificate verify failed/i, 'refused by the default trust store';

  $res = Mojo::UserAgent->new(%ua, insecure => 1)->get($url)->result;
  is $res->body, 'tls ok', 'served with server.key';
  $daemon->stop;
};

# The smoke verifies tls/le-r11.crt against the binary's trust store at 2025-01-01,
# the way this does against Mozilla::CA, the store of last resort packed into it.
subtest 'tls/le-r11.crt chains to a root in Mozilla::CA' => sub {
  plan skip_all => 'IO::Socket::SSL and Mozilla::CA required'
    unless eval { require IO::Socket::SSL; require Mozilla::CA; 1 };
  my $verify_at = sub ($time) {
    my $ctx = Net::SSLeay::CTX_new() or die "CTX_new failed\n";
    Net::SSLeay::CTX_load_verify_locations($ctx, Mozilla::CA::SSL_ca_file(), '') or die "no Mozilla::CA bundle\n";
    my $store = Net::SSLeay::CTX_get_cert_store($ctx);
    my $param = Net::SSLeay::X509_VERIFY_PARAM_new();
    Net::SSLeay::X509_VERIFY_PARAM_set_time($param, $time);
    Net::SSLeay::X509_STORE_set1_param($store, $param);
    my $bio  = Net::SSLeay::BIO_new_file($FIXTURE->child('tls', 'le-r11.crt')->to_string, 'r') or die "no le-r11.crt\n";
    my $cert = Net::SSLeay::PEM_read_bio_X509($bio);
    Net::SSLeay::BIO_free($bio);
    my $vctx = Net::SSLeay::X509_STORE_CTX_new();
    Net::SSLeay::X509_STORE_CTX_init($vctx, $store, $cert);
    my $ok = Net::SSLeay::X509_verify_cert($vctx) == 1
      ? 'verified' : Net::SSLeay::X509_verify_cert_error_string(Net::SSLeay::X509_STORE_CTX_get_error($vctx));
    Net::SSLeay::X509_STORE_CTX_free($vctx);
    Net::SSLeay::X509_free($cert);
    Net::SSLeay::CTX_free($ctx);
    return $ok;
  };
  is $verify_at->(1735689600), 'verified', 'verified at 2025-01-01, the time the smoke checks at';
  like $verify_at->(1900000000), qr/expired/, 'refused after its expiry: the fixed time is what passes it';
};

done_testing;
