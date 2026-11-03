#!/usr/bin/env bash
# Verify a packed mcp-hub against `perl -Ilib bin/mcp-hub` from this checkout.
#   scripts/verify-binary.sh <binary>
# Run it where the binary was built (same perl, same installed modules): the module set
# it requires inside the archive is computed by scripts/loaded-modules.pl on this host.
# scripts/smoke-binary.sh is the other half: the daemon, on a machine without Perl.
set -euo pipefail

[ -n "${1:-}" ] || { echo "usage: verify-binary.sh <binary>" >&2; exit 1; }
BIN=$(perl -MCwd=abs_path -e 'print abs_path(shift) // ""' "$1")
[ -n "$BIN" ] || { echo "FAIL: cannot resolve path: $1" >&2; exit 1; }
[ -x "$BIN" ] || { echo "FAIL: not an executable: $BIN" >&2; exit 1; }
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home" "$work/par"

fail() { echo "FAIL: $*" >&2; exit 1; }
tmo=${MCP_HUB_VERIFY_TIMEOUT:-120}
# timeout(1) where it exists (GNU coreutils); a perl alarm wrapper where it does not (macOS).
if command -v timeout >/dev/null 2>&1; then TMO=(timeout "$tmo")
else TMO=(perl -e 'alarm shift; exec @ARGV' "$tmo"); fi

# The binary under a wiped environment (no PERL5LIB, no config) and its own extraction
# cache: PAR_GLOBAL_TMPDIR is where PAR unpacks, so a fresh directory is a first start.
bin() { env -i PATH=/usr/bin:/bin HOME="$work/home" PAR_GLOBAL_TMPDIR="$work/par" "${TMO[@]}" "$BIN" "$@" </dev/null; }
# The reference: the same CLI from the checkout, same HOME, no configuration of the
# maintainer's, no reactor choice, no trust store or proxy of this shell's. PERL5LIB
# stays: that is where the deps are.
ref() {
  env -u MCP_HUB_CONFIG -u XDG_CONFIG_HOME -u XDG_CACHE_HOME -u CLAUDE_CONFIG_DIR \
      -u MOJO_MODE -u MOJO_REACTOR -u MOJO_HOME -u MOJO_CA_FILE -u MOJO_INSECURE \
      -u SSL_CERT_FILE -u SSL_CERT_DIR -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy \
      HOME="$work/home" \
      "${TMO[@]}" perl -I"$root/lib" "$root/bin/mcp-hub" "$@" </dev/null
}

# same_as_perl CASE ARGS...: STDOUT and exit code of the binary match the checkout's perl
# run. The reference must have printed something (empty on both sides proves nothing);
# EXPECT_EMPTY=1 for a case that prints nothing. STDERR is not compared (log lines carry
# a timestamp and a pid); STDERR_PATTERN requires both runs to report it there.
same_as_perl() {
  local name=$1; shift
  local rc_want=0 rc_got=0
  ref "$@" >"$work/want" 2>"$work/want.err" || rc_want=$?
  bin "$@" >"$work/got" 2>"$work/got.err" || rc_got=$?
  [ "$rc_want" = "$rc_got" ] || fail "$name: exit code differs (binary $rc_got, perl $rc_want): $(head -n 3 "$work/got.err")"
  if [ -z "${EXPECT_EMPTY:-}" ]; then
    [ -s "$work/want" ] || fail "$name: the perl reference printed nothing, the case proves nothing"
  fi
  cmp -s "$work/want" "$work/got" \
    || fail "$name: STDOUT differs from perl -Ilib: $(diff "$work/want" "$work/got" | head -n 6)"
  if [ -n "${STDERR_PATTERN:-}" ]; then
    grep -q -- "$STDERR_PATTERN" "$work/want.err" || fail "$name: perl run lacks '$STDERR_PATTERN' on STDERR"
    grep -q -- "$STDERR_PATTERN" "$work/got.err"  || fail "$name: binary run lacks '$STDERR_PATTERN' on STDERR: $(head -n 3 "$work/got.err")"
  fi
  # Nothing of the packer on STDERR: no "Can't locate", no PAR complaint.
  if grep -E "Can't locate|PAR|did not return a true value" "$work/got.err" >/dev/null; then
    fail "$name: the binary reports a packing problem: $(grep -E "Can't locate|PAR|did not return" "$work/got.err" | head -n 3)"
  fi
}

want_version=$(sed -n "s/^our \$VERSION = '\(.*\)';/\1/p" "$root/lib/MCP/Hub.pm")
[ -n "$want_version" ] || fail "cannot read \$VERSION from lib/MCP/Hub.pm"

# Fixtures by relative path, as the smoke and t/binary.t use them.
cd "$root"

# Startup on a fresh cache (the extraction run), then a second start on the same cache.
# (STDERR to a file: without a config file every command warns that there is none.)
v() { bin eval 'print MCP::Hub->VERSION' 2>"$work/v.err" || { cat "$work/v.err" >&2; return 1; }; }
out=$(v) || fail "eval failed on a fresh cache"
[ "$out" = "$want_version" ] || fail "MCP::Hub->VERSION is '$out', want '$want_version'"
echo "startup (fresh cache): OK (MCP::Hub $out)"
out=$(v) || fail "eval failed on the second start"
[ "$out" = "$want_version" ] || fail "second start: MCP::Hub->VERSION is '$out'"
echo "second start (same cache): OK"

# token prints exactly one line: 32 random bytes, base64url, nothing else on STDOUT.
t1=$(bin token 2>"$work/t.err") || fail "token failed: $(cat "$work/t.err")"
t2=$(bin token 2>"$work/t.err") || fail "token failed: $(cat "$work/t.err")"
printf '%s\n' "$t1" | grep -Eqx '[A-Za-z0-9_-]{43}' || fail "token prints '$t1', want 43 base64url characters"
[ "$t1" != "$t2" ] || fail "token printed the same value twice"
echo "token: OK"

# The command layer: Mojolicious finds every command by namespace, the usage text comes
# from each module's POD (pp strips POD unless PAR_VERBATIM=1 -- build-binary.sh).
same_as_perl "no command (the command list)"
same_as_perl "help" help
same_as_perl "--help" --help
for c in daemon config status refresh reload token eval get routes version; do
  same_as_perl "help $c" help "$c"
  grep -q '^Usage: ' "$work/got" || fail "help $c: no usage text (POD stripped?)"
done
STDERR_PATTERN='Unknown command "nope"' EXPECT_EMPTY=1 same_as_perl "unknown command" nope
echo "commands and help: OK"

# config: JSON and YAML (YAML::PP is loaded on demand only) print the same, and what
# t/fixtures/binary/config.expected says. Every kind of entry is in the fixture: stdio,
# the three natives, url, docker, compose.
for f in json yaml; do
  same_as_perl "config ($f)" --config "t/fixtures/binary/config.$f" config
  cmp -s "$work/got" t/fixtures/binary/config.expected || fail "config ($f): differs from t/fixtures/binary/config.expected"
  if grep -q 'failed to build upstream' "$work/got.err"; then fail "config ($f): $(grep 'failed to build' "$work/got.err" | head -n 2)"; fi
done
same_as_perl "config --all" --config t/fixtures/binary/config.yaml config --all
cat >"$work/clients.json" <<'JSON'
{"mcpServers": {"hub": {"class": "MCP::Hub::Native::Status"}},
 "hub": {"profiles": {"all": {"admin": true}},
         "clients": {"main": {"token": "secret-token", "profile": "all"}}}}
JSON
same_as_perl "config --client (clients mode)" --config "$work/clients.json" config --client main
echo "config: OK"

# Error paths: the message on STDERR, the same exit code, nothing on STDOUT.
printf '{ "mcpServers": ' >"$work/broken.json"
printf 'mcpServers: [\n' >"$work/broken.yml"
printf '{ "hub": { "bogus_key": true } }' >"$work/unknown.json"
STDERR_PATTERN='invalid JSON in'     EXPECT_EMPTY=1 same_as_perl "broken JSON"  --config "$work/broken.json" config
STDERR_PATTERN='invalid YAML in'     EXPECT_EMPTY=1 same_as_perl "broken YAML"  --config "$work/broken.yml" config
STDERR_PATTERN='at hub.bogus_key'    EXPECT_EMPTY=1 same_as_perl "unknown key"  --config "$work/unknown.json" config
STDERR_PATTERN='a client name is required' EXPECT_EMPTY=1 same_as_perl "clients mode without --client" --config "$work/clients.json" config
STDERR_PATTERN='no configuration file at' same_as_perl "missing config file" --config "$work/nope.json" config
echo "error paths: OK"

same_as_perl "routes" routes
same_as_perl "eval" eval 'print MCP::Hub::Config->can("from_file") ? "ok\n" : "missing\n"'
echo "routes, eval: OK"

# EV is left out on purpose (scripts/loaded-modules.pl --left-out): the packed hub runs
# on Mojo::Reactor::Poll, whatever the build host has installed.
reactor=$(bin eval 'print ref Mojo::IOLoop->singleton->reactor' 2>"$work/r.err") || fail "eval (reactor) failed: $(cat "$work/r.err")"
[ "$reactor" = Mojo::Reactor::Poll ] || fail "the binary runs on '$reactor', want Mojo::Reactor::Poll (EV must not be packed)"
echo "reactor: OK ($reactor)"

# TLS is packed: IO::Socket::SSL on Net::SSLeay, with the OpenSSL 3 that Net::SSLeay
# was built against. Its OPENSSLDIR is where IO::Socket::SSL looks for the host's trust
# store (cert.pem and certs/ below it) before it falls back to Mozilla::CA.
same_as_perl "TLS available" eval 'print Mojo::IOLoop::TLS->can_tls ? "tls\n" : "no tls\n"'
grep -qx tls "$work/got" || fail "the binary has no TLS: IO::Socket::SSL is not packed or does not load"
same_as_perl "OpenSSL" eval 'print Net::SSLeay::SSLeay_version(0), "\n", Net::SSLeay::SSLeay_version(4), "\n"'
grep -q '^OpenSSL 3\.' "$work/got" || fail "the binary's OpenSSL is not a 3.x: $(head -n 1 "$work/got")"
echo "TLS: OK ($(head -n 1 "$work/got"), $(sed -n 2p "$work/got"))"
# The trust store of last resort: Mozilla::CA's bundle, read from the path the module
# computes -- inside PAR's cache.
same_as_perl "Mozilla::CA bundle" eval 'require Mozilla::CA; open my $fh, "<", Mozilla::CA::SSL_ca_file() or die "$!\n"; my $n = grep { /BEGIN CERTIFICATE/ } <$fh>; print $n > 100 ? "bundle: ok\n" : "bundle: $n certificates\n"'
grep -qx 'bundle: ok' "$work/got" || fail "Mozilla::CA bundle: $(cat "$work/got")"
echo "trust store of last resort: OK (Mozilla::CA $(bin eval 'require Mozilla::CA; print Mozilla::CA->VERSION' 2>/dev/null))"
# A round trip inside the binary: the hub on https with the test certificate
# (t/fixtures/binary/tls), a client that trusts the test CA, one that trusts only the
# default store and must be refused, and one with verification off.
same_as_perl "TLS round trip" eval '
  use Mojo::Server::Daemon;
  my $dir = "t/fixtures/binary/tls";
  my $d   = Mojo::Server::Daemon->new(app => app, silent => 1,
    listen => ["https://127.0.0.1?cert=$dir/server.crt&key=$dir/server.key"])->start;
  my $url  = "https://127.0.0.1:" . $d->ports->[0] . "/_hub/status";
  my $loop = Mojo::IOLoop->singleton;
  print "test CA: ", Mojo::UserAgent->new(ioloop => $loop, ca => "$dir/ca.crt")->get($url)->result->code, "\n";
  my $err = Mojo::UserAgent->new(ioloop => $loop)->get($url)->error // {};
  print "default trust store: ", (($err->{message} // "") =~ /certificate verify failed/ ? "refused" : "not refused"), "\n";
  print "insecure: ", Mojo::UserAgent->new(ioloop => $loop, insecure => 1)->get($url)->result->code, "\n";'
printf 'test CA: 200\ndefault trust store: refused\ninsecure: 200\n' | cmp -s - "$work/got" \
  || fail "TLS round trip: $(cat "$work/got")"
echo "TLS round trip: OK (verified with the test CA, refused without it)"

# Packed module set. Inside the binary @INC is the archive only -- no PERL5LIB, no
# compiled-in path -- so a module the build missed dies at run time. The loaded set
# (scripts/loaded-modules.pl, the same list build-binary.sh packs) must be in the archive.
command -v unzip >/dev/null 2>&1 || fail "unzip is not installed (needed to inspect the PAR archive)"
rc=0; unzip -qq -o "$BIN" -d "$work/archive" >/dev/null 2>&1 || rc=$?   # 1 = bytes before the zip
[ "$rc" -le 1 ] && [ -d "$work/archive/lib" ] || fail "cannot unpack the PAR archive (unzip exit $rc)"
perl -I"$root/lib" "$root/scripts/loaded-modules.pl" >"$work/loaded" 2>"$work/loaded.err" \
  || fail "scripts/loaded-modules.pl failed: $(cat "$work/loaded.err")"
nloaded=$(wc -l <"$work/loaded" | tr -d ' ')
[ "$nloaded" -gt 150 ] || fail "loaded set suspiciously small ($nloaded modules)"
# EXTRA_PACKED_CHECK="Not::Packed" adds names (to prove the check can fail).
missing=
for m in $(cat "$work/loaded") ${EXTRA_PACKED_CHECK:-}; do
  f="$(echo "$m" | sed 's#::#/#g').pm"
  [ -f "$work/archive/lib/$f" ] || [ -f "$work/archive/arch/$f" ] || missing="$missing $f"
done
[ -z "$missing" ] || fail "modules missing inside the PAR archive:$missing (run verify where the binary was built)"
echo "packed module set: OK ($nloaded modules)"

# The left-out families must not be in the archive, whatever this host has installed.
leaked=
for spec in $(perl "$root/scripts/loaded-modules.pl" --left-out); do
  p=$(echo "${spec%::}" | sed 's#::#/#g')
  case "$spec" in
    *::) hit=$(cd "$work/archive" && { find lib arch -path "*/$p/*" -name '*.pm' 2>/dev/null || true; } | head -n 1) ;;
    *)   hit=$(cd "$work/archive" && { ls "lib/$p.pm" "arch/$p.pm" 2>/dev/null || true; } | head -n 1) ;;
  esac
  [ -z "$hit" ] || leaked="$leaked $hit"
done
[ -z "$leaked" ] || fail "left-out modules packed:$leaked (build-binary.sh must -X them)"
echo "left-out families absent: OK"

# Files read from a path next to a module: Mojolicious' templates (next to
# Mojolicious/Renderer.pm), the certificate an https listen without cert= uses (next to
# Mojo/IOLoop/TLS.pm), Mozilla::CA's bundle (next to Mozilla/CA.pm).
for f in Mojolicious/resources/templates/mojo/debug.html.ep Mojolicious/resources/templates/mojo/exception.html.ep \
         Mojolicious/resources/templates/mojo/not_found.html.ep \
         Mojo/IOLoop/resources/server.crt Mojo/IOLoop/resources/server.key Mozilla/CA/cacert.pem; do
  [ -f "$work/archive/lib/$f" ] || fail "$f not packed"
done
echo "resources: OK"
echo "verify: OK"
