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
# and leaves no child behind on SIGTERM. scripts/verify-binary.sh is the other half:
# the same CLI against `perl -Ilib`, and the packed module set.
set -euo pipefail

[ -n "${1:-}" ] || { echo "usage: smoke-binary.sh <binary>" >&2; exit 1; }
BIN=$1; case "$BIN" in /*) ;; *) BIN="$PWD/$BIN" ;; esac
[ -x "$BIN" ] || { echo "FAIL: not an executable: $BIN" >&2; exit 1; }
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
daemon_pid=
cleanup() {
  [ -n "$daemon_pid" ] && kill -TERM "$daemon_pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT
fail() {
  echo "FAIL: $*" >&2
  for f in "$work"/daemon*.log; do [ -s "$f" ] && { echo "--- $f (tail)" >&2; tail -n 20 "$f" >&2; }; done
  exit 1
}

# Nothing of this host's Perl or of anybody's configuration.
unset PERL5LIB PERL5OPT MCP_HUB_CONFIG XDG_CONFIG_HOME XDG_CACHE_HOME CLAUDE_CONFIG_DIR \
      MOJO_MODE MOJO_REACTOR MOJO_HOME MOJO_LOG_LEVEL
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

echo "smoke: OK"
