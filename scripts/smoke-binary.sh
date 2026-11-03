#!/usr/bin/env bash
# Smoke-test a packed mcp-hub where no Perl is needed: bash, sh, coreutils, grep and
# sed are all it uses (HTTP goes through bash's /dev/tcp), so it runs as-is in a bare
# distribution container.
#   scripts/smoke-binary.sh <binary>
# SMOKE_NO_PERL=1 additionally fails when a perl is on PATH, to prove the point.
#
# Covered: a cold and a warm start, token, config (JSON and YAML, every kind of
# entry), an error path, and two daemon runs -- the first fetches the stdio
# upstream's manifest once, the second serves tools/list from that cache without
# starting it, starts it on tools/call (t/upstream/echo.sh, a stdio MCP server in
# POSIX sh), answers a native and a remote HTTP upstream and Mojolicious' 404 page,
# and leaves no child behind on SIGTERM. Then TLS, with no curl or openssl on the
# host -- the binary is every client: a hub listening on https with the test
# certificate (t/fixtures/binary/tls), verified through SSL_CERT_FILE and refused
# without it, which trust store the binary finds on this host and that it verifies
# a real chain there (Let's Encrypt's R11, a fixture, at a fixed time, offline), and
# a second https hub whose `url` upstream is the first. scripts/verify-binary.sh is
# the other half: the same CLI against `perl -Ilib`, and the packed module set.
set -euo pipefail

[ -n "${1:-}" ] || { echo "usage: smoke-binary.sh <binary>" >&2; exit 1; }
BIN=$1; case "$BIN" in /*) ;; *) BIN="$PWD/$BIN" ;; esac
[ -x "$BIN" ] || { echo "FAIL: not an executable: $BIN" >&2; exit 1; }
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
daemon_pid= tls_pid= front_pid=
cleanup() {
  local p
  for p in $daemon_pid $tls_pid $front_pid; do kill -TERM "$p" 2>/dev/null; done
  rm -rf "$work"
}
trap cleanup EXIT
fail() {
  echo "FAIL: $*" >&2
  for f in "$work"/daemon*.log; do [ -s "$f" ] && { echo "--- $f (tail)" >&2; tail -n 20 "$f" >&2; }; done
  exit 1
}

# Nothing of this host's Perl or of anybody's configuration, trust store or proxy.
unset PERL5LIB PERL5OPT MCP_HUB_CONFIG XDG_CONFIG_HOME XDG_CACHE_HOME CLAUDE_CONFIG_DIR \
      MOJO_MODE MOJO_REACTOR MOJO_HOME MOJO_LOG_LEVEL MOJO_CA_FILE MOJO_INSECURE \
      SSL_CERT_FILE SSL_CERT_DIR HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
export HOME="$work/home" PAR_GLOBAL_TMPDIR="$work/par"
mkdir -p "$HOME" "$PAR_GLOBAL_TMPDIR"
if command -v perl >/dev/null 2>&1; then
  [ -z "${SMOKE_NO_PERL:-}" ] || fail "SMOKE_NO_PERL=1 but perl is on PATH: $(command -v perl)"
  echo "note: a perl is on PATH ($(command -v perl)); the binary does not use it"
else
  echo "no perl on this host"
fi
cd "$root"

now() { if [ -n "${EPOCHREALTIME:-}" ]; then echo "${EPOCHREALTIME/,/.}"; else date +%s; fi; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", b - a }'; }

# --- start-up: a cold PAR cache (the extraction run), then a warm one ---------------
# One start at a time: concurrent first starts on a cold cache crash in PAR's unpacking.
want_version=$(sed -n "s/^our \$VERSION = '\(.*\)';/\1/p" lib/MCP/Hub.pm)
t0=$(now); v1=$("$BIN" eval 'print MCP::Hub->VERSION' 2>"$work/err") || fail "cold start: $(cat "$work/err")"
t1=$(now); v2=$("$BIN" eval 'print MCP::Hub->VERSION' 2>"$work/err") || fail "warm start: $(cat "$work/err")"
t2=$(now)
[ "$v1" = "$want_version" ] && [ "$v2" = "$want_version" ] || fail "MCP::Hub->VERSION is '$v1'/'$v2', want '$want_version'"
echo "start: cold $(secs "$t0" "$t1")s, warm $(secs "$t1" "$t2")s (MCP::Hub $v1)"

# --- token: one line on STDOUT, 43 base64url characters, fresh every time -----------
"$BIN" token >"$work/t1" 2>"$work/err" || fail "token: $(cat "$work/err")"
"$BIN" token >"$work/t2" 2>"$work/err" || fail "token: $(cat "$work/err")"
[ "$(wc -l <"$work/t1" | tr -d ' ')" = 1 ] || fail "token: STDOUT is not exactly one line: $(head -c 200 "$work/t1")"
grep -Eqx '[A-Za-z0-9_-]{43}' "$work/t1" || fail "token: '$(cat "$work/t1")' is not 43 base64url characters"
[ "$(cat "$work/t1")" != "$(cat "$work/t2")" ] || fail "token: the same value twice"
echo "token: OK ($(cut -c1-6 "$work/t1")...)"

# --- config: JSON and YAML (YAML::PP, loaded on demand) print the expected client config
want=$(cat t/fixtures/binary/config.expected)
for f in json yaml; do
  "$BIN" --config "t/fixtures/binary/config.$f" config >"$work/out" 2>"$work/err" || fail "config ($f): $(cat "$work/err")"
  [ "$(cat "$work/out")" = "$want" ] || fail "config ($f): STDOUT differs from t/fixtures/binary/config.expected: $(head -c 300 "$work/out")"
  if grep -q 'failed to build upstream' "$work/err"; then fail "config ($f): $(grep 'failed to build' "$work/err")"; fi
done
echo "config: OK (JSON and YAML, $(grep -c '"url"' t/fixtures/binary/config.expected) entries)"

printf '{ "mcpServers": ' >"$work/broken.json"
rc=0; "$BIN" --config "$work/broken.json" config >"$work/out" 2>"$work/err" || rc=$?
[ "$rc" != 0 ] || fail "a broken config exits 0"
[ ! -s "$work/out" ] || fail "a broken config prints to STDOUT: $(head -c 200 "$work/out")"
grep -q 'invalid JSON in' "$work/err" || fail "a broken config: no 'invalid JSON in' on STDERR: $(head -n 3 "$work/err")"
echo "error path: OK (exit $rc)"

# --- the daemon ------------------------------------------------------------------
port=$(( 20000 + RANDOM % 20000 ))
marker="$work/echo-starts"; : >"$marker"
cat >"$work/hub.json" <<JSON
{"mcpServers": {
   "echo":    {"command": "sh", "args": ["$root/t/upstream/echo.sh", "$marker"]},
   "history": {"class": "MCP::Hub::Native::ClaudeHistory", "args": {"root": "$root/t/fixtures/claude"}},
   "hub":     {"class": "MCP::Hub::Native::Status"},
   "remote":  {"url": "http://127.0.0.1:$port/history"},
   "boxed":   {"docker": "example/mcp-server:1"}},
 "hub": {"listen": "http://127.0.0.1:$port", "cache_dir": "$work/cache",
         "docker_command": "$work/no-such-docker"}}
JSON
starts() { wc -l <"$marker" | tr -d ' '; }

# http METHOD PATH [JSON]: the raw response (headers and body) on STDOUT.
http() {
  local body=${3:-}
  exec 3<>"/dev/tcp/127.0.0.1/$port" || return 1
  printf '%s %s HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAccept: application/json, text/event-stream, text/html\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
    "$1" "$2" "$port" "${#body}" "$body" >&3
  timeout 30 cat <&3
  exec 3<&-
}
id=0
# mcp SERVER METHOD [PARAMS]: one JSON-RPC request; waits out a 503 (manifest still fetching).
mcp() {
  local i out params=${3:-}
  [ -n "$params" ] || params='{}'
  id=$((id + 1))
  for i in $(seq 1 100); do
    out=$(http POST "/$1" "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"$2\",\"params\":$params}") || true
    case "$out" in "HTTP/1.1 503"*) sleep 0.2 ;; *) break ;; esac
  done
  printf '%s\n' "$out"
}
start_daemon() {
  "$BIN" --config "$work/hub.json" daemon >"$work/daemon$1.out" 2>"$work/daemon$1.log" &
  daemon_pid=$!
  local i out
  for i in $(seq 1 100); do
    out=$(http GET /_hub/status 2>/dev/null) || true
    grep -q '"upstreams"' <<<"$out" && return 0
    kill -0 "$daemon_pid" 2>/dev/null || fail "daemon run $1 exited at start-up"
    sleep 0.2
  done
  fail "daemon run $1 did not answer on 127.0.0.1:$port"
}
stop_daemon() {
  local rc=0
  kill -TERM "$daemon_pid"; wait "$daemon_pid" || rc=$?
  daemon_pid=
  # 143: ended by the TERM itself, as perl -Ilib bin/mcp-hub daemon does.
  [ "$rc" = 0 ] || [ "$rc" = 143 ] || fail "daemon exited $rc on SIGTERM"
}

# Run 1: a cold manifest cache. The hub fetches echo's manifest once in the background.
start_daemon 1
out=$(mcp echo tools/list)
grep -q '"name":"echo"' <<<"$out" || fail "run 1: tools/list on /echo: $(printf '%s' "$out" | tail -n 1 | head -c 300)"
[ "$(starts)" -ge 1 ] || fail "run 1: echo was never started to fetch its manifest"
stop_daemon
echo "daemon run 1 (cold manifest cache): OK (echo started $(starts)x to fetch its manifest)"

# Run 2: the cached manifest. tools/list starts nothing, tools/call starts echo.
: >"$marker"
start_daemon 2
out=$(mcp history tools/list)
grep -q '"name":"list_projects"' <<<"$out" || fail "tools/list on /history (native): $(printf '%s' "$out" | tail -n 1 | head -c 300)"
echo "tools/list /history (native ClaudeHistory): OK"
out=$(mcp echo tools/list)
grep -q '"name":"echo"' <<<"$out" || fail "tools/list on /echo: $(printf '%s' "$out" | tail -n 1 | head -c 300)"
[ "$(starts)" = 0 ] || fail "tools/list on /echo started the upstream (lazy start broken): $(cat "$marker")"
echo "tools/list /echo (stdio, from the manifest cache): OK, nothing started"
out=$(mcp echo tools/call '{"name":"echo","arguments":{"msg":"smoke-hello-42"}}')
grep -q 'smoke-hello-42' <<<"$out" || fail "tools/call echo: $(printf '%s' "$out" | tail -n 3 | head -c 300)"
[ "$(starts)" = 1 ] || fail "tools/call on /echo: echo started $(starts)x, want 1"
echo_pid=$(sed -n 's/^start //p' "$marker")
echo "tools/call /echo: OK, started sh t/upstream/echo.sh (pid $echo_pid) and echoed smoke-hello-42"
out=$(mcp remote tools/call '{"name":"list_projects","arguments":{}}')
grep -q 'proj-a' <<<"$out" || fail "tools/call on /remote (HTTP upstream): $(printf '%s' "$out" | tail -n 1 | head -c 300)"
echo "tools/call /remote (HTTP upstream): OK"
out=$(mcp hub tools/call '{"name":"hub_status","arguments":{}}')
grep -q 'upstreams' <<<"$out" || fail "tools/call hub_status: $(printf '%s' "$out" | tail -n 1 | head -c 300)"
echo "tools/call /hub (native Status): OK"
out=$(http GET /no/such/route) || true
grep -q 'Page Not Found' <<<"$out" || fail "the 404 page (Mojolicious resources) did not render"
echo "404 page (packed Mojolicious templates): OK"
"$BIN" --config "$work/hub.json" status >"$work/status" 2>"$work/err" || fail "status: $(cat "$work/err")"
grep -Eq '^echo +stdio +ready' "$work/status" || fail "status does not show echo ready: $(cat "$work/status")"
echo "status command: OK"
grep -q "\[boxed\] cannot start: .*no-such-docker' not found" "$work/daemon1.log" \
  || fail "the docker upstream did not report its missing CLI"
echo "docker upstream: OK (reports the missing docker CLI, the hub runs on)"
stop_daemon
sleep 0.5
if kill -0 "$echo_pid" 2>/dev/null; then fail "echo (pid $echo_pid) outlived the daemon"; fi
echo "daemon run 2: OK (SIGTERM stopped the hub and its stdio child)"

# --- TLS ---------------------------------------------------------------------------
# The binary is the only TLS client on this host: `mcp-hub get` (Mojolicious' get
# command) and the hub's own `url` upstream. Certificates by relative path: the
# daemons run in the checkout, and a path in a listen URL's query must not need
# escaping.
ca=t/fixtures/binary/tls/ca.crt
tls_url="https://127.0.0.1:$((port + 1))"
front_http=$((port + 2))
front_url="https://127.0.0.1:$((port + 3))"
cat >"$work/tls.json" <<JSON
{"mcpServers": {"history": {"class": "MCP::Hub::Native::ClaudeHistory", "args": {"root": "$root/t/fixtures/claude"}}},
 "hub": {"listen": "$tls_url?cert=t/fixtures/binary/tls/server.crt&key=t/fixtures/binary/tls/server.key",
         "cache_dir": "$work/cache-tls"}}
JSON
cat >"$work/front.json" <<JSON
{"mcpServers": {"secure": {"url": "$tls_url/history"}},
 "hub": {"cache_dir": "$work/cache-front"}}
JSON
# get ARGS...: the binary's own HTTP client; the body on STDOUT, errors on STDERR.
get() { timeout 30 "$BIN" get "$@" </dev/null; }
# wait_tls NAME PID GET-ARGS...: until the daemon answers /_hub/status over https.
wait_tls() {
  local name=$1 pid=$2 i; shift 2
  for i in $(seq 1 60); do
    get "$@" >"$work/out" 2>"$work/err" && grep -q '"upstreams"' "$work/out" && return 0
    kill -0 "$pid" 2>/dev/null || fail "the $name hub exited at start-up"
    sleep 0.2
  done
  fail "the $name hub did not answer over https: $(head -n 3 "$work/err")"
}

"$BIN" --config "$work/tls.json" daemon >"$work/daemon-tls.out" 2>"$work/daemon-tls.log" &
tls_pid=$!
SSL_CERT_FILE=$ca wait_tls tls "$tls_pid" "$tls_url/_hub/status"
echo "https listen (hub.listen with cert= and key=): OK, verified against the test CA via SSL_CERT_FILE"

# The same request, trusting only what the binary finds on this host: refused.
rc=0; get "$tls_url/_hub/status" >"$work/out" 2>"$work/err" || rc=$?
[ "$rc" != 0 ] || fail "a certificate from an unknown CA was accepted: $(head -c 200 "$work/out")"
grep -q 'certificate verify failed' "$work/err" || fail "an unknown CA: no 'certificate verify failed': $(head -n 3 "$work/err")"
echo "unknown CA without SSL_CERT_FILE: refused (certificate verify failed)"

# Where the binary looks for trusted CAs here: the system's store below /etc/ssl,
# else the packed Mozilla::CA bundle. It must exist and hold certificates.
"$BIN" eval 'my %ca = IO::Socket::SSL::default_ca(); print "$_=$ca{$_}\n" for sort keys %ca' \
  >"$work/ca" 2>"$work/err" || fail "default_ca: $(cat "$work/err")"
[ -s "$work/ca" ] || fail "the binary finds no trust store on this host (not even Mozilla::CA)"
store=
while IFS='=' read -r kind loc; do
  case "$kind" in
    SSL_ca_file) n=$(grep -c 'BEGIN CERTIFICATE' "$loc" 2>/dev/null || true) ;;
    SSL_ca_path) n=$(ls "$loc" 2>/dev/null | grep -cE '^[0-9a-f]{8}\.[0-9]+$' || true) ;;
    *) fail "default_ca: unexpected '$kind=$loc'" ;;
  esac
  [ "${n:-0}" -ge 50 ] || fail "trust store $loc holds ${n:-0} certificates"
  case "$loc" in */Mozilla/CA/cacert.pem) loc="the packed Mozilla::CA bundle" ;; esac
  store="${store:+$store, }$loc ($n)"
done <"$work/ca"
echo "trust store on this host: $store"

# That store verifies a real chain, offline: Let's Encrypt's intermediate R11 (a
# fixture) against ISRG Root X1, which every store above holds -- checked at a fixed
# time, so R11's expiry does not matter. On a hashed directory this is also the
# subject-hash lookup of the binary's own OpenSSL.
"$BIN" eval '
  require IO::Socket::SSL;
  my %ca  = IO::Socket::SSL::default_ca();
  my $ctx = Net::SSLeay::CTX_new() or die "CTX_new failed\n";
  Net::SSLeay::CTX_load_verify_locations($ctx, $ca{SSL_ca_file} || "", $ca{SSL_ca_path} || "")
    or die "cannot load the trust store\n";
  my $store = Net::SSLeay::CTX_get_cert_store($ctx);
  my $param = Net::SSLeay::X509_VERIFY_PARAM_new();
  Net::SSLeay::X509_VERIFY_PARAM_set_time($param, 1735689600);    # 2025-01-01
  Net::SSLeay::X509_STORE_set1_param($store, $param);
  my $bio  = Net::SSLeay::BIO_new_file("t/fixtures/binary/tls/le-r11.crt", "r") or die "cannot read le-r11.crt\n";
  my $cert = Net::SSLeay::PEM_read_bio_X509($bio) or die "le-r11.crt holds no certificate\n";
  my $vctx = Net::SSLeay::X509_STORE_CTX_new();
  Net::SSLeay::X509_STORE_CTX_init($vctx, $store, $cert);
  print Net::SSLeay::X509_verify_cert($vctx) == 1 ? "verified\n"
    : Net::SSLeay::X509_verify_cert_error_string(Net::SSLeay::X509_STORE_CTX_get_error($vctx)) . "\n";
' >"$work/out" 2>"$work/err" || fail "chain check: $(cat "$work/err")"
[ "$(cat "$work/out")" = verified ] || fail "the trust store does not verify Let's Encrypt R11: $(cat "$work/out")"
echo "trust store verifies a real chain: OK (Let's Encrypt R11 to ISRG Root X1, offline)"

# A second hub whose `url` upstream is the first one, verified against the test CA.
# It listens on https with Mojolicious' built-in certificate (no cert= in the listen
# URL; the client turns verification off with -k) and on http, where the helpers
# above send the tools/call -- its answer is an event stream, which `get` does not
# print.
SSL_CERT_FILE=$ca "$BIN" --config "$work/front.json" daemon -l "http://127.0.0.1:$front_http" -l "$front_url" \
  >"$work/daemon-front.out" 2>"$work/daemon-front.log" &
front_pid=$!
wait_tls front "$front_pid" -k "$front_url/_hub/status"
echo "https listen with the built-in certificate: OK (get -k)"
port=$front_http    # http and mcp talk to $port
out=$(mcp secure tools/list)
grep -q '"name":"list_projects"' <<<"$out" || fail "tools/list on /secure (https url upstream): $(printf '%s' "$out" | tail -n 1 | head -c 300)"
out=$(mcp secure tools/call '{"name":"list_projects","arguments":{}}')
grep -q 'proj-a' <<<"$out" || fail "tools/call on /secure (https url upstream): $(printf '%s' "$out" | tail -n 3 | head -c 300)"
echo "https url upstream: OK (manifest and tools/call through the second hub, verified against the test CA)"
stop_tls() {
  local rc=0
  kill -TERM "$2"; wait "$2" || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 143 ] || fail "the $1 hub exited $rc on SIGTERM"
}
stop_tls front "$front_pid"; front_pid=
stop_tls tls "$tls_pid"; tls_pid=
echo "TLS: OK"

echo "smoke: OK"
