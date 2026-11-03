# Docker upstreams — Design

**Status:** Draft, written by the coordinating agent on 2026-11-03. The maintainer
asked for the feature and said "design it, I'll tune it later" — every decision
below that is not a direct quote of the request is the agent's call, and the
maintainer may overturn any of them.

## Intent

An MCP server that ships as a Docker image should be as easy to mount as an
`npx` one: **name the image, and the hub does the rest** — pull it, start the
container, wire up its port, talk to it, stop it again when idle. Nobody writes a
`docker run …` line by hand or runs the container separately and points a `url`
at it. In the maintainer's words: "dass man nicht irgendwie anders das Docker
managen muss, sondern das sehr gut konfigurieren kann … einfach Docker-Image-Name
geht, und dann wird gestartet, so dass es angebunden werden kann, mit Port usw."

For servers that need several containers (a compose project), the maintainer
suggested "eine Ziel-Directory, wenn es Docker Compose sein muss". **Agent's
reading:** the entry names the directory that holds the compose project, and the
hub runs it there. (Alternative reading, not chosen: a directory the hub writes a
generated compose file into.)

## Goals

1. **Image name is enough.** `{"docker": "mcp/fetch"}` is a complete entry.
2. **Both kinds of container server work:** stdio ones (the common case — most
   images on Docker Hub's `mcp/` namespace, `ghcr.io/github/github-mcp-server`)
   and HTTP ones that listen on a port (crawl4ai and friends).
3. **Same promises as stdio:** lazy start (a cached manifest serves `tools/list`
   with no container running), idle stop, `always_on`, crash-loop → `failed`,
   `refresh` to come back, live reload that only rebuilds what changed.
4. **Secrets stay off command lines.** `env` values never appear in an argv.
5. **Works when the hub itself runs in its Docker image** (sibling containers
   via the mounted socket), and with Podman.

## Non-goals

- Building images. (A compose file may still `build:` — that is compose's business.)
- Updating images automatically. An image is pulled when it is missing; to move a
  tag such as `:latest`, `docker pull` it — the next container start uses it.
  *(Candidate for later tuning: a `pull: "always"` knob.)*
- A fixed host port. The hub lets Docker pick one; nothing else needs to know it.
- Managing a compose project beyond `up -d` / `stop` (no `down`, no volume removal).
- Per-client containers (same non-goal as for every other upstream).

## Anti-goals

- A hub that **removes or stops containers it did not start** — another hub's,
  the user's own. Cleanup only ever touches containers carrying this hub's label.
- A large image pull that **times out the handshake** and leaves the server
  `failed` on first use.
- A **blocking** `docker` call inside the event loop: the hub is one process, one
  `Mojo::IOLoop`.

## Configuration

Exactly one of `command`, `class`, `url`, `docker` or `compose` per entry
(`compose` additionally *requires* `url`, see below). Unknown or misplaced keys
are an error with their JSON path, as everywhere else.

### `docker` without `port` — a stdio container

```json
"github": {
  "docker": "ghcr.io/github/github-mcp-server",
  "args":   ["stdio"],
  "env":    { "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}" }
}
```

The hub spawns, as an ordinary stdio child:

    docker run -i --rm --name mcp-hub-github \
      --label mcp-hub.server=github --label mcp-hub.owner=<owner-id> \
      -e GITHUB_PERSONAL_ACCESS_TOKEN \
      [-v VOLUME …] [DOCKER_ARGS …] \
      ghcr.io/github/github-mcp-server stdio

Each `env` key becomes a bare `-e KEY`; the value is put into the environment
of the `docker` CLI process only (the same merge `Upstream::Stdio` already does),
so the CLI forwards it and no secret is visible in `ps`.

### `docker` with `port` — an HTTP container

```json
"crawl4ai": {
  "docker": "unclecode/crawl4ai:latest",
  "port":   11235,
  "path":   "/mcp/sse",
  "type":   "sse"
}
```

The hub runs `docker run -d --rm --name mcp-hub-crawl4ai <labels> <-e …> -p
127.0.0.1::11235 … IMAGE ARGS`, asks `docker port mcp-hub-crawl4ai 11235/tcp`
for the host address Docker picked, and from then on speaks to
`http://127.0.0.1:<host-port><path>` exactly like a `url` upstream: `type` is
`http` (default) or `sse`, `headers` are allowed.

`path` defaults to `/mcp`.

**Readiness.** A published port accepts TCP connections before the server inside
is listening (the Docker proxy owns it), so "port open" proves nothing. The hub
retries the MCP handshake — a refused or reset connection is retried every half
second or so — until `request_timeout` runs out. If the container exits in the
meantime the start fails at once, and the error carries the last lines of
`docker logs`.

### `compose` — a compose project directory

```json
"stack": {
  "compose": "~/mcp/stack",
  "url":     "http://127.0.0.1:8931/mcp"
}
```

`compose` names the directory that holds the compose file. Start:
`docker compose up -d` with that directory as working directory, then readiness
and HTTP exactly as above, against `url`. Idle stop: `docker compose stop`. The
stack publishes its own ports, so `url` is required and the hub does not rewrite
anything in the compose file. `type` and `headers` work as with `url`. `env` is
put into the environment of the `docker compose` process, so `${VAR}`
interpolation inside the compose file sees it. `~` is expanded; a relative path is
taken as-is, like `cwd` (agent's call: consistency with `cwd`).

### Keys at a glance

| Key | With | Meaning |
|---|---|---|
| `docker` | — | Image reference. |
| `args` | `docker` | Container arguments, after the image. |
| `env` | `docker`, `compose` | See above; never in an argv. |
| `port` | `docker` | Container port the server listens on; switches to HTTP. Integer 1–65535. |
| `path` | `docker` + `port` | URL path, default `/mcp`. Must start with `/`. |
| `type`, `headers` | `docker` + `port`, `compose` | As with `url`. |
| `volumes` | `docker` | List of `-v` specs (`/host:/container[:ro]` or `name:/container`). `${VAR}` and a leading `~` in the host part are expanded. |
| `docker_args` | `docker` | Extra `docker run` flags, inserted before the image (`--memory 512m`, `--gpus all`, `--user 1000`, …). |
| `compose` | — | Compose project directory. Requires `url`. |
| `hub.idle_timeout`, `hub.always_on`, `hub.request_timeout` | all | Exactly as for stdio; idle stop stops the container. |

`cwd` is refused with `docker` and `compose` (it has no meaning there).
`${VAR}` / `${VAR:-default}` are expanded in `docker`, `args`, `env` values,
`volumes`, `docker_args`, `compose`, `url` and `headers`.

### `hub` block — two new keys

| Key | Default | Meaning |
|---|---|---|
| `docker_command` | `docker` | The CLI to call. `podman` works. Also how the test suite substitutes a fake CLI. |
| `docker_network` | unset | When set, HTTP containers join this network instead of publishing a port, and the hub reaches them as `http://mcp-hub-<name>:<port><path>`. Needed when the hub itself runs in a container: a sibling's port published on the host's `127.0.0.1` is not reachable from inside the hub's container. |

Both can be changed by a reload; a change rebuilds the Docker upstreams.

## Lifecycle

- **Image.** Before the first start: `docker image inspect IMAGE`; missing →
  `docker pull IMAGE`, logged at `info` ("pulling IMAGE"), with no timeout of its
  own. The pull happens before the handshake, so the handshake's
  `request_timeout` never includes download time. Compose: `docker compose up`
  pulls what it needs itself; the handshake/readiness clock starts after `up`
  returns.
- **Names and ownership.** Container name `mcp-hub-<name>`. Every container the
  hub starts carries `mcp-hub.server=<name>` and `mcp-hub.owner=<owner-id>`,
  where the owner id is a short stable hash identifying this hub instance (agent's
  suggestion: of its `cache_dir`). Before a start, leftovers **with this hub's
  owner label** for that server are removed (`docker rm -f`) — a crashed hub's
  orphan. A container with that name that is *not* ours is left alone; `docker
  run` then fails with Docker's own "name already in use", and that message is
  the start error.
- **Stop** (idle, reload removal/change, daemon shutdown):
  - stdio container: the normal stdio stop (close stdin, `TERM`, `KILL` after
    the grace), then a `docker rm -f` by owner label in case the `KILL` orphaned
    the container.
  - HTTP container: `docker stop -t 5 mcp-hub-<name>` (`--rm` removes it).
  - compose: `docker compose stop`.
- **Warming.** At daemon start without a cached manifest, a Docker upstream is
  fetched once and stopped again, as a stdio upstream is (today `_warm_upstream`
  stops only `type eq 'stdio'` — it must cover these types too).
- **Crash loop.** The existing rule: three failed starts / unexpected exits within
  the fail window → `failed`, sticky until `refresh`.
- **Never blocking.** Every `docker` invocation runs as a child process watched by
  the IOLoop (the fork/exec pattern of `Upstream::Stdio`, or
  `Mojo::IOLoop->subprocess`), never `system` or backticks in the loop.

## Manifest hash

Never over `env`, as always.

- `docker`: over image, `args`, `port`, `path`, `type`, `volumes`, `docker_args`.
- `compose`: over the directory, `url`, `type`.

## Status and setup page

`type` is `docker` or `compose`. The status row additionally names the container
(or the compose directory). `pid` / `rss_kb` would describe the `docker` CLI, not
the server, so they stay `undef` for these types (agent's call: no number beats a
misleading one; `docker stats` is too slow to call per status request).

## Errors — every one names the fix

| Situation | Message carries |
|---|---|
| CLI missing (exec fails, 127) | "`docker` not found — install the Docker CLI, set `hub.docker_command`, or mount `/var/run/docker.sock` into the hub container" |
| Daemon unreachable / permission denied | Docker's own stderr |
| Pull fails | "cannot pull IMAGE: <stderr>" |
| Container exits during start | its exit, plus the tail of `docker logs` |
| Readiness runs out | "no MCP answer from <url> within Ns" |

## The hub's own Docker image

- Add the **compose plugin** (pinned `ARG`, next to `DOCKER_CLI_VERSION`), so
  `compose` entries work inside the image.
- `docker-compose.yml`: give the default network a fixed name (`mcp-hub`) and
  document `"hub": {"docker_network": "mcp-hub"}` next to the commented socket
  mount.
- Document the socket gotcha: with the socket mounted, **host paths are host
  paths** — `volumes` and the bind mounts of a compose project are resolved by the
  host's daemon. Mount a compose directory into the hub container **at the same
  path** it has on the host.

## Tests

No test talks to a real Docker daemon or the network.

- A fake CLI (a small Perl script under `t/upstream/`), selected with
  `hub.docker_command`, records every invocation (argv and the environment keys
  it was given) and emulates `image inspect` (present/missing), `pull`,
  `ps`/`rm -f` by label, `run -i` (execs `t/upstream/echo.pl`), `run -d` (starts
  a small HTTP MCP server on a free port), `port`, `stop`, `logs`,
  `compose up -d` / `compose stop`.
- Cover: config validation with JSON paths; the argv shape (bare `-e KEY`, no
  secret value anywhere in an argv); lazy start (cached manifest → the CLI is not
  called at daemon start); idle stop calls the right stop; pull only when
  missing; orphan cleanup only by owner label; `docker_network` skips `-p` and
  addresses the container by name; manifest hash ignores `env`; reload rebuilds a
  changed Docker entry and leaves an unchanged one alone; `docker_command`
  honoured.

## Left to the builder

Module layout (suggestion: thin subclasses — a stdio-container upstream on top of
`Upstream::Stdio`, an HTTP-container and a compose upstream on top of
`Upstream::Http`, plus one small helper for "run a `docker` command without
blocking"), how the normalized entry records transport vs. kind, the exact owner
id, retry interval, and how many log lines go into an error.
