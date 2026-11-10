#!/usr/bin/env bash
# Smoke-test a packed mcp-hub where no Perl is needed: bash, sh, coreutils, grep, sed
# and awk are all it uses (HTTP goes through bash's /dev/tcp, every Perl check runs
# inside the binary), so it runs as-is in a bare distribution container.
#   scripts/binary-smoke.sh <binary>
# binary_smoke of the [@Author::GETTY] bundle (dist.ini): its dzil-binary workflow runs
# it from the unpacked dist on clean machines without perl (AlmaLinux 8 and 9, Debian
# bookworm slim, the macOS runner as it is), dzil build's local check right after
# packing. Prints "smoke: OK" and exits 0, or "FAIL: <reason>" on STDERR and exits 1.
# SMOKE_NO_PERL=1 additionally fails when a perl is on PATH, to prove the point.
#
# Covered: a cold and a warm start, token, JSON decoded in C (Cpanel::JSON::XS under
# Mojo::JSON and JSON::MaybeXS, from the archive), config (JSON and YAML, every kind
# of entry), an error path, and two daemon runs -- the first fetches the stdio
# upstream's manifest once, the second serves tools/list from that cache without
# starting it, starts it on tools/call (t/upstream/echo.sh, a stdio MCP server in
# POSIX sh; on Linux it must hold neither an fd on the binary nor the listening
# socket), answers a native and a remote HTTP upstream and Mojolicious' 404 page,
# runs a native in a forked worker (hub.fork; on Linux, elsewhere it checks the
# refusal) and leaves no child behind on SIGTERM. On Linux a probe class then checks
# a forked worker's lazy require and that its archive fds are its own: a read on
# them leaves the hub's offsets where they were. Then TLS, with no curl or openssl
# on the host -- the binary is every client: a hub listening on https with the test
# certificate (t/fixtures/binary/tls), verified through SSL_CERT_FILE and refused
# without it, which trust store the binary finds on this host and that it verifies
# a real chain there (Let's Encrypt's R11, a fixture, at a fixed time, offline), and
# a second https hub whose `url` upstream is the first. scripts/binary-verify.sh is
# the other half: the same CLI against `perl -Ilib`, and the packed module set.
set -euo pipefail

[ -n "${1:-}" ] || { echo "usage: binary-smoke.sh <binary>" >&2; exit 1; }
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
      MOJO_MODE MOJO_REACTOR MOJO_NO_JSON_XS MOJO_HOME MOJO_LOG_LEVEL MOJO_CA_FILE MOJO_INSECURE \
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

# tmo SECS CMD...: CMD, ended with TERM after SECS seconds -- timeout(1) where it
# exists, else (macOS ships none) a watchdog in the background that looks once a second.
# CMD keeps the caller's stdin (<&0): an asynchronous command would get /dev/null.
if command -v timeout >/dev/null 2>&1; then
  tmo() { timeout "$@"; }
else
  tmo() {
    local secs=$1 pid dog rc=0
    shift
    "$@" <&0 &
    pid=$!
    ( i=0
      while [ "$i" -lt "$secs" ] && kill -0 "$pid" 2>/dev/null; do sleep 1; i=$((i + 1)); done
      kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    dog=$!
    wait "$pid" || rc=$?
    kill "$dog" 2>/dev/null || true
    wait "$dog" 2>/dev/null || true
    return "$rc"
  }
fi

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

# --- JSON in C: Cpanel::JSON::XS is packed, its shared object with it --------------
# Mojo::JSON (the wire) and JSON::MaybeXS (the natives' decoder) each load it by name
# and fall back to pure Perl without it: every other check here would still pass, and
# the natives would read a large Claude Code history dozens of times slower. It must
# come from the archive -- PAR's cache -- not from a perl of this host's.
"$BIN" eval '
  require JSON::MaybeXS;
  my $par  = $ENV{PAR_TEMP} // "";
  my $from = sub { my $f = shift // "nowhere"; length($par) && index($f, "$par/") == 0 ? "the archive" : $f };
  my %so;
  @so{@DynaLoader::dl_modules} = @DynaLoader::dl_shared_objects;
  print "Mojo::JSON::JSON_XS: ", (Mojo::JSON::JSON_XS() ? "true" : "false"), "\n",
    "JSON::MaybeXS::JSON(): ", JSON::MaybeXS::JSON(), "\n",
    "Cpanel::JSON::XS from: ", $from->($INC{"Cpanel/JSON/XS.pm"}), "\n",
    "its shared object from: ", $from->($so{"Cpanel::JSON::XS"}), "\n",
    "info: Cpanel::JSON::XS ", Cpanel::JSON::XS->VERSION // "none", ", JSON::MaybeXS $JSON::MaybeXS::VERSION\n";
' >"$work/out" 2>"$work/err" || fail "JSON backend: $(cat "$work/err")"
want="Mojo::JSON::JSON_XS: true
JSON::MaybeXS::JSON(): Cpanel::JSON::XS
Cpanel::JSON::XS from: the archive
its shared object from: the archive"
[ "$(grep -v '^info: ' "$work/out")" = "$want" ] || fail "JSON does not decode in C: $(cat "$work/out")"
echo "JSON in C: OK (Mojo::JSON::JSON_XS true, JSON::MaybeXS::JSON() is Cpanel::JSON::XS, it and its" \
  "shared object from the archive; $(sed -n 's/^info: //p' "$work/out"))"

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
   "forked":  {"class": "MCP::Hub::Native::ClaudeHistory", "args": {"root": "$root/t/fixtures/claude"},
               "hub": {"fork": true}},
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
  tmo 30 cat <&3
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
# On Linux: the exec'd child keeps nothing of the hub's above stderr -- no fd on the
# binary (PAR's archive handles) and not the listening socket, which a child that
# outlives a crashed hub would keep bound. Before k52 echo.sh held both.
if [ -d /proc/self/fd ]; then
  self=$(readlink -f "$BIN")
  # archive_fds PID: "fd:offset ..." for each fd PID holds open on the binary -- the
  # handles PAR keeps on its archive.
  archive_fds() {
    local fd out=
    for fd in /proc/"$1"/fd/*; do
      [ "$(readlink "$fd" 2>/dev/null)" = "$self" ] || continue
      out="$out ${fd##*/}:$(sed -n 's/^pos:[[:space:]]*//p' "/proc/$1/fdinfo/${fd##*/}")"
    done
    printf '%s\n' "${out# }"
  }
  # fds_above_stderr PID: "fd->target ..." for each fd above 2 that PID holds.
  fds_above_stderr() {
    local fd out=
    for fd in /proc/"$1"/fd/*; do
      [ "${fd##*/}" -gt 2 ] 2>/dev/null || continue
      out="$out ${fd##*/}->$(readlink "$fd" 2>/dev/null)"
    done
    printf '%s\n' "${out# }"
  }
  # The listening socket as /proc/PID/fd names it, socket:[INODE]: the inode of the
  # LISTEN (0A) row for 127.0.0.1:$port in /proc/net/tcp (addresses in hex).
  listen_sock=$(awk -v p=":$(printf '%04X' "$port")" \
    '($2 == "0100007F" p || $2 == "7F000001" p) && $4 == "0A" { print "socket:[" $10 "]"; exit }' /proc/net/tcp)
  [ -n "$listen_sock" ] || fail "no LISTEN row for 127.0.0.1:$port in /proc/net/tcp"
  case " $(fds_above_stderr "$daemon_pid") " in
    *"->$listen_sock "*) ;;
    *) fail "the hub holds no fd on its listening socket $listen_sock: the check proves nothing" ;;
  esac
  [ -n "$(archive_fds "$daemon_pid")" ] || fail "the hub holds no fd on its own binary ($self): the check proves nothing"
  kill -0 "$echo_pid" 2>/dev/null || fail "echo (pid $echo_pid) is gone after its tools/call"
  child_fds=$(fds_above_stderr "$echo_pid")
  case " $child_fds " in *"->$self "*) fail "echo (pid $echo_pid) holds an fd on the binary: $child_fds" ;; esac
  case " $child_fds " in *"->$listen_sock "*) fail "echo (pid $echo_pid) holds the hub's listening socket $listen_sock: $child_fds" ;; esac
  echo "stdio child fds: OK (echo.sh holds ${child_fds:-nothing} above stderr; the hub's listening socket" \
    "$listen_sock and its archive fds $(archive_fds "$daemon_pid") stayed in the hub)"
fi
out=$(mcp remote tools/call '{"name":"list_projects","arguments":{}}')
grep -q 'proj-a' <<<"$out" || fail "tools/call on /remote (HTTP upstream): $(printf '%s' "$out" | tail -n 1 | head -c 300)"
echo "tools/call /remote (HTTP upstream): OK"
out=$(mcp hub tools/call '{"name":"hub_status","arguments":{}}')
grep -q 'upstreams' <<<"$out" || fail "tools/call hub_status: $(printf '%s' "$out" | tail -n 1 | head -c 300)"
echo "tools/call /hub (native Status): OK"

# A native in a forked worker (hub.fork): the packed hub forks itself, with no exec,
# so the worker is the binary's own perl. Linux only -- the worker's fd isolation
# reads /proc/self/fd; elsewhere the entry is a failed one and the hub runs on.
fork_pid=
# The forked entry's row of /_hub/status, on one line.
forked_row() { http GET /_hub/status | grep -o '{[^{}]*"name":"forked"[^{}]*}' || true; }
if [ -d /proc/self/fd ]; then
  # (self and archive_fds: from the stdio child's fd check above)
  worker_pid() { forked_row | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p'; }
  out=$(mcp forked tools/list)
  grep -q '"name":"list_projects"' <<<"$out" || fail "tools/list on /forked: $(printf '%s' "$out" | tail -n 1 | head -c 300)"
  [ -z "$(worker_pid)" ] || fail "tools/list on /forked forked a worker (lazy start broken)"
  echo "tools/list /forked (hub.fork, native ClaudeHistory): OK, listed by the class in the hub, no worker"
  out=$(mcp forked tools/call '{"name":"list_projects","arguments":{}}')
  grep -q 'proj-a' <<<"$out" || fail "tools/call on /forked: $(printf '%s' "$out" | tail -n 3 | head -c 300)"
  fork_pid=$(worker_pid)
  [ -n "$fork_pid" ] || fail "tools/call on /forked answered, but the status shows no worker"
  case "$(tr '\0' ' ' <"/proc/$fork_pid/cmdline")" in
    "mcp-hub-worker forked"*) ;;
    *) fail "the worker (pid $fork_pid) runs as '$(tr '\0' ' ' <"/proc/$fork_pid/cmdline" | head -c 100)'" ;;
  esac
  [ "$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$fork_pid/status")" = "$daemon_pid" ] \
    || fail "the worker (pid $fork_pid) is no child of the hub (pid $daemon_pid)"
  echo "tools/call /forked: OK, answered by mcp-hub-worker forked (pid $fork_pid), forked from the hub"
  # The worker inherited the hub's archive fds and reopened each one: the same fd
  # numbers, still on the binary (not /dev/null), at the hub's offsets. A second call
  # goes to the same worker and moves none of them.
  hub_fds=$(archive_fds "$daemon_pid")
  [ -n "$hub_fds" ] || fail "the hub holds no fd on its own binary ($self): the archive checks prove nothing"
  [ "$(archive_fds "$fork_pid")" = "$hub_fds" ] \
    || fail "the worker's archive fds ($(archive_fds "$fork_pid")) are not the hub's ($hub_fds)"
  out=$(mcp forked tools/call '{"name":"list_sessions","arguments":{"project":"/home/tester/proj-a"}}')
  grep -q 'Debug the widget renderer' <<<"$out" || fail "a second tools/call on /forked: $(printf '%s' "$out" | tail -n 3 | head -c 300)"
  [ "$(worker_pid)" = "$fork_pid" ] || fail "the second call did not go to worker $fork_pid (now: '$(worker_pid)')"
  [ "$(archive_fds "$daemon_pid")" = "$hub_fds" ] || fail "the hub's archive offsets moved: $hub_fds -> $(archive_fds "$daemon_pid")"
  echo "archive fds: OK (the worker holds the hub's fds on the binary, $hub_fds, none on /dev/null; a second call moved none)"
else
  grep -q 'hub.fork needs Linux' <<<"$(forked_row)" \
    || fail "hub.fork on $(uname -s): /forked is not failed with 'hub.fork needs Linux': $(forked_row)"
  echo "hub.fork on $(uname -s): refused as documented (Linux only), the hub runs on"
fi
out=$(http GET /no/such/route) || true
grep -q 'Page Not Found' <<<"$out" || fail "the 404 page (Mojolicious resources) did not render"
echo "404 page (packed Mojolicious templates): OK"
"$BIN" --config "$work/hub.json" status >"$work/status" 2>"$work/err" || fail "status: $(cat "$work/err")"
grep -Eq '^echo +stdio +ready' "$work/status" || fail "status does not show echo ready: $(cat "$work/status")"
if [ -n "$fork_pid" ]; then
  grep -Eq "^forked +fork +ready +$fork_pid +[0-9]+ +[0-9]+ " "$work/status" \
    || fail "status does not show the forked worker with its PSS_KB: $(grep '^forked' "$work/status")"
fi
echo "status command: OK"
grep -q "\[boxed\] cannot start: .*no-such-docker' not found" "$work/daemon1.log" \
  || fail "the docker upstream did not report its missing CLI"
echo "docker upstream: OK (reports the missing docker CLI, the hub runs on)"
stop_daemon
sleep 0.5
if kill -0 "$echo_pid" 2>/dev/null; then fail "echo (pid $echo_pid) outlived the daemon"; fi
if [ -n "$fork_pid" ] && kill -0 "$fork_pid" 2>/dev/null; then fail "the forked worker (pid $fork_pid) outlived the daemon"; fi
echo "daemon run 2: OK (SIGTERM stopped the hub, its stdio child${fork_pid:+ and its forked worker})"

# --- a forked worker's lazy require and archive fds (Linux) ------------------------
# What the daemon cannot show: a worker loading a module the hub never loaded, and a
# worker reading through its archive fds. The packed perl keeps two fds open on the
# binary -- the loader's and PAR's bootstrap handle -- and a worker inherits both; the
# reopen rule gives it an open file description of its own for each, so a read in
# the worker never moves the hub's offset. The probe class lives only in this eval
# and is mounted the way hub.fork mounts one: listed in the hub, called in a worker.
#
# With PAR 1.021 a require reads the copy of the archive PAR unpacked into
# PAR_TEMP/inc at the first start, not these fds -- the info line says which. So the
# worker also seeks and reads on each archive fd, as Archive::Zip does on a member,
# and the hub's offsets must not follow. They are compared with the offsets at the
# fork: perl flushes every handle before a fork, PAR's bootstrap handle still holds
# read-ahead, so the hub's own first fork (any fork) moves that offset once.
if [ -d /proc/self/fd ]; then
  tmo 60 "$BIN" eval '
    use Mojo::Base -strict, -signatures;
    use Mojo::File qw(path);
    use Mojo::JSON qw(decode_json encode_json);
    use MCP::Hub::Upstream::Fork;
    use POSIX ();

    my $SELF = path($ENV{PAR_PROGNAME})->realpath->to_string;

    # "fd:offset ..." for each fd PID holds open on the binary.
    sub archive_fds ($pid) {
      opendir my $dh, "/proc/$pid/fd" or die "/proc/$pid/fd: $!\n";
      my @fds;
      for my $fd (sort { $a <=> $b } grep {/^\d+$/} readdir $dh) {
        next unless (readlink("/proc/$pid/fd/$fd") // "") eq $SELF;
        open my $info, "<", "/proc/$pid/fdinfo/$fd" or next;
        my ($pos) = map { /^pos:\s+(\d+)/ ? $1 : () } <$info>;
        push @fds, "$fd:$pos";
      }
      return join " ", @fds;
    }

    package Probe {
      use Mojo::Base "MCP::Server", -signatures;
      sub new ($class, @args) {
        my $self = $class->SUPER::new(@args);
        $self->tool(name => "probe", description => "a lazy require, then a read on each archive fd",
          code => sub ($tool, $args) {
            my $hub = getppid;
            my %r = (hub => main::archive_fds($hub), mine => main::archive_fds($$),
                     preloaded => $INC{"YAML/PP.pm"} ? 1 : 0);
            require YAML::PP;
            $r{yaml}          = YAML::PP->new->load_string("k: v\n")->{k};
            $r{from}          = $INC{"YAML/PP.pm"};
            $r{after_require} = main::archive_fds($$);
            for my $fd (map { (split /:/)[0] } split / /, $r{mine}) {
              POSIX::lseek($fd, 0, POSIX::SEEK_SET()) // die "lseek $fd: $!\n";
              POSIX::read($fd, my $buf, 4)            // die "read $fd: $!\n";
            }
            $r{after_read}     = main::archive_fds($$);
            $r{hub_after_read} = main::archive_fds($hub);
            return Mojo::JSON::encode_json(\%r);
          });
        return $self;
      }
    }

    package main;
    die "YAML::PP is loaded in the hub already: the require in the worker would not be lazy\n"
      if $INC{"YAML/PP.pm"};
    my $up = MCP::Hub::Upstream::Fork->new(name => "probe", config => {type => "fork", class => "Probe"});
    $up->server;
    my $res;
    $up->call_tool("probe", {})->then(sub ($r) { $res = $r })->catch(sub ($e) { $res = {error => "$e"} })->wait;
    my $hub_after = archive_fds($$);
    $up->stop;
    die "tools/call probe: $res->{error}\n" if $res->{error};
    my $r = decode_json($res->{content}[0]{text});
    (my $moved = $r->{mine}) =~ s/:\d+/:4/g;
    # An unset or empty PAR_TEMP would make the prefix "/", which any absolute path passes.
    my $par = $ENV{PAR_TEMP} // "";
    say !$r->{preloaded} && ($r->{yaml} // "") eq "v" && length($par) && index($r->{from} // "", "$par/") == 0
      ? "lazy require in the worker: YAML::PP, not loaded in the hub, read from the unpacked archive"
      : "FAIL lazy require: preloaded=$r->{preloaded} yaml=" . ($r->{yaml} // "undef") . " from=" . ($r->{from} // "undef")
        . " PAR_TEMP=" . (length($par) ? $par : "unset");
    say length $r->{mine} && $r->{mine} eq $r->{hub}
      ? "archive fds in the worker: the hub fd numbers, at the hub offsets"
      : "FAIL archive fds: worker [$r->{mine}], hub [$r->{hub}]";
    say $r->{after_read} eq $moved && $r->{hub_after_read} eq $r->{hub}
      ? "a read on each moved the worker offsets only: descriptions of its own"
      : "FAIL own descriptions: worker after its reads [$r->{after_read}], want [$moved]; hub [$r->{hub}] then [$r->{hub_after_read}]";
    say $hub_after eq $r->{hub}
      ? "the hub offsets after the call: as at the fork"
      : "FAIL hub after the call: [$r->{hub}] then [$hub_after]";
    say "info: archive fds $r->{hub}; the require read ",
      $r->{after_require} eq $r->{mine} ? "nothing through them" : "through them ([$r->{mine}] to [$r->{after_require}])";
  ' >"$work/out" 2>"$work/err" || fail "fork probe: $(cat "$work/out") $(grep -v 'forked a worker' "$work/err" | tail -n 3)"
  want="lazy require in the worker: YAML::PP, not loaded in the hub, read from the unpacked archive
archive fds in the worker: the hub fd numbers, at the hub offsets
a read on each moved the worker offsets only: descriptions of its own
the hub offsets after the call: as at the fork"
  [ "$(grep -v '^info: ' "$work/out")" = "$want" ] || fail "fork probe: $(cat "$work/out")"
  sed 's/^/fork probe: /' "$work/out"
  echo "fork probe: OK"
fi

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
get() { tmo 30 "$BIN" get "$@" </dev/null; }
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
