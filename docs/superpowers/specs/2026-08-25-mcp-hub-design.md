# MCP::Hub — Design

**Status:** Draft for review
**Date:** 2026-08-25
**Scope:** A single HTTP MCP server (`mcp-hub`) that embeds any number of stdio MCP servers and in-process Perl MCP servers, exposes each of them to many agents on the same machine as its own endpoint, decides per client which of them it may use, and prints ready-to-paste client configuration. Goal in one line: a lot of MCP for very little RAM.

## Goals

1. **Run each MCP server once per machine, not once per agent session.** Today every Claude Code session spawns its own copy of every stdio server. On this machine that is ~2.2 GB RSS of node processes (context7, playwright, serper, claude-code-history, plus an idle `npm exec` wrapper of ~85 MB each) for three sessions.
2. **Keep the agent's view identical to a direct start.** Each embedded server is its own endpoint with unchanged tool names, so `mcp__context7__resolve-library-id` stays `mcp__context7__resolve-library-id`, existing permission rules keep working, and the `/mcp` menu still lists servers separately.
3. **Start lazily, stop when idle.** `tools/list` is answered from a cached manifest; the child process is spawned on the first `tools/call` and terminated after an idle timeout. Playwright's ~110 MB exist only while someone uses it.
4. **Tell agents apart.** Two modes on one code path: *open* (no tokens, everyone sees everything — the "insecure / unified" setup) and *clients* (bearer token → profile → allowed servers and tools). Both mixable through a public profile.
5. **Config is a superset of `.mcp.json`.** An existing `mcpServers` block is a valid hub config; entries are copied 1:1.
6. **Export client config.** `mcp-hub config --client NAME` prints the `mcpServers` JSON an agent needs, one HTTP entry per allowed server.
7. **Ship native Perl replacements for small helpers**, starting with Claude Code history and live session discovery, which today cost a 120 MB node process per session.
8. **Mount Perl MCP servers in-process.** Any `MCP::Server` subclass (`MCP::Run`, `MCP::K8s`, the native modules) is an upstream without a subprocess.

## Non-goals (v1)

- Per-client instances of the same upstream (`sharing: per-client`, e.g. one Playwright browser per agent). The design leaves room for it; v1 shares every upstream.
- HTTP/SSE upstreams (`url` entries). They are rejected at config load with a clear message.
- Modern-only (`2026-07-28`) stdio upstreams. v1 opens every stdio upstream with the legacy `initialize` handshake, which every legacy and dual-era server (including Perl `MCP` ≥ 0.15) accepts; the `server/discover` probe with modern fallback is a follow-up.
- Forwarding server-initiated requests (`sampling/createMessage`, `elicitation/create`) to the agent. They are answered with a JSON-RPC error.
- Resource subscriptions and `resources/templates`.
- A full-text index over the Claude history (932 MB, 1190 sessions here). v1 streams and filters.
- OAuth. Tokens are static strings in the config.
- Multi-user machines with different Unix users. The hub runs as one user for that user's agents; tokens separate agents, not users.

## Background

### What exists

- **`MCP` 0.15** (Mojolicious-based, installed) implements protocol revision `2026-07-28`, which is stateless: no `initialize` handshake, no session, `server/discover` + `tools/list` + `tools/call`, protocol version and client capabilities in `_meta`. `MCP::Server::Legacy` accepts the classic revisions (`2024-10-07` … `2025-11-25`) on the server side, including the `initialize` handshake. `MCP::Server::Transport::HTTP` handles Streamable HTTP, SSE upgrade for notifications, an `auth` callback (`sub ($c) { {principal => …, scopes => […]} }`) and a header/body consistency check. `MCP::Server` emits `tools`, `prompts`, `resources` events with `($server, $arrayref, $context)` where the list can be filtered per request. `MCP::Tool::call` passes a hash with `content` through unchanged.
- **`MCP::Client` 0.15** speaks only the new revision over HTTP. It has no stdio transport and no legacy mode, so it cannot talk to npm/python servers. The upstream client is ours to write.
- **Claude Code 2.1.241** (verified against a probe server on 2026-08-25): connects to an `MCP` 0.15 HTTP endpoint (`✔ Connected`), speaks `2026-07-28` (`server/discover`, then `tools/list`), sends `Authorization: Bearer …` from the config `headers`, `User-Agent: claude-code/2.1.241 (sdk-cli)`, no session id.
- **stdio servers in the wild** (context7, playwright, serper, …) speak the classic revision: `initialize` → `notifications/initialized` → `tools/list` with cursor pagination → `tools/call`. They may send `notifications/tools/list_changed`, `notifications/message`, and server-to-client requests (`roots/list`, `sampling/createMessage`, `elicitation/create`).
- **Claude history** lives in `~/.claude/projects/<path-with-slashes-as-dashes>/<session-uuid>.jsonl`, one JSON object per line with `type` (`user`, `assistant`, `system`, `summary`, `ai-title`, `last-prompt`, …), `uuid`, `parentUuid`, `sessionId`, `timestamp`, `cwd`, `gitBranch`, `version`, and `message` (`role`, `content` as string or array of typed blocks).
- **Running sessions** are `claude` processes; `/proc/<pid>/cwd` gives the project directory.

### Why one Mojolicious process with `MCP::Server` façades

Three approaches were considered. **A** (chosen): one Mojolicious process; every upstream is presented through its own `MCP::Server` instance, so the agent-facing side — both protocol revisions, header checks, SSE, auth — is `MCP` 0.15 as shipped, and the hub only adds the upstream stdio client and glue. **B**, a raw JSON-RPC proxy, would re-implement all of that. **C**, an IO::Async stack, loses `MCP::Server` entirely and collapses into B.

## Architecture

```
agent (Claude Code, …)             mcp-hub daemon (one process, Mojo::IOLoop)                 upstreams
                                   ┌─────────────────────────────────────────────┐
POST /context7  ── Bearer ──▶      │ Auth under ─▶ Facade(context7) ──▶ Upstream::Stdio ── pipes ──▶ npx context7-mcp
POST /playwright ─────────▶        │             ─▶ Facade(playwright) ─▶ Upstream::Stdio ── pipes ──▶ npx @playwright/mcp
POST /run  ───────────────▶        │             ─▶ Upstream::Perl ─────────────────────────▶ MCP::Run (in-process)
POST /claude-history ─────▶        │             ─▶ Upstream::Perl ─────────────────────────▶ MCP::Hub::Native::ClaudeHistory
POST /all  ───────────────▶        │             ─▶ Aggregate ──▶ (all of the above, prefixed)
GET  /_hub/status ────────▶        │             ─▶ admin API
                                   └─────────────────────────────────────────────┘
                                      manifests: ~/.cache/mcp-hub/manifests/*.json
```

### Process model

`mcp-hub daemon` runs a single `Mojo::Server::Daemon` process. It must not run under hypnotoad or prefork: every worker would spawn its own children and hold its own state, which defeats the purpose. Everything — child processes, idle timers, manifests, in-process servers — lives in this one event loop. Tool calls are non-blocking promises, so one slow upstream does not block the others.

Default listen address is `http://127.0.0.1:3080`. The daemon runs in the foreground; the README ships a systemd user unit.

### Module layout

| Module | Responsibility |
|---|---|
| `MCP::Hub` | Mojolicious application. `startup` loads the config, builds upstreams, mounts routes, starts background manifest fetches. Holds `config`, `upstreams`, `auth`. |
| `MCP::Hub::Config` | Load JSON, validate, expand `${VAR}` / `${VAR:-default}`, apply defaults, derive mode. Pure data, no I/O beyond reading the file. |
| `MCP::Hub::Auth` | Resolve `Authorization` header → client → profile. Provides the `under` handler (401/404) and the per-request tool filter attached to every server's `tools` event. |
| `MCP::Hub::Manifest` | Read/write manifest cache files, compute the command hash, decide freshness. |
| `MCP::Hub::Upstream` | Base class: `name`, `config`, `state`, `server` (the `MCP::Server` agents talk to), `start_p`, `stop`, `refresh_p`, `last_used`, `stats`. |
| `MCP::Hub::Upstream::Stdio` | Child process management and the legacy JSON-RPC client. Builds its `server` from the manifest via `MCP::Hub::Facade`. |
| `MCP::Hub::Upstream::Perl` | Instantiates a `class` once; `server` is that instance. |
| `MCP::Hub::Facade` | Builds an `MCP::Server` from a manifest whose tools, prompts and resources forward to an upstream. |
| `MCP::Hub::Facade::Tool` | `MCP::Tool` subclass with `validate_input` disabled (the upstream validates; `JSON::Schema::Tiny` rejects some `$ref`-heavy schemas) and an `extra` hash (`title`, `icons`, `_meta`) for the list rendering. |
| `MCP::Hub::Facade::Server` | `MCP::Server` subclass whose list rendering includes the `extra` fields of façade primitives. |
| `MCP::Hub::Aggregate` | The `/all` server: union of every upstream's tools and prompts with a `<name>__` prefix. |
| `MCP::Hub::Native::ClaudeHistory` | `MCP::Server` subclass: history tools. |
| `MCP::Hub::Native::ClaudeSessions` | `MCP::Server` subclass: live session discovery. |
| `MCP::Hub::Native::Status` | `MCP::Server` subclass: hub introspection; receives `hub`. |
| `MCP::Hub::Command::{config,refresh,status,token}` | Mojolicious commands behind `bin/mcp-hub`. |

Every unit can be tested alone: `Config` on strings, `Manifest` on a temp dir, `Auth` on a config hash, `Facade` on a manifest hash with a mock upstream, `Upstream::Stdio` against a Perl test server script, the natives against fixture directories.

## Configuration

One JSON file. Location: `--config PATH`, else `$MCP_HUB_CONFIG`, else `~/.config/mcp-hub/config.json`.

```json
{
  "mcpServers": {
    "context7":        { "command": "npx", "args": ["-y", "@upstash/context7-mcp@latest"] },
    "playwright":      { "command": "npx", "args": ["@playwright/mcp@latest", "--headless"],
                         "hub": { "idle_timeout": 120 } },
    "serper":          { "command": "npx", "args": ["-y", "serper-search-scrape-mcp-server@latest"],
                         "env": { "SERPER_API_KEY": "${SERPER_API_KEY}" } },
    "run":             { "class": "MCP::Run", "args": { "allowed_commands": ["ls", "cat", "grep"] } },
    "claude-history":  { "class": "MCP::Hub::Native::ClaudeHistory" },
    "claude-sessions": { "class": "MCP::Hub::Native::ClaudeSessions" },
    "hub":             { "class": "MCP::Hub::Native::Status" }
  },
  "hub": {
    "listen": "http://127.0.0.1:3080",
    "cache_dir": "~/.cache/mcp-hub",
    "idle_timeout": 300,
    "request_timeout": 60,
    "profiles": {
      "full":     { "servers": ["*"], "admin": true },
      "research": { "servers": ["context7", "serper", "claude-history"],
                    "tools": { "serper": { "deny": ["scrape"] } } }
    },
    "clients": {
      "main":     { "token": "…", "profile": "full" },
      "worker-1": { "token": "…", "profile": "research" }
    },
    "public_profile": null
  }
}
```

### `mcpServers` entries

Exactly one of `command` or `class` is required.

| Key | Meaning |
|---|---|
| `command`, `args`, `env`, `cwd` | As in `.mcp.json`. `env` is merged over the hub's own environment. `cwd` defaults to the hub's working directory. |
| `class` | Perl class name, loaded with `Mojo::Loader::load_class`. Must be an `MCP::Server` subclass. |
| `args` (with `class`) | Hash passed to `new`. If the class has a `hub` attribute, the `MCP::Hub` instance is injected. |
| `url`, `type: "http"/"sse"` | Rejected: "HTTP upstreams are not supported yet". |
| `hub.idle_timeout` | Seconds. Overrides `hub.idle_timeout`. `0` means never stop. |
| `hub.always_on` | Boolean. Start at daemon start and never stop. Equivalent to `idle_timeout: 0` plus eager start. |
| `hub.request_timeout` | Seconds per request. Overrides the global value. |

Server names must match `^[A-Za-z0-9][A-Za-z0-9_-]*$`. `all` and names starting with `_` are reserved. Unknown keys inside an entry are an error, so typos surface at start.

### `${VAR}` expansion

`${VAR}` and `${VAR:-default}` are expanded in `command`, every element of `args`, every value of `env`, and `cwd` — the same places Claude Code expands them. An unset variable without a default is a config error at load time. (Claude Code only warns and keeps the literal `${VAR}`; a daemon that would then run `npx` with a literal `${API_KEY}` for hours is better off refusing to start.)

### `hub` block

| Key | Default | Meaning |
|---|---|---|
| `listen` | `http://127.0.0.1:3080` | Passed to `Mojo::Server::Daemon`. |
| `cache_dir` | `$XDG_CACHE_HOME/mcp-hub` or `~/.cache/mcp-hub` | Manifest cache lives in `<cache_dir>/manifests/`. |
| `idle_timeout` | `300` | Seconds of no requests before a stdio upstream is stopped. |
| `request_timeout` | `60` | Seconds to wait for an upstream response. |
| `profiles` | `{}` | Named sets of permissions, see below. |
| `clients` | `{}` | `name → { token, profile }`. |
| `public_profile` | `null` | Profile applied to requests without a token when `clients` is non-empty. |

### Mode

The mode is derived, not declared:

- `clients` empty → **open**. No token is checked; every request sees every upstream; the admin API is open.
- `clients` non-empty → **clients**. A request must carry a bearer token matching a client, or — if `public_profile` is set — it gets that profile. Anything else is 401.

A `.mcp.json` with no `hub` block is therefore a valid open-mode hub config.

### Profiles

| Key | Meaning |
|---|---|
| `servers` | List of server names, or `["*"]`. |
| `tools` | `server → { allow: […], deny: […] }`. If `allow` is present only those tools are visible; `deny` is then subtracted. Applies to tools only; prompts and resources follow `servers`. |
| `admin` | Boolean. Grants the admin API (`/_hub/*`) and the `hub_refresh` tool. |

A client whose profile does not include a server gets **404** for that server's path, so it cannot tell the server exists. Tool filtering is applied both to `tools/list` and to `tools/call` (a denied tool is "not found"), implemented as a handler on the `tools` event of every mounted `MCP::Server`.

Tokens are compared in constant time (`Crypt::Misc::slow_eq`, already a dependency of `MCP`).

## Endpoints

| Route | Handler | Notes |
|---|---|---|
| `POST /<name>` | that upstream's `server->to_action({streaming => 1})` | Tool names unchanged. `streaming` enables `subscriptions/listen`, which Claude Code's v2 runtime holds open to receive `notifications/tools/list_changed` after a manifest refresh; it is per-process state, which is fine in the single daemon process. |
| `POST /all` | `MCP::Hub::Aggregate` | Tools and prompts of all servers the client may see, as `<name>__<tool>`. Resources are not aggregated (URIs are opaque and would collide); use the per-server endpoint. `instructions` is the concatenation `## <name>\n<instructions>` of the upstreams that have any. |
| `GET /_hub/status` | admin | JSON: per upstream `name, type, state, pid, rss_kb, manifest_fetched_at, last_used, calls, errors`; clients currently known (name, last seen). |
| `POST /_hub/refresh` | admin | Body `{"name": "context7"}` or empty for all. Re-fetches manifests; returns the new tool counts. |

All MCP routes sit under one `under` that runs `MCP::Hub::Auth`: it resolves the profile, stores it in the stash, answers 401/404, and passes through otherwise.

An upstream whose manifest is not available yet (still fetching at startup) or that is `failed` answers **503** with `{"error": "…"}` so that `claude mcp list` shows the failure with the URL instead of a server with zero tools.

## Upstreams

### Common interface (`MCP::Hub::Upstream`)

- `name`, `config`, `hub`
- `state`: `stopped | starting | ready | failed`
- `server`: the `MCP::Server` mounted at `/<name>`
- `start_p` → promise resolving when `ready`; idempotent (returns the in-flight promise while `starting`)
- `stop` → terminate, `stopped`
- `refresh_p` → re-fetch the manifest and rebuild `server`
- `touch` → resets `last_used` and the idle timer
- `stats`: `calls`, `errors`, `started_at`, `pid`

### `MCP::Hub::Upstream::Stdio`

**Spawning.** `pipe` × 3, `fork`, in the child: `chdir $cwd`, set `%ENV`, `exec $command @args`. The parent wraps stdout and stdin in `Mojo::IOLoop::Stream`. stdout is split on newlines and each line decoded as JSON; malformed lines are logged and skipped (Claude Code caps this at 16 MB — the hub caps the line buffer at 16 MB and kills the child if exceeded). stderr lines go to the hub log at `debug` as `[<name>] …`. No CPAN dependency for process handling.

**Handshake and manifest.**
1. `initialize` with `protocolVersion: "2025-06-18"`, `capabilities: {}`, `clientInfo: {name: "mcp-hub", version: $VERSION}`. Accept whatever version the server answers; remember it.
2. `notifications/initialized`.
3. `tools/list`, following `nextCursor` until exhausted. `prompts/list` and `resources/list` only if `capabilities` from the `initialize` result declare them; a `-32601` from either is tolerated and yields an empty list.
4. Assemble the manifest, write the cache, build the façade (or swap the tools of the existing one), state `ready`.

**Requests.** One integer id counter per upstream; `pending{id} = {promise, timer}`. `request_timeout` rejects the promise, sends `notifications/cancelled` for the id, and leaves the process running. A response with an unknown id is logged and dropped.

**Server-initiated traffic.**

| Incoming | Handling |
|---|---|
| `ping` request | answer `{}` |
| `roots/list` request | answer `{roots: []}` |
| `sampling/createMessage`, `elicitation/create`, anything else with an `id` | answer error `-32601 Method not supported by mcp-hub` |
| `notifications/tools/list_changed` (also prompts/resources) | mark manifest stale, run `refresh_p` in the background, log at `info` |
| `notifications/message` | log at the given level as `[<name>] …` |
| `notifications/progress` | dropped in v1 |

**Lifecycle.**

```
stopped ──start_p──▶ starting ──handshake ok──▶ ready ──idle timeout / stop──▶ stopped
                        │                          │
                        └── exec/handshake failed ──┴── child exited unexpectedly ──▶ stopped (pending requests rejected)
                                                        (3 exits within 5 s of start) ──▶ failed
```

- **Lazy start.** At daemon start a stdio upstream with a fresh cached manifest is `stopped` with a façade built from the cache; nothing is spawned. Without a cached manifest (or with a stale one, see below) it is started once in the background to fetch it; the daemon does not wait for that.
- **On demand.** The first `tools/call`, `prompts/get` or `resources/read` calls `start_p` and queues behind it; further calls during `starting` queue on the same promise.
- **Idle.** Every request calls `touch`. When the timer fires: close stdin, `SIGTERM`, after 5 s `SIGKILL`, reap with `waitpid`. `always_on` upstreams are started at daemon start and have no idle timer.
- **Crash.** On unexpected exit all pending promises are rejected (the façade turns that into an error result for the agent), state becomes `stopped`, and the next call starts the process again. Three exits within 5 s of their start mark the upstream `failed`; its endpoint answers 503 until `refresh` succeeds.
- **Shutdown.** `SIGINT`/`SIGTERM` to the daemon stops every child the same way before exiting.

### `MCP::Hub::Upstream::Perl`

Loads `class`, calls `new(%$args)` (plus `hub => $hub` when `$class->can('hub')`), stores the instance as `server`. State is always `ready`; `stop` and `refresh_p` are no-ops. There is no manifest because the instance answers `tools/list` itself.

## Manifest cache

File: `<cache_dir>/manifests/<name>-<hash>.json`, where `hash` is the first 16 hex characters of SHA-256 over the JSON encoding of `[command, args, cwd]` (not `env`, which may hold secrets). A changed command therefore never reuses a stale manifest.

```json
{
  "name": "context7",
  "hash": "…",
  "fetched_at": "2026-08-25T14:03:11Z",
  "protocol_version": "2025-06-18",
  "server_info": { "name": "…", "version": "…" },
  "capabilities": { … },
  "instructions": "…",
  "tools": [ … verbatim entries from tools/list … ],
  "prompts": [ … ],
  "resources": [ … ]
}
```

Refetched when: the file is missing or its `hash` differs; `refresh` is requested (CLI, admin API, `hub_refresh` tool); the upstream sends `list_changed`. There is no TTL in v1 — a stale manifest costs one wrong tool description until the next refresh, and refresh is cheap. Writes are atomic (write to a temp file in the same directory, rename).

## Façade

`MCP::Hub::Facade->build($upstream, $manifest)` returns an `MCP::Server` with `name`, `version` and `instructions` from the manifest and:

- one `MCP::Hub::Facade::Tool` per manifest tool, carrying `name`, `description`, `input_schema`, `output_schema`, `annotations` verbatim, plus the manifest entry's `title`, `icons` and `_meta` as an `extra` attribute. `MCP::Server` renders only name, description, inputSchema, outputSchema and annotations in `tools/list`, so the façade's server is an `MCP::Hub::Facade::Server` subclass that overrides the `tools/list` rendering to merge `extra` back in — otherwise Claude Code-specific annotations such as `_meta["anthropic/maxResultSizeChars"]` and `_meta["anthropic/requiresUserInteraction"]` would be lost on the way through the hub. Same for prompts (`title`, `icons`, `_meta`) and resources. Its `code` returns `$upstream->call_tool($name, $args)`, a promise resolving to the upstream's `tools/call` result (`content`, `isError`, `structuredContent`) unchanged. A JSON-RPC error from the upstream becomes `text_result("upstream <name>: <message>", 1)`; a transport failure (timeout, crash, failed to start) likewise. Structured content is not re-validated against the output schema; the upstream is trusted.
- one prompt per manifest prompt forwarding to `prompts/get` (result `{description, messages}` passed through).
- one resource per manifest resource forwarding to `resources/read` (result `{contents}` passed through).

Rebuilding after a refresh replaces the primitive lists of the existing `MCP::Server` in place, so the mounted route keeps its instance and `notify_list_changed` can be sent to streaming subscribers.

## Aggregate (`/all`)

Built once at start and rebuilt on any refresh. For every upstream `u` and every tool `t` of `u->server->tools` it registers a tool `<u>__<t>` whose `code` calls the original tool object directly (`$t->call($args, $context)`), so filtering, façade error handling and in-process servers all behave as on their own endpoint. Prompts likewise. The per-request `tools` filter applies the profile's `servers` and `tools` rules using the prefix to find the owning server.

## Native modules

All are `MCP::Server` subclasses registering their tools in `new`, so they work standalone (`->to_stdio`) as well as inside the hub.

### `MCP::Hub::Native::ClaudeHistory`

Reads `$CLAUDE_CONFIG_DIR` or `~/.claude`, subdirectory `projects/`. The project path is taken from the `cwd` of the first line of any session file, falling back to the directory name. Per session file a small metadata record (`session_id, project, started_at, last_activity, messages, first_prompt, title, git_branch`) is cached in memory keyed by `(path, mtime, size)` so repeated listings do not re-read unchanged files.

| Tool | Arguments | Result |
|---|---|---|
| `list_projects` | — | `[{project, dir, sessions, last_activity}]` |
| `list_sessions` | `project?`, `since?`, `until?` (filter on `last_activity`), `limit` (50) | `[{session_id, project, started_at, last_activity, messages, first_prompt, title, git_branch}]`, newest first |
| `search_conversations` | `query` (required), `project?`, `since?`, `until?`, `roles` (`["user"]`), `limit` (30) | `[{session_id, project, timestamp, role, snippet}]` — case-insensitive substring match over the text content, snippet ±120 characters |
| `get_conversation` | `session_id` (required), `offset` (0), `limit` (50), `roles` (`["user","assistant"]`) | `{entries: [{uuid, timestamp, role, text}], total, has_more}` — text blocks joined, `tool_use` blocks rendered as `[tool_use <name>]`, `tool_result` as `[tool_result]` |

Dates are ISO 8601; `since`/`until` accept `YYYY-MM-DD` or a full timestamp, interpreted in the hub's local time zone. Text content is `message.content` when a string, else the `text` fields of the block array.

### `MCP::Hub::Native::ClaudeSessions`

| Tool | Result |
|---|---|
| `list_running_sessions` | `[{pid, cwd, project, session_id, started_at, last_activity, last_prompt, git_branch}]` |

Process discovery: `/proc/*/comm` equal to `claude` (or `pgrep -x claude` as fallback), `cwd` from `/proc/<pid>/cwd`. The session is the newest `.jsonl` in the project directory matching that `cwd`; `last_prompt` is the most recent `user` line's text. Linux only; on other systems the tool returns an error result saying so.

### `MCP::Hub::Native::Status`

| Tool | Arguments | Result |
|---|---|---|
| `hub_status` | — | the same structure as `GET /_hub/status` |
| `hub_refresh` | `name?` | new tool counts; requires `admin` in clients mode, otherwise an error result |

`rss_kb` comes from `/proc/<pid>/status` (`VmRSS`) where available.

## CLI (`bin/mcp-hub`)

Mojolicious commands; `--config` and `MCP_HUB_CONFIG` apply to all of them.

| Command | Behaviour |
|---|---|
| `daemon` | Runs the hub in the foreground. `--log-level` / `MOJO_LOG_LEVEL` as usual. |
| `config [--client NAME] [--all] [--url BASE]` | Prints `{"mcpServers": {…}}`. In clients mode `--client` is required and adds `"headers": {"Authorization": "Bearer …"}`; in open mode it is omitted. Default: one `{"type": "http", "url": "<base>/<name>"}` entry per server the profile allows, keyed by the server name. `--all`: a single entry `hub` pointing at `<base>/all`. `--url` overrides the base (default derived from `listen`). `--client` in open mode is ignored with a warning. |
| `status` | Calls `GET /_hub/status` and prints a table. Reports "not running" on connection refused. |
| `refresh [NAME]` | Calls `POST /_hub/refresh`. |
| `token` | Prints 32 random bytes as base64url — to paste into `clients`. Never touches the config file. |

`status` and `refresh` use the token of the first client whose profile has `admin: true` when in clients mode; `--client` selects another.

## Error handling

| Situation | Agent sees | Hub does |
|---|---|---|
| Unknown path / server not in profile | 404 | — |
| Missing or wrong token (clients mode) | 401 + `WWW-Authenticate: Bearer` | log at `info` |
| Upstream still fetching its first manifest, or `failed` | 503 `{"error": …}` | — |
| Tool denied by profile | "Tool not found" (`-32602`, as for any unknown tool) | — |
| Upstream returns JSON-RPC error | error result: `upstream <name>: <message>` | count in `errors` |
| Upstream timeout | error result: `upstream <name>: timed out after <n>s` | `notifications/cancelled`, count |
| Upstream crashes mid-call | error result: `upstream <name>: exited (<signal or code>)` | `stopped`, restart on next call |
| Upstream cannot start (exec fails, handshake error) | error result / 503 | log at `error`, `failed` after 3 quick exits |
| Config invalid | daemon refuses to start with the message and the JSON path (`mcpServers.playwright.hub.idle_timeout`) | — |

Secrets stay out of the log: `env` values are never logged and tokens are never echoed; the `config` command is the one place that prints a token, by design.

## Logging

`Mojo::Log` to STDERR. `info`: start/stop of upstreams with pid, manifest fetches, auth failures. `debug`: every forwarded request (name, tool, duration), child stderr. `MCP_DEBUG=1` from `MCP` still dumps raw messages on the agent side.

## Testing

- `t/upstream/echo.pl`: a Perl stdio `MCP::Server` (speaks legacy through `MCP::Server::Legacy`) with tools `echo`, `sleep` (async, seconds argument), `fail` (error result), `die` (internal error), `exit` (terminates the process), `notify` (writes a `notifications/tools/list_changed` line to STDOUT so the hub's refresh path can be exercised), one prompt and one resource. This is the only upstream the test suite spawns; no node or network.
- `t/config.t`: defaults, mode derivation, `${VAR}` expansion including `:-` defaults and the unset error, reserved names, `url` rejection, unknown keys, JSON path in messages.
- `t/manifest.t`: round-trip, hash change detection, atomic write.
- `t/auth.t`: token → profile, 401/404 decisions, `servers` wildcard, `tools` allow/deny composition.
- `t/facade.t`: build from a manifest with a mock upstream returning canned promises; result pass-through; error mapping; `validate_input` disabled; `tools/list` rendering keeps `title`, `icons` and `_meta` from the manifest.
- `t/stdio.t`: against `echo.pl` — handshake, pagination, timeout with `sleep`, crash with `exit` and restart, `failed` after repeated exits, idle stop with `idle_timeout: 1`, `list_changed` refresh, stderr capture.
- `t/hub.t`: `Test::Mojo` on `MCP::Hub` with a temp config and cache dir, driven by `MCP::Client`: lazy start (no pid before the first call), `tools/list` from cache without a process, per-server endpoints, `/all` prefixes, 404 outside profile, 503 while fetching, admin API, `config` command output.
- `t/native/claude-history.t`, `t/native/claude-sessions.t`, `t/native/status.t`: against fixtures under `t/fixtures/claude/projects/` (two projects, three sessions, string and block content, an `ai-title` line); sessions test uses a fake `/proc` layout via an overridable root.

## Dependencies

Perl 5.20+ (signatures, as `MCP` uses them). `Mojolicious` ≥ 9.x, `MCP` ≥ 0.15, `CryptX` (via `MCP`, used for `slow_eq` and random tokens), core modules for everything else. Test: `Test::Mojo` (ships with Mojolicious). No process-management or YAML dependencies.

## Distribution

Dist `MCP-Hub`, main module `MCP::Hub`, repository `p5-mcp-hub`, `[@Author::GETTY]` Dist::Zilla conventions (`dist.ini`, `cpanfile`, `Changes`, `README.md`, `# ABSTRACT:` on every module, `# PODNAME:` on `bin/mcp-hub`).
