<p align="center">
  <img src="assets/github.png" alt="MCP-Hub — A lot of MCP for very little RAM." width="100%">
</p>

# MCP-Hub

**A lot of MCP for very little RAM.**

`mcp-hub` is a single HTTP MCP server that embeds any number of stdio MCP
servers (context7, playwright, serper, …), MCP servers that ship as Docker
images or compose services, in-process Perl MCP servers, and remote HTTP MCP
servers (Streamable HTTP or HTTP+SSE), and hands each of them to every agent on
the machine as its own endpoint. It runs each server **once per
machine**, not once per agent session, starts them **lazily** on the first tool
call, and stops them again when idle.

Today every Claude Code session spawns its own copy of every stdio server. On a
busy machine that is easily ~2.2 GB of node processes (context7, playwright,
serper, claude-code-history — plus an idle `npm exec` wrapper of ~85 MB each)
for three sessions. `mcp-hub` collapses that to one shared set of processes that
only exist while someone is using them.

The agent's view is unchanged: each embedded server keeps its own tool names, so
`mcp__context7__resolve-library-id` stays `mcp__context7__resolve-library-id`,
your existing permission rules keep working, and the `/mcp` menu still lists
servers separately.

## Quick start

The fastest way to run the hub is the Docker image. It is
**batteries-included**: the stdio servers you embed run *inside* the container,
so it already ships the runtimes they need — Node (with `npx`), Python
(`uv`/`uvx`), Deno and Bun — and there is nothing to install on the host.

**1. Write a `.mcp.json`.** It is a **superset of the `.mcp.json` you already
use** — an existing `mcpServers` block is already a valid hub config:

```json
{
  "mcpServers": {
    "context7":       { "command": "npx", "args": ["-y", "@upstash/context7-mcp@latest"] },
    "playwright":     { "command": "npx", "args": ["@playwright/mcp@latest", "--headless"],
                        "hub": { "idle_timeout": 120 } },
    "serper":         { "command": "npx", "args": ["-y", "serper-search-scrape-mcp-server@latest"],
                        "env": { "SERPER_API_KEY": "${SERPER_API_KEY}" } },
    "claude-history": { "class": "MCP::Hub::Native::ClaudeHistory" },
    "hub":            { "class": "MCP::Hub::Native::Status" }
  }
}
```

**2. Run the container.** Mount that config, expose the port, and give it a
volume for its cache:

```bash
docker run -d --name mcp-hub \
  -p 127.0.0.1:3080:3080 \
  -v "$PWD/.mcp.json:/config/mcp.json:ro" \
  -v mcp-hub-cache:/cache \
  --env-file .env \
  raudssus/mcp-hub
```

Secrets stay out of the config: reference them as `${SERPER_API_KEY}` and put
the values in `.env` (or pass single ones with `-e SERPER_API_KEY=…`).

Publishing on `127.0.0.1` keeps the hub reachable from this machine only. A
bare `-p 3080:3080` publishes it on **every** interface — in [open
mode](#two-modes) that hands every tool and the admin API to the whole network.
Only do that with a `clients` block in place.

or, with the bundled `docker-compose.yml`:

```bash
docker compose up -d
```

**3. Point your agent at it.** Open **<http://127.0.0.1:3080/>** in a browser —
the hub serves a [setup page](#web-setup-page) with the ready-to-paste client
configuration and a one-click **Copy** button.

That's it. Nothing is spawned until an agent actually calls a tool; `tools/list`
is answered from a cached manifest. See [Docker image](#docker-image) for
volumes, secrets, per-upstream runtimes and rootless Podman.

## Install with Perl (CPAN)

Prefer to run it directly, without a container? Install it from CPAN — the
natural route for Perl people, and for mounting your own in-process servers:

```bash
cpanm MCP::Hub
```

This gives you the `mcp-hub` command. Write the same config as above at
`~/.config/mcp-hub/config.json` (or, [as YAML](#json-or-yaml), `config.yml`) and
start it in the foreground:

```bash
mcp-hub daemon
# Listening on http://127.0.0.1:3080
```

Print the client configuration to paste into Claude Code (`.mcp.json`):

```bash
mcp-hub config
```

```json
{
   "mcpServers" : {
      "context7"       : { "type" : "http", "url" : "http://127.0.0.1:3080/context7" },
      "playwright"     : { "type" : "http", "url" : "http://127.0.0.1:3080/playwright" },
      "serper"         : { "type" : "http", "url" : "http://127.0.0.1:3080/serper" },
      "claude-history" : { "type" : "http", "url" : "http://127.0.0.1:3080/claude-history" },
      "hub"            : { "type" : "http", "url" : "http://127.0.0.1:3080/hub" }
   }
}
```

Or just open **<http://127.0.0.1:3080/>** — the same setup page as above.

### Running as a service

A systemd **user** unit at `~/.config/systemd/user/mcp-hub.service`:

```ini
[Unit]
Description=MCP Hub
After=network.target

[Service]
ExecStart=%h/perl5/bin/mcp-hub daemon
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
Environment=MCP_HUB_CONFIG=%h/.config/mcp-hub/config.json
# A local::lib install in ~/perl5: the user manager sets neither PERL5LIB nor a
# PATH with ~/perl5/bin, which stdio upstreams installed there need.
Environment=PERL5LIB=%h/perl5/lib/perl5
Environment=PATH=%h/perl5/bin:/usr/local/bin:/usr/bin:/bin
# Secrets the config references as ${VAR} (API keys, client tokens); optional.
EnvironmentFile=-%h/.config/mcp-hub/env

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now mcp-hub
```

## Standalone binary

No Perl and no container on the machine? Each GitHub release also carries
`mcp-hub` as one executable per platform — `linux-x86_64`, `linux-arm64` and
`macos-arm64` — with Perl, OpenSSL and every module packed inside:

```bash
curl -fsSL https://github.com/Getty/mcp-hub/releases/latest/download/install.sh | sh
```

The install script picks the binary for your OS and architecture, checks it
against the release's `SHA256SUMS` and installs it as `mcp-hub`. Or download
`mcp-hub-<version>-<os>-<arch>` from the release page yourself, `chmod +x` it and
put it on your `PATH` (on macOS, after a browser download:
`xattr -d com.apple.quarantine mcp-hub`). The Linux binaries need glibc 2.28 or
newer; on Alpine (musl) use the [Docker image](#docker-image).

It is the same `mcp-hub` as the CPAN install — every command, JSON and YAML
configs, stdio, `url`, `docker` and `compose` entries, both modes, the setup
page — with these differences:

- **No Perl modules from outside.** The binary loads only what is packed into
  it; `PERL5LIB`, `PERL5OPT` and an installed `local::lib` are ignored. A `class`
  entry can name the bundled natives — `MCP::Hub::Native::ClaudeHistory`,
  `MCP::Hub::Native::ClaudeSessions`, `MCP::Hub::Native::Status` — and nothing
  else: `MCP::Run`, `MCP::K8s` or [your own server](#writing-your-own-native-server)
  shows up as `failed` with `cannot load class …`. Use the CPAN install for those,
  or, with a Perl on the machine, mount them as a stdio upstream instead:
  `{"command": "perl", "args": ["-MMy::Weather", "-e", "My::Weather->new->to_stdio"]}`.
- **It replaces Perl, nothing else.** A stdio entry still runs its `command` —
  `npx`, `uvx`, `docker`, … — from the host's `PATH`, and `docker`/`compose`
  entries still need the Docker CLI, exactly as with the CPAN install.
- **Its own OpenSSL.** TLS works as in the CPAN install — `https://` `url`
  upstreams, and an `https://` `hub.listen` such as
  `https://127.0.0.1:3443?cert=/path/server.crt&key=/path/server.key` (without
  `cert` and `key`, Mojolicious' built-in self-signed test certificate) — but
  with OpenSSL 3.5 linked into the binary: the system's OpenSSL and its
  `openssl.cnf` are not used.
- **The system's CA certificates where it finds them.** To verify a server's
  certificate, the binary reads the hashed certificate directory `/etc/ssl/certs`
  and the bundle `/etc/ssl/cert.pem` — whichever exist, both if both do — and
  only when it finds neither, the Mozilla CA bundle packed into it.
  `SSL_CERT_DIR` and `SSL_CERT_FILE` name another directory or bundle.
  - Debian, Ubuntu: `/etc/ssl/certs` from `ca-certificates` — the system store,
    with CAs added by `update-ca-certificates`.
  - RHEL, Rocky, Alma 9 and later, Fedora: `/etc/ssl/cert.pem` — the system
    store, with CAs added by `update-ca-trust`.
  - RHEL, Rocky, Alma 8 have neither, so the packed bundle answers, which knows
    no local CAs; `export SSL_CERT_FILE=/etc/pki/tls/certs/ca-bundle.crt` uses
    the system store instead.
  - macOS: `/etc/ssl/cert.pem`, the system's root certificates. CAs added to the
    Keychain are not in it: export them, together with the roots you still need,
    into one PEM file and point `SSL_CERT_FILE` at it.
  - A minimal container image without `ca-certificates`: the packed bundle.
- It runs on Mojolicious' own event loop, never on `EV`, like the Docker image.

The first start after installing or upgrading unpacks about 35 MB into
`$TMPDIR/par-<user>/cache-<hash>` (set `PAR_GLOBAL_TMPDIR` to move it) and takes
a few seconds; later starts reuse it. Let that first start finish before starting
several `mcp-hub` at once, and remove the cache of an old version after an
upgrade — nothing cleans it up. For the systemd unit above, point `ExecStart` at
the binary, e.g. `%h/.local/bin/mcp-hub daemon`.

## Web setup page

Because everything is served over HTTP, the hub also serves a **setup page** at
`GET /` that tells a user exactly what to do — no need to run a command:

- the ready-to-paste `.mcp.json`, with a one-click **Copy** button;
- a `claude mcp add --transport http …` line per server;
- for each server, what it does (its own MCP `instructions`) and its tools.

In **clients mode** the page shows only a sign-in field until you paste your
token. Once signed in, it shows exactly the servers *your* profile allows and a
config that already carries your token — so it never reveals which servers exist
to someone without a key.

The token travels in the `Authorization: Bearer …` header and nowhere else: the
sign-in field re-requests the page with that header, so the token never lands in
a URL, an access log or the browser history. A `?token=…` query parameter is
ignored. From a script, `curl -H "Authorization: Bearer …" http://127.0.0.1:3080/`
gives you the same page.

A server the hub could not start is shown as **Unavailable** with the reason,
rather than being hidden.

```
┌───────────────────────────────────────────────┐
│  MCP Hub                                        │
│  A lot of MCP for very little RAM.              │
│  Signed in as worker-1.                         │
│                                                 │
│  Add these to your client            [ Copy ]   │
│  ┌───────────────────────────────────────────┐  │
│  │ { "mcpServers": {                         │  │
│  │     "context7": { "type": "http",         │  │
│  │       "url": "http://…/context7",         │  │
│  │       "headers": { "Authorization": … } } │  │
│  │ } }                                       │  │
│  └───────────────────────────────────────────┘  │
│                                                 │
│  context7  [stdio]                              │
│  Up-to-date library documentation.              │
│  Tools: resolve-library-id, get-library-docs    │
└───────────────────────────────────────────────┘
```

## Two modes

The mode is **derived**, never declared:

- **open** — no `clients` block. No token is checked; every request sees every
  upstream; the admin API is open. This is the simple single-user setup, and a
  plain `.mcp.json` is a valid open-mode config.
- **clients** — a `clients` block is present. Each request must carry a bearer
  token matching a client, whose **profile** decides which servers and tools it
  may use. A request without a valid token gets the `public_profile` if one is
  set, or a `401` otherwise.

```json
{
  "mcpServers": { "…": {} },
  "hub": {
    "profiles": {
      "full":     { "servers": ["*"], "admin": true },
      "research": { "servers": ["context7", "serper", "claude-history"],
                    "tools":   { "serper": { "deny": ["scrape"] } } }
    },
    "clients": {
      "main":     { "token": "${HUB_TOKEN_MAIN}",     "profile": "full" },
      "worker-1": { "token": "${HUB_TOKEN_WORKER_1}", "profile": "research" }
    }
  }
}
```

Generate a token:

```bash
mcp-hub token
```

A token can be written into the config literally, but it is better kept out of
it: reference it as `${VAR}` as above and provide the value through the
environment — an `.env` file passed with `--env-file` / `env_file:` under
Docker, `EnvironmentFile=` in the systemd unit. An unset variable is a config
error at start, so a hub never comes up with an empty token.

Export a specific client's config (adds the `Authorization: Bearer …` header):

```bash
mcp-hub config --client worker-1
```

A profile that does not include a server gets **404** for that server's path, so
a client cannot even tell the server exists. `allow`/`deny` filter individual
tools, applied to both `tools/list` and `tools/call`. Prompts and resources are
not filtered individually — they follow `servers` alone.

## Endpoints

| Route | What it is |
|---|---|
| `GET /` | The web setup page (public; token-gated in clients mode). |
| `POST /<name>` | One endpoint per upstream, tool names unchanged. |
| `POST /all` | Every tool and prompt the client may see, as `<name>__<tool>`. |
| `GET /_hub/status` | Per-upstream state, pid, RSS, call counts, failure reason; known clients and when each was last seen. Needs an `admin` profile. |
| `POST /_hub/refresh` | Re-fetch manifests. Body `{"name": "context7"}` or empty for all. Needs an `admin` profile. |
| `POST /_hub/reload` | [Reload the config](#changing-the-config-while-it-runs). `200` with `{ok, added, removed, changed, unchanged, auth, warnings}`, or `500` with `{"error": …}` when the new file was refused. Needs an `admin` profile. |

The status codes carry meaning, and none of them is ever softened into an empty
tool list:

| Status | Meaning |
|---|---|
| `401` | Clients mode, and the bearer token is missing or wrong (and there is no `public_profile`). |
| `403` | The admin API, called with a profile that is not `admin`. |
| `404` | The server is not in your profile — indistinguishable from a server that does not exist. |
| `503` | The server is yours, but it is still fetching its first manifest, or it has `failed`. The body names the reason. |

## CLI

| Command | Behaviour |
|---|---|
| `mcp-hub daemon` | Run the hub in the foreground (single process). |
| `mcp-hub config [--client NAME] [--all] [--url BASE]` | Print `mcpServers` JSON. |
| `mcp-hub status [--client NAME] [--url BASE] [--token TOKEN]` | Table of the running hub's upstreams and clients. |
| `mcp-hub refresh [NAME] [--client NAME] [--url BASE] [--token TOKEN]` | Re-fetch manifests; also the way to retry a `failed` server. |
| `mcp-hub reload [--client NAME] [--url BASE] [--token TOKEN]` | Re-read the config and apply only what changed. |
| `mcp-hub token` | Print a fresh random bearer token. |

A global `--config PATH` (or `-c PATH`, or `$MCP_HUB_CONFIG`) selects the config
file for every command.

`status`, `refresh` and `reload` talk to the running daemon at the config's `listen`
address (a wildcard such as `0.0.0.0` or `[::]` is reached over loopback, and
listen options such as `?cert=…&key=…` are left out). If the
daemon listens somewhere else — `daemon -l …`, a remapped Docker port, another
machine — point them at it with `--url http://host:port`. In clients mode they
authenticate as the first `admin` client, or the one named with `--client`, or a
token given on the spot with `--token TOKEN` (or `$MCP_HUB_TOKEN`). Given `--url`
together with a token they never read the config file at all, so a broken local
config does not stop you reaching a daemon whose address and token you know.

## Changing the config while it runs

You do not restart the hub to change its config. A **reload** re-reads the file
and changes exactly what the edit asks for — everything else keeps running:

| You edit… | What happens |
|---|---|
| nothing about a server | Nothing. Same process, same stats, same idle timer. |
| a profile, a client, `tools.allow`/`deny`, `public_profile` | Swapped in place; in effect on the next request. A tool you deny disappears from `tools/list` and `tools/call`, and no server is restarted. |
| only timeouts (`idle_timeout`, `request_timeout`, per server or global) | Applied in place, no restart. |
| a server's `command`, `args`, `env`, `url`, `docker`, … | That one server is stopped and rebuilt. |
| `hub.docker_command` or `hub.docker_network` | The `docker` (and, for the command, `compose`) servers are rebuilt. |
| remove a server | It is stopped and its path is `404` again. |
| add a server | It is mounted; with a cached manifest nothing is spawned until its first call. |
| `hub.listen` or `hub.cache_dir` | Cannot be applied live: the rest is applied and you get a warning to restart. |

A config that does not validate is **refused as a whole**: the error (with its
path) is reported, and the hub carries on with the config it had. A reload never
takes the daemon down and never half-applies. A server that could not be built
last time is retried on every reload — install the missing module, reload, done.

Three ways to trigger it:

```bash
mcp-hub reload                 # prints what changed, or the validation error (exit ≠ 0)
kill -HUP <pid>                # same thing, result goes to the log
                               #   docker kill -s HUP mcp-hub  /  systemctl --user reload mcp-hub
```

```
added      serper
removed    playwright
unchanged  3
warning: hub.listen changed from http://127.0.0.1:3080 to http://0.0.0.0:3080, restart the daemon to apply
```

…or let the hub watch the file itself:

```json
{ "hub": { "auto_reload": true } }
```

With `auto_reload` the daemon checks the config file every couple of seconds and
reloads when it changed. A half-saved file simply fails validation and is
ignored until the next write. Under Docker, **mount the config's directory, not
the single file** (`-v "$PWD/config:/config:ro"`, with your config at
`config/mcp.json`): a single-file bind mount pins the old inode, so an editor
that saves by rename is never seen.

The config path is fixed at start: a second config file dropped next to the
active one does not take over.

## Troubleshooting

Start with `mcp-hub status` (or the `hub_status` tool): it lists every
configured server with its state, and for a `failed` one a `MESSAGE` column with
the reason.

- **A server answers `503`.** It is either still fetching its first manifest
  (just retry) or it has `failed`. A server fails when its entry cannot be built
  — a `class` that does not load, for instance — or when its process exits three
  times within five seconds. A broken entry never takes the hub down and never
  silently disappears: it stays in `status`, on the setup page and in
  `mcp-hub config`, and says why.
- **Bringing a `failed` server back.** Fix the cause, then `mcp-hub refresh NAME`
  (or the `hub_refresh` tool). An ordinary tool call deliberately does *not*
  restart a crash-looping server; it returns an error that names the refresh
  command.
- **Seeing what a child process prints.** A stdio server's stderr is logged at
  `debug`, prefixed with `[name]`; unexpected exits are logged at `warn` and name
  the command when it died during start-up (the usual "command not found"). The
  log level is Mojolicious': everything by default, `info` and up with
  `mcp-hub daemon -m production`, or pick one with `MOJO_LOG_LEVEL=debug`.
- **`status`/`refresh` say the hub is not running.** They look at the config's
  `listen` address; use `--url` if the daemon listens elsewhere.
- **A command dies on a broken config while the daemon is still up.** `status`,
  `refresh` and `reload` normally read the config for the address and token; pass
  `--url` and `--token` (or `$MCP_HUB_TOKEN`) to skip the file and reach the
  running daemon anyway — `reload` then tells it to re-read the fixed config.

## Native Perl servers

`mcp-hub` ships native Perl replacements for small helpers that today cost a
node process per session:

- **`MCP::Hub::Native::ClaudeHistory`** — browse the local Claude Code history:
  `list_projects`, `list_sessions`, `search_conversations`, `get_conversation`.
- **`MCP::Hub::Native::ClaudeSessions`** — `list_running_sessions`, the live
  `claude` processes on the machine and what each is working on (Linux).
- **`MCP::Hub::Native::Status`** — `hub_status` and `hub_refresh` as tools.

Any `MCP::Server` subclass — or a class with a `server` method that returns
one — can be mounted in-process with a `class` entry: `MCP::Run`, `MCP::K8s`, or
your own, with no subprocess at all. Its tools run inside the hub's event loop,
so a slow one holds up every other server while it runs; for a class like that,
see [forked class workers](#forked-class-workers).

```json
{ "run": { "class": "MCP::Run", "args": { "allowed_commands": ["ls", "cat", "grep"] } } }
```

### Writing your own native server

Any `MCP::Server` subclass works. Register your tools in `new` and it can be
mounted in the hub with a `class` entry — and still works standalone over stdio:

```perl
package My::Weather;
use Mojo::Base 'MCP::Server', -signatures;

sub new ($class, %args) {
  my $self = $class->SUPER::new(name => 'weather', %args);
  $self->tool(
    name         => 'forecast',
    description  => 'Get the forecast for a city',
    input_schema => {type => 'object', properties => {city => {type => 'string'}}, required => ['city']},
    code         => sub ($tool, $args) { $tool->text_result("Sunny in $args->{city}") },
  );
  return $self;
}
1;
```

```json
{ "weather": { "class": "My::Weather" } }
```

If your class has a `hub` attribute, the running `MCP::Hub` instance is injected
into its constructor — that is how `MCP::Hub::Native::Status` reaches the hub.

A `class` entry takes its settings through `args` alone: `env`, `cwd`, `headers`
and `type` are configuration errors on it, and so are the `hub` timeouts and
`always_on` — an in-process class has no process to time out or keep running.

### Forked class workers

A tool that takes seconds — a git history walk, say — stalls the whole hub when
its class runs in-process. `"hub": {"fork": true}` keeps the memory cost close to
in-process without the stall:

```json
{
  "wiki": {
    "class": "MCP::Wiki::Server",
    "args":  { "wiki_root": "/home/me/wiki", "use_git": true },
    "hub":   { "fork": true, "idle_timeout": 600 }
  }
}
```

- **Listing needs no process.** The class is loaded in the hub, and its tools,
  prompts and resources are read from it when the entry is built — nothing is
  cached on disk.
- **Calls run in a worker.** The first `tools/call` forks a worker from the hub,
  with no exec: it shares the hub's memory pages and is ready in a few tens of
  milliseconds. It builds its own instance from `args` and serves one call at a
  time, and it is stopped after `idle_timeout` like a stdio child. `always_on`
  and `request_timeout` work as for one too.
- **A worker holds nothing of the hub's.** Before it starts it lets go of the
  listening socket and every other inherited fd, the signal handlers and the
  event loop. It shows up as `mcp-hub-worker NAME` in `ps`. Because its RSS
  counts every page it shares with the hub, `mcp-hub status` also gives it a
  `PSS_KB`.
- **Limits.** Linux only. The class must not need the running hub (a class with
  a `hub` attribute is refused) nor the HTTP request: its tools see no
  request and no profile. `args` is passed as it is — no `${VAR}`, no `~` — so
  write absolute paths, and `env`/`cwd` do not apply. A newer version of the
  class installed on disk takes effect after a daemon restart.

Measured with `MCP::Wiki::Server` (15 tools, git on): `tools/list` answers in
about 10 ms with no worker, the first write forks and commits in about 40 ms,
and a running worker adds about 13 MB to the PSS of hub and worker together.

## MCP servers in Docker containers

An MCP server that ships as a Docker image is mounted by its image name — no
`docker run` line, no separately started container:

```json
{
  "mcpServers": {
    "time":     { "docker": "mcp/time" },
    "github":   { "docker": "ghcr.io/github/github-mcp-server", "args": ["stdio"],
                  "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}" } },
    "crawl4ai": { "docker": "unclecode/crawl4ai", "port": 11235, "path": "/mcp/sse", "type": "sse" },
    "stack":    { "compose": "~/mcp/stack", "service": "mcp" }
  }
}
```

It behaves like a stdio server: `tools/list` is answered from the cached
manifest with no container running; the first `tools/call` pulls the image if it
is missing (with no timeout — a large pull never fails the handshake), starts
the container and talks to it; after `idle_timeout` the container is stopped
again. Crash loops, `refresh`, `always_on` and reload work as for stdio.

**stdio or HTTP — the hub decides at start:**

1. `"port": N` — HTTP on container port N.
2. no `port`, and the image `EXPOSE`s exactly one port — HTTP on that one.
3. no `port` and no `EXPOSE` — stdio (`docker run -i --rm …`).
4. `"stdio": true` — stdio, whatever the image declares (for images that
   `EXPOSE` a port but speak stdio by default).

An image that `EXPOSE`s several ports needs `port`. An HTTP container's port is
published on `127.0.0.1` only, on a port Docker picks; the hub waits until the
server answers, so a slow start is no error. `path` (default `/mcp`), `type`
(`http` or `sse`) and `headers` work as for a `url` server.

**Compose.** `compose` names the directory of a compose project and `service`
(required) the one service that is the MCP server. The hub reads the project
with `docker compose config` and talks to the service this way: `url` — HTTP to
exactly that address; `port` — HTTP on that published port; exactly one
published port — HTTP on it; none — stdio, via `docker compose run --rm -T
--no-deps`. `"stdio": true` forces stdio. The hub starts the service, plus any
dependencies that are not running yet; it stops only that service; it never
stops, recreates or restarts anything that already exists.

For HTTP the hub first asks `docker compose ps` whether the service already
runs. If it does, the hub uses it as it is — no `up` — and never stops it; if
that check fails, so does the start, and nothing is started or stopped.
Otherwise it runs `docker compose up -d --no-recreate <service>`: compose starts
the service and what it `depends_on` that does not run, waits for each as
`depends_on` says, and recreates nothing. (Compose's default would recreate a
running dependency whose configuration has changed — the user's database, say,
started from a shell with a variable the hub's environment lacks.) `docker
compose stop <service>` stops it again. For stdio, the hub does first what
`compose run` would otherwise do inside the handshake: it pulls or builds a
missing image, runs `docker compose up -d --no-recreate` for the dependencies,
and waits until each `service_healthy` one is healthy and each
`service_completed_successfully` one has exited 0 — all without a timeout, so
none of it counts against `request_timeout`. The dependencies are left running,
as `compose run` leaves them; a one-shot dependency runs again on every start,
as compose runs it. As nothing is recreated, a change in the compose file
reaches a container that already exists — a dependency's, or an HTTP service's —
only once you recreate it yourself (`docker compose up -d --force-recreate
<service>`); the stdio server's `run` container is new on every start. A
compose entry's `env` is
the environment of the compose command, so `${VAR}` in the compose file sees it;
it reaches the container only where the compose file passes it on. Compose
entries need Docker Compose 2 or later (`docker compose version`);
podman-compose is not supported.

**Secrets stay off command lines.** For a `docker` entry each `env` key becomes a
bare `-e KEY`; the value travels in the environment of the `docker` CLI, never in
an argv. Error messages carry what a command wrote to stderr, never its stdout —
which for `docker compose config` is the whole project.

**What the hub stops and removes.** Every container it starts —
from a `docker` entry, or by `docker compose run` — is named `mcp-hub-<name>` and
labelled `mcp-hub.server=<name>`, `mcp-hub.owner=<id>` and `mcp-hub.run=<start>`.
The owner id is kept in the cache directory; a hub that cannot keep it there
starts no container at all. Leftovers of a crashed hub are removed by those
labels only, and every match is checked again before it goes; a container of
that name that is not the hub's makes the start fail with Docker's "already in
use", and the hub leaves it alone. A compose service is stopped only when it was
not running when the hub looked, just before its `up -d` (one that someone else
starts in the moment between the two cannot be told apart); its dependencies
and the rest of the stack are never stopped, recreated or restarted.

**Podman** works: set `"hub": { "docker_command": "podman" }`, or point the
`docker` CLI at Podman's socket. For compose entries `podman compose` must hand
over to Docker Compose (its default provider when it is installed), not to
podman-compose.

## Docker image

The `raudssus/mcp-hub` image is **batteries-included**: the stdio upstreams the
hub spawns run *inside* the container, so it ships the runtimes they need — Node
(with `npx`), Python (`uv`/`uvx`), Deno and Bun. Upstream secrets referenced as
`${VAR}` in your `.mcp.json` are read from the container's environment (`-e` /
`env_file`). See [Quick start](#quick-start) for the basic `docker run` and
`docker compose` invocations.

- **It binds `0.0.0.0` inside the container.** The container's `CMD` overrides
  the `127.0.0.1` configuration default, so `-p` actually works. To change the
  port keep the flag: `… raudssus/mcp-hub daemon -l http://0.0.0.0:9000`. Who can
  reach it is decided by what you publish: `-p 127.0.0.1:3080:3080` is this
  machine only, `-p 3080:3080` is everyone who can reach the host — use
  [clients mode](#two-modes) for that.
- **`docker exec mcp-hub mcp-hub status`** (and `refresh`, `config`) work inside
  the running container.
- **The `/cache` volume holds everything regenerable** — the manifest cache,
  on-demand Node versions, and the npm/uv/deno/bun package caches — so restarts
  are warm. Delete it to reset; you'll see files appear there as they're fetched.
- **`tini` is built in** as PID 1, so the stdio children the hub stops after
  their idle timeout are reaped for you — no `--init` needed.
- **Rootless Podman:** a bind-mounted `./cache` isn't writable by the container
  user because of the uid mapping. Add `:U` to the mount
  (`-v "$PWD/cache:/cache:U"`), run with `--userns=keep-id`, or use a named
  volume (`-v mcp-hub-cache:/cache`, as in the quick start). Under Docker the
  bind mount just works.

### A Node version per upstream

The default Node is baked in (major 22). To pin a different version for one
server, prefix its command with `with-node <version>`; that version is fetched
into `/cache/node/<version>` on first use and reused afterwards:

```json
{
  "mcpServers": {
    "modern": { "command": "npx",       "args": ["-y", "@some/mcp"] },
    "legacy": { "command": "with-node", "args": ["18", "npx", "-y", "@old/mcp"] }
  }
}
```

Python versions come for free the same way via `uvx --python 3.11 …`.

### Docker-based upstreams

[`docker` and `compose` entries](#mcp-servers-in-docker-containers) (and
servers launched with `command: "docker"`) work inside the image: the Docker
CLI and its compose plugin are in it. Mount the daemon's socket, and give the
container user access to it:

```bash
docker run … -v /var/run/docker.sock:/var/run/docker.sock \
  --group-add "$(stat -c %g /var/run/docker.sock)" raudssus/mcp-hub
```

The containers the hub starts are then **siblings** of the hub's own container,
created by the host's daemon. Three things follow:

- **The hub must reach them over a network**, not over the host's `127.0.0.1`.
  Put the hub on a named network and tell it to use it — the bundled
  `docker-compose.yml` names its default network `mcp-hub`:

  ```json
  { "hub": { "docker_network": "mcp-hub" } }
  ```

  HTTP containers then join that network instead of publishing a port, and the
  hub reaches them as `http://mcp-hub-<name>:<port><path>`.
- **A compose HTTP service needs its `url`.** Without one the hub connects to
  where `docker compose port` says the service is published — an address on the
  host, which from inside the hub's container is not reachable as
  `127.0.0.1`. `docker_network` applies to `docker` entries only. Give the entry
  its `url`: with the hub on the project's network, say,
  `"url": "http://mcp:8080/mcp"`.
- **Host paths are host paths.** `volumes` and the bind mounts of a compose
  project are resolved by the host's daemon, not inside the hub's container.
- **Mount a compose directory at the same path** it has on the host
  (`-v /srv/mcp/stack:/srv/mcp/stack:ro`), so that `compose` names one directory
  for the hub and for the daemon alike.

Rootless Podman: mount its socket instead
(`-v "$XDG_RUNTIME_DIR/podman/podman.sock:/var/run/docker.sock"`).

### Building the image

```bash
docker build -t raudssus/mcp-hub \
  --build-arg NODE_VERSION=20 \
  --build-arg DOCKER_CLI_VERSION=27.3.1 \
  --build-arg DOCKER_COMPOSE_VERSION=2.29.7 .
```

Need a runtime the image doesn't ship? It's an ordinary Debian base — start a new
image `FROM raudssus/mcp-hub` and add it.

## Testing

```bash
dzil test          # or: prove -l -r t/
```

The suite spawns only one upstream, a tiny Perl stdio server
(`t/upstream/echo.pl`) — no node, no network. Its server is a class,
`t/lib/EchoServer.pm`, which `t/fork.t` also mounts as a forked class (Linux). A separate **live** integration
test exercises the hub against a real classic npx MCP server
(`@modelcontextprotocol/server-everything`); it is off by default and only runs
when you opt in or during a release, and `npx` with a recent enough node is on
`PATH`:

```bash
MCP_HUB_TEST_NPX=1 prove -l t/npx.t
```

A plain `dzil test` never touches npm or the network; only an explicit
`MCP_HUB_TEST_NPX=1` or a genuine release run (`RELEASE_TESTING`, i.e.
`dzil release` / `dzil test --release`) exercises the live server.

The `docker` and `compose` upstreams are tested against a fake Docker CLI
(`t/upstream/fake-docker.pl`, selected with `hub.docker_command`) whose
"containers" are `echo.pl` — no daemon, no image. The live counterpart runs a
real `mcp/time` container and is opt-in the same way:

```bash
MCP_HUB_TEST_DOCKER=1 prove -l t/docker-live.t
```

## How it works

```
agent (Claude Code, …)          mcp-hub daemon (one Mojo::IOLoop process)          upstreams
                                ┌────────────────────────────────────────┐
POST /context7  ─ Bearer ─▶     │ Auth ─▶ Facade(context7) ─▶ Upstream::Stdio ─▶ npx context7-mcp
POST /playwright ────────▶      │      ─▶ Facade(playwright) ─▶ Upstream::Stdio ─▶ npx @playwright/mcp
POST /run  ──────────────▶      │      ─▶ Upstream::Perl ───────────────▶ MCP::Run (in-process)
POST /wiki ──────────────▶      │      ─▶ Upstream::Fork ───────────────▶ MCP::Wiki::Server (forked worker)
POST /crawl4ai ──────────▶      │      ─▶ Upstream::Http ───────────────▶ remote server (HTTP / SSE)
POST /time ──────────────▶      │      ─▶ Upstream::Docker ─────────────▶ docker run -i mcp/time
POST /all  ──────────────▶      │      ─▶ Aggregate ─▶ (all of the above, prefixed)
GET  /_hub/status ───────▶      │      ─▶ admin API
                                └────────────────────────────────────────┘
                                   manifests: ~/.cache/mcp-hub/manifests/*.json
```

The agent-facing side is `MCP` as shipped — both protocol revisions, header
checks, SSE, auth. The hub adds a legacy stdio client for the upstreams (so it
can talk to the npm and Python servers in the wild) and the glue in between.
A stdio upstream is spawned on the first `tools/call`, its handshake and tool
list cached as a manifest, and it is terminated again after an idle timeout.

The hub runs as **one process** that serves HTTP and owns all state (never
hypnotoad or a pre-forking server: every worker would spawn its own children
and hold its own state, which defeats the purpose). Its child processes are
exec'd upstreams or [forked class workers](#forked-class-workers); a worker
never runs the hub's event loop, holds none of its fds or signal handlers, and
ends with `_exit`. Child processes, idle timers, manifests and in-process
servers all live in that one event loop, and tool calls are non-blocking, so one
slow upstream never blocks the others — except a tool of an in-process `class`,
which runs inside the loop.

## Configuration reference

### JSON or YAML

The config file is JSON or YAML, and **the extension decides**: `.yml` / `.yaml`
is read as YAML, every other name — `.mcp.json`, no extension at all — as JSON.
YAML is a second spelling of the same structure, not a second feature set: same
keys, same validation, same error messages, `${VAR}` expansion and all. What it
buys you is comments, so a server can be annotated, or switched off for an
afternoon instead of deleted:

```yaml
mcpServers:
  context7:
    command: npx
    args: ["-y", "@upstash/context7-mcp@latest"]
  # playwright:            # off while I debug the browser cache
  #   command: npx
  #   args: ["@playwright/mcp@latest", "--headless"]
  serper:
    command: npx
    args: ["-y", "serper-search-scrape-mcp-server@latest"]
    env:
      SERPER_API_KEY: ${SERPER_API_KEY}
    hub:
      idle_timeout: 120
hub:
  profiles:
    full: { servers: ["*"], admin: true }
  clients:
    main: { token: "${HUB_TOKEN_MAIN}", profile: full }
```

Without `--config` / `$MCP_HUB_CONFIG` the hub looks for `config.json`, then
`config.yml`, then `config.yaml` in `~/.config/mcp-hub/` and takes the first that
exists. A file must hold a single YAML document; duplicate keys are an error,
and no YAML tag can construct an object. `mcp-hub config` always prints JSON —
that output is for MCP clients.

The Docker image sets `MCP_HUB_CONFIG_DIR=/config` and finds `mcp.json`, then
`mcp.yml`, then `mcp.yaml` there (first that exists, JSON leading), so a YAML
config just needs mounting under one of those names — no env override:

```bash
docker run … -v "$PWD/mcp.yml:/config/mcp.yml:ro" raudssus/mcp-hub
```

### `mcpServers` entries

Exactly one of `command`, `class`, `url`, `docker` or `compose` is required.

| Key | Meaning |
|---|---|
| `command`, `args`, `env`, `cwd` | A stdio child, as in `.mcp.json`. `env` is merged over the hub's environment. |
| `class` | A Perl `MCP::Server` subclass, or a class whose instances have a `server` method returning one; loaded and mounted in-process. `env`, `cwd`, `headers` and `type` are errors on it. |
| `args` (with `class`) | Hash passed to the class's `new` as it is — no `${VAR}`, no `~`. |
| `hub.fork` (with `class`) | `true` runs the class's calls in a [forked worker](#forked-class-workers) (Linux). An error on any other entry. |
| `url` | A remote HTTP MCP server. |
| `type` (with `url`) | `http` (Streamable HTTP, the default) or `sse` (the older HTTP+SSE transport, e.g. a `…/sse` URL). |
| `headers` (with `url`) | Extra request headers, such as `{ "Authorization": "Bearer …" }`. |
| `docker` | An image: a [container](#mcp-servers-in-docker-containers) the hub starts and stops. |
| `args` (with `docker`) | Container arguments, after the image. |
| `env` (with `docker`) | Passed as bare `-e KEY`; the values never appear on a command line. |
| `env` (with `compose`) | The environment of the compose command — what `${VAR}` in the compose file sees. |
| `volumes` (with `docker`) | `-v` specs, `/host:/container[:ro]` or `name:/container`; a leading `~` is expanded. |
| `docker_args` (with `docker`) | Extra `docker run` flags, before the image (`--memory`, `--gpus`, `--user`, …). |
| `compose` | A compose project directory; `~` is expanded. |
| `service` (with `compose`) | **Required.** The one service that is the MCP server. |
| `url` (with `compose`) | Where the service answers; skips the port lookup. |
| `port` (with `docker`, `compose`) | The container port the server listens on: HTTP on it. Optional when the image `EXPOSE`s (or the service publishes) exactly one. |
| `stdio` (with `docker`, `compose`) | `true` forces stdio, even when a port would be detected. |
| `path`, `type`, `headers` (with `docker`, `compose`) | For an HTTP container: the URL path (default `/mcp`), `http` or `sse`, extra headers. |
| `hub.idle_timeout` | Seconds; `0` means never stop. Overrides the global default (stdio, docker, compose and forked class). |
| `hub.always_on` | Start at daemon start and never stop. |
| `hub.request_timeout` | Seconds per request. |

On a `class` entry without `hub.fork` the three are an error: it has no process
of its own.

```json
{
  "mcpServers": {
    "remote":   { "url": "https://example.com/mcp", "headers": { "Authorization": "Bearer ${TOKEN}" } },
    "crawl4ai": { "url": "http://10.0.0.5:11235/mcp/sse", "type": "sse" }
  }
}
```

`${VAR}` and `${VAR:-default}` are expanded in `command`, `args`, `env`, `cwd`,
`url`, `headers`, `docker`, `volumes`, `docker_args` and `compose`, and in the
`hub` block in `listen`, `cache_dir`, `docker_command`, `docker_network` and
each client's `token`. An unset variable without a default is a config error at
start.

### `hub` block

| Key | Default | Meaning |
|---|---|---|
| `listen` | `http://127.0.0.1:3080` | Listen address. |
| `cache_dir` | `~/.cache/mcp-hub` | Where manifests are cached. |
| `idle_timeout` | `300` | Seconds before an idle stdio, docker or compose upstream, or a forked class worker, is stopped. |
| `request_timeout` | `60` | Seconds to wait for an upstream response. |
| `profiles` | `{}` | Named permission sets. |
| `clients` | `{}` | `name → { token, profile }`. |
| `public_profile` | `null` | Profile for tokenless requests in clients mode. |
| `auto_reload` | `false` | Watch the config file and [reload](#changing-the-config-while-it-runs) when it changes. |
| `docker_command` | `docker` | The CLI for `docker` and `compose` entries; `podman` works too. |
| `docker_network` | unset | HTTP containers join this network instead of publishing a port, and are reached by name — for a hub [that runs in a container](#docker-based-upstreams) itself. |

`listen` and `cache_dir` take effect at start only; everything else can be
changed by a reload.

## Non-goals (v1)

- Per-client instances of the same upstream (one browser per agent). v1 shares
  every upstream.
- Forwarding server-initiated `sampling/createMessage` and `elicitation/create`
  to the agent — answered with an error.
- Resource subscriptions and `resources/templates`.
- OAuth. Tokens are static strings in the config.

## Requirements

To run the Docker image you need only Docker (or Podman) — everything else is in
the image. For the CPAN install: Perl 5.20+,
[`Mojolicious`](https://metacpan.org/pod/Mojolicious) 9.49+,
[`MCP`](https://metacpan.org/pod/MCP) ≥ 0.15, `CryptX`,
[`IO::Socket::SSL`](https://metacpan.org/pod/IO::Socket::SSL) 2.009+ for TLS —
`https://` `url` upstreams and an `https://` `hub.listen` (its `Net::SSLeay`
compiles against the OpenSSL and zlib development files, e.g. Debian's
`libssl-dev` and `zlib1g-dev`), and the pure-Perl
[`YAML::PP`](https://metacpan.org/pod/YAML::PP) (loaded only when a YAML config
is read). No process-management dependencies; everything else is core. On a perl
without TLS, an `https://` `url` upstream shows up as `failed`, with the fix in
its reason.

## License

This software is copyright (c) 2026 by Torsten Raudssus. It is free software and
may be redistributed under the same terms as Perl itself.
