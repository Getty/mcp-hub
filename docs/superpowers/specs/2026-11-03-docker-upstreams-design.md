# Docker upstreams — Design

**Status:** Draft, written by the coordinating agent on 2026-11-03. The maintainer
asked for the feature and said "design it, I'll tune it later" — every decision
below that is not a direct quote of the request is the agent's call, and the
maintainer may overturn any of them. Implemented in k21; where the text below and
the code disagree, the section **As built** at the end says how and why — and the
code wins.

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
(`url` may additionally accompany `compose`, see below). Unknown or misplaced keys
are an error with their JSON path, as everywhere else.

### stdio or HTTP — how the hub decides

Decided by the maintainer (2026-11-03, after the first draft):

1. `"port": N` given → HTTP on container port N.
2. No `port`, and the image declares **exactly one** `EXPOSE` port → HTTP on that
   port. (Read with `docker image inspect` after the image is present, i.e. at
   start, not at config load.)
3. No `port` and no `EXPOSE` → stdio: the hub talks to the container over its
   stdin/stdout.
4. `"stdio": true` forces stdio even when the image declares a port — for images
   that `EXPOSE` a port but run stdio by default (servers that speak both).

Errors: no `port` and **more than one** `EXPOSE` port → the start fails and names
the ports ("image X exposes 8080/tcp and 9090/tcp, set `port`").
`"stdio": true` together with `port`, `path`, `type` or `headers` → config error.
`path`/`type`/`headers` without `port` are allowed (they apply when the image's
`EXPOSE` makes it HTTP); if the image turns out to be stdio, the start fails and
says they need a port. When an HTTP container never answers within the readiness
window, the error suggests `"stdio": true` if the port came from `EXPOSE`.

The detected mode is not part of the manifest hash (it is a property of the
image, not of the entry); a pull that changes it simply applies on the next start.

### `docker` as stdio — a stdio container

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

### `docker` as HTTP — a container with a port

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

### `compose` — one service of a compose project

```json
"stack": { "compose": "~/mcp/stack", "service": "mcp" }
```

`compose` names the directory that holds the compose file (the maintainer's
"Ziel-Directory"); `service` names the **one** service that is the MCP server.
**`service` is always required** — a missing one is a config error — and the hub
uses only that service, never the whole stack (maintainer, 2026-11-03): the
directory may hold a larger stack the hub has no business starting or stopping.
The hub reads the project with `docker compose config --format json` (working
directory = the compose directory) — never parses YAML itself; a `service` that
is not in the project is a start error that lists the services there.

How the hub talks to the service — the same rule as for `docker`, in this order:

1. `url` given → HTTP to exactly that URL (a reverse proxy in front, say); the hub
   does not look at ports.
2. `port` given → HTTP; the host address comes from
   `docker compose port <service> <port>`. A port the service does not publish
   is an error that says to add it under `ports:` (or to give `url`).
3. Neither, and the service publishes **exactly one** port (`ports:` in the
   normalized config) → HTTP on that port, address via `docker compose port`.
   More than one → error naming them, "set `port`".
4. No published port → stdio: `docker compose run --rm -T <service>` as the stdio
   child.
5. `"stdio": true` forces 4.

HTTP start: `docker compose up -d <service>` — only that service; compose pulls or
builds what it needs and brings up what the service declares in `depends_on`,
because the service cannot run without it. Idle stop: `docker compose stop
<service>` — only that service. Its dependencies and every other service of the
stack are never stopped by the hub (they may serve other things in that stack).
stdio: the `run --rm` container goes away with the stdio stop; nothing else is
stopped. `type`, `path`
and `headers` work as for a `docker` HTTP container (`path` default `/mcp`,
ignored when `url` is given). `env` is put into the environment of the
`docker compose` process, so `${VAR}` interpolation inside the compose file sees
it. `~` is expanded; a relative path is taken as-is, like `cwd` (agent's call:
consistency with `cwd`). The stdio `run` gets `--name mcp-hub-<name>` and the
owner labels (`-l`), so orphan cleanup works as for `docker`; containers from
`up` belong to compose and are only ever stopped through compose.

### Keys at a glance

| Key | With | Meaning |
|---|---|---|
| `docker` | — | Image reference. |
| `args` | `docker` | Container arguments, after the image. |
| `env` | `docker`, `compose` | See above; never in an argv. |
| `port` | `docker`, `compose` | Container port the server listens on; switches to HTTP. Integer 1–65535. Optional when the image `EXPOSE`s (docker) / the service publishes (compose) exactly one port. |
| `stdio` | `docker`, `compose` | `true` forces stdio even when a port would be detected. |
| `path` | `docker`, `compose` (HTTP) | URL path, default `/mcp`. Must start with `/`. |
| `type`, `headers` | `docker`, `compose` (HTTP) | As with `url`. |
| `service` | `compose` | **Required.** The one service that is the MCP server; the hub starts and stops only it. |
| `url` | `compose` | Explicit address; skips port detection. |
| `volumes` | `docker` | List of `-v` specs (`/host:/container[:ro]` or `name:/container`). `${VAR}` and a leading `~` in the host part are expanded. |
| `docker_args` | `docker` | Extra `docker run` flags, inserted before the image (`--memory 512m`, `--gpus all`, `--user 1000`, …). |
| `compose` | — | Compose project directory. |
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
  - compose: `docker compose stop <service>` (HTTP) or the stdio stop of the
    `run --rm` container — never the rest of the stack.
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
- `compose`: over the directory, `service`, `url`, `port`, `path`, `type`, `stdio`.

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
  `compose config --format json` (several services, zero/one/two published
  ports), `compose up -d SERVICE`, `compose port`, `compose run --rm -T`
  (execs `echo.pl`), `compose stop SERVICE`. Its `image inspect` must be able to report
  zero, one or two `EXPOSE` ports so the mode decision can be tested.
- Cover: config validation with JSON paths; the argv shape (bare `-e KEY`, no
  secret value anywhere in an argv); lazy start (cached manifest → the CLI is not
  called at daemon start); idle stop calls the right stop; pull only when
  missing; the mode decision (explicit `port`, one `EXPOSE`, no `EXPOSE`, two
  `EXPOSE` → error, `stdio: true` overriding an `EXPOSE`, `stdio: true` + `port` →
  config error) and its compose twin (`url`, `port`, one published port, none →
  stdio via `run`, missing `service` → config error, unknown `service` → start
  error listing the services, idle stop names only the service);
  orphan cleanup only by owner label; `docker_network` skips `-p` and
  addresses the container by name; manifest hash ignores `env`; reload rebuilds a
  changed Docker entry and leaves an unchanged one alone; `docker_command`
  honoured.

## Left to the builder

Module layout (suggestion: thin subclasses — a stdio-container upstream on top of
`Upstream::Stdio`, an HTTP-container and a compose upstream on top of
`Upstream::Http`, plus one small helper for "run a `docker` command without
blocking"), how the normalized entry records transport vs. kind, the exact owner
id, retry interval, and how many log lines go into an error.

## As built (k21)

The builder's calls, and every place the code departs from the text above.

**Module layout.** The mode is decided at start (from `EXPOSE` or the published
ports), so one class per entry cannot be picked at config load. Instead:

- `MCP::Hub::Docker` — the CLI helper: non-blocking `run_p` (fork/exec, output
  through the IOLoop; the exit status from an `EV::child` watcher under
  `Mojo::Reactor::EV`, whose libev reaps every child itself, else polled with
  `WNOHANG`; `on_spawn` hands out a kill for a command the caller may give up
  on, such as a `docker wait`), naming, labels, `run` argv, hash input, owner
  id, `image_ports_p` (inspect, pull if missing, inspect), `image_exists_p`,
  orphan removal by label, messages.
- `MCP::Hub::Upstream::Docker` — the upstream the hub sees for a `docker` entry:
  state, crash-loop counter, idle timer, the per-start plan. For each start it
  creates one *engine* and forwards requests to it.
- `MCP::Hub::Upstream::Compose` — the same for one compose service (a subclass
  that overrides planning, launch, teardown and the hash).
- `MCP::Hub::Upstream::Docker::Stdio` / `::Http` — the engines: the unchanged
  `Upstream::Stdio` / `Upstream::Http` transports, mixed with
  `MCP::Hub::Upstream::Docker::Engine` (owner link, teardown, tools registered
  on the owner's façade). `Upstream::Stdio` and `Upstream::Http` are untouched.

**Normalized entry.** `type` is the kind (`docker`/`compose`); the HTTP flavour
a `type` key asked for is `transport` (undef when not given). `docker_command`
(and, for `docker`, `docker_network`) are copied into every container entry, so
a reload that changes them rebuilds exactly those servers.

**Departures from the text above:**

- *Owner id* — random, made once and kept in `<cache_dir>/docker-owner`, not a
  hash of `cache_dir`: two hubs in two containers both keep their cache at
  `/cache` and would share a hash. When the file cannot be written or read
  back, the start fails ("cannot keep a docker owner id in … -- docker and
  compose entries need a writable hub.cache_dir"): an id made up for the moment
  would leave containers no later clean-up recognises.
- *A third label*, `mcp-hub.run=<random>`, per start: the clean-up after one
  stdio container's CLI exits removes only that start's container, never the one
  that replaced it.
- *HTTP containers run without `--rm`* and are stopped with `docker stop -t 5
  <id>` then `docker rm -f <id>`: with `--rm` a container that dies while
  starting is gone before `docker logs` can say why. A `run -d` that printed no
  id (timed out, or created the container and then failed to start it) is
  cleaned up by its labels — this hub's owner, this server, this start's run —
  so nothing it may have created stays behind. The same label removal follows a
  stdio CLI that exits or is killed.
- *A stop during the start* wins, at whatever step it comes — the readiness
  wait and the MCP handshake are cut short, a docker command already running
  (a pull, say) is let finish: the start is rejected ("stopped while
  starting"), the container is torn down, the state ends `stopped`. The
  `docker wait` that watches a container is killed at teardown, so none
  outlives its container.
- *Leftover removal* inspects every container the label filter returns and
  removes it only when its labels match exactly.
- *Compose project name* is compose's own default (no `-p`), so the service
  joins the user's stack.
- *A compose service that already runs* (`compose ps --status running --status
  restarting --status paused -q SERVICE` names a container) is used as it is:
  no `up`, which could recreate it, and never a `stop`. When that `ps` fails,
  the start fails too — the hub starts, and later stops, only a service it saw
  not running. What starts the service between that `ps` and the `up` is beyond
  telling.
- *Nothing that exists is recreated.* The hub starts the service, plus any
  dependencies that are not running yet; it stops only that service; it never
  stops, recreates or restarts anything that already exists. Compose's default
  policy recreates a running service whose configuration has diverged — and
  `up SERVICE` applies it to the dependencies too — so the hub's HTTP start is
  `compose up -d --no-recreate SERVICE`, the stdio dependencies are started with
  `compose up -d --no-recreate DEPS`, and the stdio server with `compose run
  --no-deps`. A change to a service in the compose file therefore reaches an
  existing container only when the user recreates it.
- *Compose stdio is prepared first.* `compose run` would pull or build a missing
  image and start `depends_on` inside the handshake's `request_timeout`; the hub
  does both before `run`, without a timeout: `docker image inspect` on the
  service's image (`<project>-<service>` for a build-only service), `compose
  build|pull SERVICE` when it is missing, then `compose up -d --no-recreate` for
  the `depends_on` services (required ones, and optional ones the project has),
  which stay running afterwards as `compose run` leaves them. Then it polls
  `compose ps -a --format json DEPS` every 0.5 s until each `service_healthy`
  dependency is healthy and each `service_completed_successfully` one has exited
  0; one that exits non-zero, exits while it should be healthy, turns
  unhealthy or has no healthcheck fails the start. Not `up --wait`: it fails on
  a one-shot dependency (compose 5.x: "container … exited (0)", exit 1), and a
  stop cannot cut it short. Not `compose wait` either: it does not see a
  container that has already exited. A one-shot dependency runs again on every start, as
  compose runs it. No timeout — compose has none for `depends_on` either.
- *Docker Compose 2 or later.* podman-compose has no `config --format json` and
  is not supported; a compose that rejects a flag the hub uses fails the start
  with "the hub needs Docker Compose 2 or later (docker compose version);
  podman-compose is not supported".
- *Hash.* `docker` also hashes `stdio` (it changes how the server is spoken to).
  Neither kind hashes `env` or the docker command.
- *Config.* `port` + `url` (compose) and `url` + `"stdio": true` are config
  errors; `env` keys must be valid variable names (they become `-e KEY`). A
  JSON `true` is no integer: `"port": true` is refused (so are the `hub`
  timeouts). Nor is a YAML `true` or a string such as `"8080"`. `stdio` stays
  truthy, like `always_on`.
- *Messages.* A missing CLI says "install the Docker CLI or set
  hub.docker_command"; the socket hint goes with the error it belongs to — a
  daemon that cannot be reached ("… mount /var/run/docker.sock into it"). A
  foreign container holding the name gets "remove it if it is a leftover, or
  rename this server" after Docker's own message. A failed command's message
  carries its stderr only, never its stdout: `compose config` prints the
  project with every interpolated secret. A stdio CLI's stderr is read to the
  end before its exit is handled, even when the IOLoop sees the end of its
  stdout first.
- *Readiness* is a `POST {}` with the MCP `Accept` header every 0.5 s: any HTTP
  answer means the server listens; then the transport's own handshake runs.
  A container exit (watched with `docker wait`) ends the wait at once, with the
  last 10 lines of `docker logs`.
- *Shutdown.* `mcp-hub daemon` stops every upstream on its way out and waits (at
  most 20 s) until the containers are gone (`MCP::Hub::shutdown_p`). From the
  first moment of that wait the hub reloads nothing — no SIGHUP, no changed
  file — so no new upstream starts while the old ones go.
- *Status.* `TYPE` column widened for `compose`; the status row carries
  `container` (or `compose` and `service`) and the detected `mode`.

**Tests.** `t/docker.t` against `t/upstream/fake-docker.pl`, a fake CLI that
keeps its containers and images as JSON in a state directory, logs every call,
answers `ps` filters and `inspect --format` the way Docker does, models
compose's recreate policy (a running service whose definition changed is
recreated unless `--no-recreate`), `depends_on` conditions with healthchecks and
one-shot services, rejects any flag it does not know, and fails any command on
demand (`fail.json`); `t/upstream/echo.pl` gained `--http=PORT` for
the fake's HTTP containers. `t/docker-live.t` runs
`mcp/time` against a real daemon (`MCP_HUB_TEST_DOCKER=1` or `RELEASE_TESTING`).
