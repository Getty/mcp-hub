<p align="center">
  <img src="assets/github.png" alt="MCP-Hub — A lot of MCP for very little RAM." width="100%">
</p>

# MCP-Hub

**A lot of MCP for very little RAM.**

`mcp-hub` is a single HTTP MCP server that embeds any number of stdio MCP
servers (context7, playwright, serper, …), in-process Perl MCP servers, and
remote HTTP MCP servers (Streamable HTTP or HTTP+SSE), and hands each of them to
every agent on the machine as its own endpoint. It runs each server **once per
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
# Secrets the config references as ${VAR} (API keys, client tokens); optional.
EnvironmentFile=-%h/.config/mcp-hub/env

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now mcp-hub
```

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
| `mcp-hub status [--client NAME] [--url BASE]` | Table of the running hub's upstreams and clients. |
| `mcp-hub refresh [NAME] [--client NAME] [--url BASE]` | Re-fetch manifests; also the way to retry a `failed` server. |
| `mcp-hub reload [--client NAME] [--url BASE]` | Re-read the config and apply only what changed. |
| `mcp-hub token` | Print a fresh random bearer token. |

A global `--config PATH` (or `-c PATH`, or `$MCP_HUB_CONFIG`) selects the config
file for every command.

`status`, `refresh` and `reload` talk to the running daemon at the config's `listen`
address (a wildcard such as `0.0.0.0` or `[::]` is reached over loopback). If the
daemon listens somewhere else — `daemon -l …`, a remapped Docker port, another
machine — point them at it with `--url http://host:port`. In clients mode they
authenticate as the first `admin` client, or the one named with `--client`.

## Changing the config while it runs

You do not restart the hub to change its config. A **reload** re-reads the file
and changes exactly what the edit asks for — everything else keeps running:

| You edit… | What happens |
|---|---|
| nothing about a server | Nothing. Same process, same stats, same idle timer. |
| a profile, a client, `tools.allow`/`deny`, `public_profile` | Swapped in place; in effect on the next request. A tool you deny disappears from `tools/list` and `tools/call`, and no server is restarted. |
| only timeouts (`idle_timeout`, `request_timeout`, per server or global) | Applied in place, no restart. |
| a server's `command`, `args`, `env`, `url`, … | That one server is stopped and rebuilt. |
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

## Native Perl servers

`mcp-hub` ships native Perl replacements for small helpers that today cost a
node process per session:

- **`MCP::Hub::Native::ClaudeHistory`** — browse the local Claude Code history:
  `list_projects`, `list_sessions`, `search_conversations`, `get_conversation`.
- **`MCP::Hub::Native::ClaudeSessions`** — `list_running_sessions`, the live
  `claude` processes on the machine and what each is working on (Linux).
- **`MCP::Hub::Native::Status`** — `hub_status` and `hub_refresh` as tools.

Any `MCP::Server` subclass can be mounted in-process with a `class` entry —
`MCP::Run`, `MCP::K8s`, or your own — with no subprocess at all:

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

Some servers are launched with `command: "docker"`. The Docker **CLI** is in the
image; mount the daemon socket to let them run:

```bash
docker run … -v /var/run/docker.sock:/var/run/docker.sock raudssus/mcp-hub
```

### Building the image

```bash
docker build -t raudssus/mcp-hub \
  --build-arg NODE_VERSION=20 \
  --build-arg DOCKER_CLI_VERSION=27.3.1 .
```

Need a runtime the image doesn't ship? It's an ordinary Debian base — start a new
image `FROM raudssus/mcp-hub` and add it.

## Testing

```bash
dzil test          # or: prove -l -r t/
```

The suite spawns only one upstream, a tiny Perl stdio server
(`t/upstream/echo.pl`) — no node, no network. A separate **live** integration
test exercises the hub against a real classic npx MCP server
(`@modelcontextprotocol/server-everything`); it is off by default and only runs
when you ask for it and `npx` with a recent enough node is on `PATH`:

```bash
MCP_HUB_TEST_NPX=1 prove -l t/npx.t
```

## How it works

```
agent (Claude Code, …)          mcp-hub daemon (one Mojo::IOLoop process)          upstreams
                                ┌────────────────────────────────────────┐
POST /context7  ─ Bearer ─▶     │ Auth ─▶ Facade(context7) ─▶ Upstream::Stdio ─▶ npx context7-mcp
POST /playwright ────────▶      │      ─▶ Facade(playwright) ─▶ Upstream::Stdio ─▶ npx @playwright/mcp
POST /run  ──────────────▶      │      ─▶ Upstream::Perl ───────────────▶ MCP::Run (in-process)
POST /crawl4ai ──────────▶      │      ─▶ Upstream::Http ───────────────▶ remote server (HTTP / SSE)
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

The hub runs as **one process** (never hypnotoad or a pre-forking server):
every worker would spawn its own children and hold its own state, which defeats
the purpose. Child processes, idle timers, manifests and in-process servers all
live in one event loop, and tool calls are non-blocking, so one slow upstream
never blocks the others.

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

The Docker image sets `MCP_HUB_CONFIG=/config/mcp.json`, so to use YAML there,
mount the file under a YAML name and point the variable at it:

```bash
docker run … -v "$PWD/mcp.yml:/config/mcp.yml:ro" -e MCP_HUB_CONFIG=/config/mcp.yml raudssus/mcp-hub
```

### `mcpServers` entries

Exactly one of `command`, `class` or `url` is required.

| Key | Meaning |
|---|---|
| `command`, `args`, `env`, `cwd` | A stdio child, as in `.mcp.json`. `env` is merged over the hub's environment. |
| `class` | A Perl `MCP::Server` subclass, loaded and mounted in-process. |
| `args` (with `class`) | Hash passed to the class's `new`. |
| `url` | A remote HTTP MCP server. |
| `type` (with `url`) | `http` (Streamable HTTP, the default) or `sse` (the older HTTP+SSE transport, e.g. a `…/sse` URL). |
| `headers` (with `url`) | Extra request headers, such as `{ "Authorization": "Bearer …" }`. |
| `hub.idle_timeout` | Seconds; `0` means never stop. Overrides the global default (stdio only). |
| `hub.always_on` | Start at daemon start and never stop. |
| `hub.request_timeout` | Seconds per request. |

```json
{
  "mcpServers": {
    "remote":   { "url": "https://example.com/mcp", "headers": { "Authorization": "Bearer ${TOKEN}" } },
    "crawl4ai": { "url": "http://10.0.0.5:11235/mcp/sse", "type": "sse" }
  }
}
```

`${VAR}` and `${VAR:-default}` are expanded in `command`, `args`, `env`, `cwd`,
`url` and `headers`, and in the `hub` block in `listen`, `cache_dir` and each
client's `token`. An unset variable without a default is a config error at
start.

### `hub` block

| Key | Default | Meaning |
|---|---|---|
| `listen` | `http://127.0.0.1:3080` | Listen address. |
| `cache_dir` | `~/.cache/mcp-hub` | Where manifests are cached. |
| `idle_timeout` | `300` | Seconds before an idle stdio upstream is stopped. |
| `request_timeout` | `60` | Seconds to wait for an upstream response. |
| `profiles` | `{}` | Named permission sets. |
| `clients` | `{}` | `name → { token, profile }`. |
| `public_profile` | `null` | Profile for tokenless requests in clients mode. |
| `auto_reload` | `false` | Watch the config file and [reload](#changing-the-config-while-it-runs) when it changes. |

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
[`MCP`](https://metacpan.org/pod/MCP) ≥ 0.15, `CryptX`, and the pure-Perl
[`YAML::PP`](https://metacpan.org/pod/YAML::PP) (loaded only when a YAML config
is read). No process-management dependencies; everything else is core.

## License

This software is copyright (c) 2026 by Torsten Raudssus. It is free software and
may be redistributed under the same terms as Perl itself.
