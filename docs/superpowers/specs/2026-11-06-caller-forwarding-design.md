# Caller forwarding — Design

**Status:** Draft, written for k45 by mcp-hub-worker on 2026-11-06. It comes from the
k29 research (step 2/3 of the shared mcp-wiki store). Nothing here is decided. Every
choice that does not quote the card is Claude's call. Those calls are listed under
**Calls made by Claude, not by the maintainer** at the end, and the open questions are
under **Decisions for the maintainer**.

The MCP 0.15 behaviour below was checked with two small prototypes in a session
scratchpad, outside the repo. One was a plain `MCP::Server` over stdio with a
`handle` override. The other was an in-process server behind a Mojolicious `under`,
driven by `Test::Mojo`. Setup: perl 5.40.1, Mojolicious 9.49, MCP 0.15.

## Intent

A wiki shared through the hub should record which client wrote each change. Today
every mcp-wiki commit has the same author and committer:
`Git::Raw::Signature->default($repo)` (the repo's `user.name`/`user.email`), or
`MCP::Wiki <mcp-wiki@localhost>` when no identity is set
(`MCP::Wiki::Git::History::_signature`).

In clients mode the hub knows who is calling. `Auth::authenticate` matches the bearer
token in constant time and stashes the client name as `mcp.client`. But it forwards
only the tool name and the arguments: `Facade::_tool` calls
`$upstream->call_tool($name, $args)`, which sends `{name, arguments}`. The
upstream cannot tell its callers apart.

## Goals

1. **The upstream learns the caller on every call**, from the hub and from nobody
   else. It is the client name from `hub.clients`, not a self-reported label.
2. **One way of passing it for every upstream type**: stdio, http/sse, fork, docker
   and compose. An in-process class gets the same value through the API MCP 0.15
   already has.
3. **No client can claim to be another**, whatever it puts in its own request.
4. **mcp-wiki records it**, and when no caller is given its commits stay exactly as
   they are today.

## Non-goals

- **Per-client upstream instances.** These are already a v1 non-goal in the main
  spec. Every caller shares one child, worker or container.
- **End-user identity beyond the hub's clients.** A client is a token, so whoever
  holds the token is that client. The hub does not know which human or session is
  behind it.
- **Forwarding the agent's own `_meta`**, such as `progressToken` passthrough. Today
  none of it reaches an upstream, and this design keeps it that way.
- **A modern-only (2026-07-28) upstream.** The hub speaks the legacy protocol to
  every upstream (`initialize` with `2025-06-18`).

## Anti-goals

- **An identity taken from anything the agent sends**: `_meta`, `arguments`, a
  header, `clientInfo`, or a commit `reason`.
- **An identity in a child's `env`.** It would stick to whoever caused the lazy
  start.
- **A client name sent to a remote upstream that nobody asked to receive it.**
- **A new spawn, a changed manifest hash, or a dropped `extra`** for this feature.

## The options

**A — `_meta` on the request (recommended).** The hub adds one key to `params._meta`
of `tools/call`, `prompts/get` and `resources/read`:

```json
{"jsonrpc": "2.0", "id": 7, "method": "tools/call",
 "params": {"name": "update_paragraph", "arguments": {"page": "…"},
            "_meta": {"mcp-hub/client": "laptop"}}}
```

The spec allows this. `_meta` is "reserved by MCP to allow clients and servers to
attach additional metadata", and request params may carry keys beyond
`progressToken`. A key is an optional prefix (dot-separated labels, then `/`) plus
a name. A prefix is reserved only when one of its labels is exactly `mcp` or
`modelcontextprotocol` and another label follows it. `mcp-hub/` is a single label,
so it is not reserved.

The value travels with each request, so one shared child can serve many callers.
Every wire type goes through the same `Upstream::call_tool` → `_request_p`
(Stdio, Http, Fork, and Docker/Compose through their engines), so the change is
made in one place.

The cost is on the receiving side. MCP 0.15 gives a tool handler none of the
request's `_meta`. `MCP::Server::Context` carries only fields it has parsed out
(`principal`, `scopes`, `client_info`, `progress_token`, `controller`), and on the
legacy path `legacy_context` reads `progressToken` and nothing else. A Perl upstream
has to override `MCP::Server::handle` to read the key (see **mcp-wiki**). The
prototype confirms that this works and that a request without the key gets
`undef`.

**B — an env var per worker.** This does not work. A stdio child, fork worker or
container is started lazily by whichever call comes first and then serves every
caller until it goes idle. An identity in its `env` would be that first caller's,
and every later write would be pinned on it. That is worse than no attribution.
Getting it right would take one child per client, which is the per-client non-goal
and multiplies RAM, the opposite of the hub's purpose. Env also cannot reach an http
upstream, and a class entry refuses `env` altogether. The static case (one identity
for everything written through the hub) already exists: it is the wiki repo's
`git config user.name`.

**C — nothing.** This is right for open mode and for tokenless callers (see **Open
mode**). As the only answer it leaves the card unsolved.

**Also considered.** An HTTP header works for http upstreams only, and stdio has no
headers. An `arguments` field would change the tool's input schema, show up to the
model, and be exactly what an agent controls. The http `Mcp-Session-Id` cannot help
either: the hub sends every caller over one upstream session.

## Mechanism (option A)

### Where the hub gets the caller

There is one source: the `mcp.client` that `Auth::authenticate` stashes after a token
match. Nothing else is consulted. `Auth::authenticate` also stashes
`mcp.auth => {principal => $client}` (with `principal => undef` in open mode and for
`public_profile`). `MCP::Server::Transport::HTTP` copies that into
`Context->principal` for every request on every transport the hub builds: each
upstream's `action`, and the `/all` aggregate. The prototype confirms the copy.

From there:

- **Façade tools, prompts and resources** (`Facade::_tool`/`_prompt`/`_resource`) pass
  `$primitive->context->principal` to `call_tool`/`get_prompt`/`read_resource` as a
  third argument.
- **`Upstream::call_tool`, `get_prompt` and `read_resource`** add
  `_meta => {'mcp-hub/client' => $caller}` to the params when the entry has
  `forward_client` and the caller is defined. Otherwise the params stay exactly as
  they are today.
- **`/all`** needs nothing extra. `Aggregate::_wrap_tool` already calls
  `$tool->call($args, $wrapper->context)`, so the inner façade tool sees the
  aggregate's context and its principal.

### Per upstream type

| Type | Carried as | The upstream reads it from | Trust boundary |
|---|---|---|---|
| `stdio` | `params._meta` on the JSON-RPC line on its stdin | its MCP library's request `_meta` | stdin's only writer is the hub |
| `fork` | the same, since the worker runs `to_stdio` | the same | the worker is a copy of the hub: hub-trusted code |
| `http` / `sse` | `_meta` in the POST body | the same | the network: the upstream must authenticate the hub (a bearer in `headers`) before it trusts the key |
| `docker` (stdio mode), `compose run -T` | container stdin through the docker CLI, bytes unchanged | the same | as stdio |
| `docker` / `compose` (HTTP mode) | POST body to the published port | the same | as http, and a published port can be reached by other local processes |
| `perl` (in-process class) | no wire | `$tool->context->principal` (MCP 0.15 API, no hub coupling) | same process |
| natives | `principal`, unused today | the same | same process |

### Open mode and tokenless callers

In open mode there are no tokens, so the hub knows nobody. It forwards nothing: the
key is absent and `principal` is `undef`. A `public_profile` caller in clients mode is
treated the same way. Nothing better is available without trust. The legacy
`clientInfo` is not kept per request by MCP 0.15 (`legacy_context` sets it to `{}`),
and any header or label the agent sends is self-reported. Writing a self-reported
name as "who wrote" is exactly the injection that **Trust** rules out.

So the key means "a token-authenticated client made this call", and nothing weaker.
Anyone who wants attribution sets up `clients`. The mode is already derived, so no new
switch is needed.

### Configuration

There is one per-entry key, in the entry's `hub` block, which keeps it
JSON-expressible:

```json
"wiki": {"class": "MCP::Wiki::Server", "args": {"wiki_root": "/home/u/wiki", "use_git": 1},
         "hub": {"fork": true, "forward_client": true}}
```

- It is a boolean and **off by default**. Turning it on tells that upstream the client
  names. For a remote http upstream that is a disclosure to a third party, which is why
  it is opt-in.
- It applies to `command`, `url`, `docker`, `compose` and `class` with `fork`.
  On an in-process `class` it is a config error with its JSON path, the same rule
  `idle_timeout`/`request_timeout`/`always_on` follow there. An in-process class
  always gets `principal`: it shares the hub's memory, so there is nothing to
  disclose, and `/all` mixes upstreams in one request, so it could not be switched
  per entry anyway.
- It is not part of the manifest hash, because it does not change the tool list. A
  reload that changes only this key is applied in place, like the timeouts, because
  the value is read on every call.

## Trust

1. **Only the hub writes it.** The hub builds the upstream params from scratch, and
   today none of the agent's `_meta` gets through. If a later change forwards some of
   it, the hub must delete `mcp-hub/client` and then set it from the stash, with its
   own write coming last. A test pins this: an agent that sends
   `_meta: {"mcp-hub/client": "admin"}` leaves the upstream seeing the real client,
   or no key at all.
2. **In-process, the agent's `_meta` never becomes the principal.** MCP 0.15 never
   copies request `_meta` into `principal`, and the prototype confirms it. The
   principal comes only from `mcp.auth`, which the hub sets after the token check.
3. **The receiving side trusts the key only over stdio.** On stdio the only peer is
   the parent: the hub, or whoever spawned the server directly. An upstream must not
   trust the key over HTTP unless it has authenticated the hub. It must never let the
   key overwrite a `principal` that is already set (see **mcp-wiki**).
4. **An upstream cannot spoof it.** The identity flows one way, from the hub to the
   upstream, per request. The hub reads no identity from results, notifications or
   server-initiated requests (it terminates those anyway), and no upstream can reach
   another through the hub. This separation is real only for exec'd and remote
   upstreams. In-process classes and forked workers are hub-trusted code, and a fork
   worker already holds a copy of the hub's memory, every client token included. That
   is true today and is not changed here.
5. **Per request, never per process.** The hub pipelines several callers' requests
   into one child, and each request carries its own key. An upstream must not keep a
   "current caller" across requests. MCP 0.15 builds a fresh `Context` per request,
   so `principal` is safe.
6. **The value is a label, not a format.** Client names are arbitrary JSON object keys
   (`Config::_parse_client` does not restrict them). A consumer sanitises the value
   before writing it anywhere, for example by dropping control characters, `<` and
   `>` and capping its length.

## mcp-wiki — what it would do

This is for the matching p5-mcp-wiki card. No edit is made here.

**Reading.** `_build_server` would return a small `MCP::Server` subclass whose
`handle` does the following on the stdio transport (`!$context->controller`), and
only when `principal` is not already set: it copies
`params._meta.{"mcp-hub/client"}` into `$context->principal`.

The prototype ran exactly this. As a stdio child or fork worker, the wiki then
sees the hub's client. In-process in the hub, the hub has already set `principal`.
Over HTTP, an agent-sent key is ignored. The `_add_tool` wrapper reads
`$tool->context->principal` once and puts it into the change event as `client`, so
`on_change` handlers see it too. An embedder who passes in a plain `MCP::Server`
(option (a), p5-mcp-wiki k65) gets `principal` and no `_meta` reading.

**Recording — trailer (recommended) or author.**

| | Trailer: `Hub-Client: laptop` | Author `laptop`, committer = repo identity |
|---|---|---|
| `git log` / `blame` show the client | only with `--format='%(trailers:key=Hub-Client)'` | directly |
| `get_section_history` | needs a new `client` field, parsed from the trailer | the existing `author` field already shows it |
| Email | none needed | has to be invented (`laptop@…`), since the hub knows none |
| Matches this house's practice | yes: agents go in trailers, the human stays the author | no |
| Spoofing through `reason` | real: `reason` is the whole commit message, so an agent can write its own `Hub-Client:` line. The key has to be stripped from `reason`. | none, since the author is a header field |

**Fallback.** With no caller (open mode, tokenless, `forward_client` off, standalone
mcp-wiki) there is no trailer and the author is unchanged, so commits are
byte-identical to today's.

## The hazards it touches

- **The façade must not drop `extra`.** The change edits the code closures in
  `Facade::_tool`/`_prompt`/`_resource`, the lines next to `extra => _extra($t)`.
  Two different `_meta` are involved:
  - the **tool-definition** `_meta`, which rides on `Facade::Tool->extra` and is
    re-merged into `tools/list` by `Facade::Server`;
  - the **request** `_meta` that this design adds to `tools/call`.

  Neither may be routed through the other, and the tests assert that `tools/list`
  still renders the manifest's `_meta`. k30 (`/all` drops extras) is still open and
  is not touched here: the caller reaches `/all` through the context, not through
  `extra`.
- **The manifest hash never covers `env`.** The identity is per call. It is never
  in `env`, a manifest or a hash, and `forward_client` is not hashed either. That is
  one reason option B is rejected.
- **Lazy start.** Only the call path changes. `tools/list` is untouched, and nothing
  spawns because of this.
- **Config stays JSON-expressible.** One entry key with a JSON-path error, and no
  CLI flag.
- **404/401/503** are unchanged. Forwarding happens after the auth and route checks.

## Tests

None of these needs node, the network or a real `~/.claude`.

- Extend `t/lib/EchoServer.pm` (served by `t/upstream/echo.pl` and forked by
  `t/fork.t`) with the `handle` override and a `whoami` tool that returns its
  `principal`. This proves the technique mcp-wiki will use.
- **Clients mode.** Token A sees `A` and token B sees `B`. Tokenless with
  `public_profile` sees no key, and so does open mode. With `forward_client` off,
  no key is sent: assert on the raw line the child receives.
- **Spoofing.** An agent `_meta` holding the key is not forwarded, and an agent
  `arguments.client` is ignored.
- **Paths.** The same assertions on `/all`, on a fork upstream, on an in-process
  `class` (via `principal`) and on an http upstream (the key in the POST body).
- **Hazards.** `tools/list` still carries the tool-definition `_meta`. Toggling
  `forward_client` does not change the manifest hash. A reload that changes only
  `forward_client` keeps the same object and pid. `tools/list` spawns nothing.
- **Config.** `forward_client` on an in-process `class` is an error that names
  `mcpServers.NAME.hub.forward_client`.

## Recommendation

Use option A. In clients mode the hub adds `_meta: {"mcp-hub/client": <client>}` to
`tools/call`, `prompts/get` and `resources/read`, for entries with
`"hub": {"forward_client": true}`. In-process classes get the same value as
`Context->principal`. Open mode and tokenless callers forward nothing.

mcp-wiki maps the key to `principal` on stdio only, records it as a `Hub-Client:`
trailer, strips that key from the `reason`, and commits exactly as today when there
is no caller.

## Decisions for the maintainer

1. **The carrier.** Option A (`_meta`), as recommended, or another.
2. **The key.** `mcp-hub/client`, holding a bare string, or a reverse-DNS prefix you
   own. An object (`{"client": …}`) would leave room for later fields such as the
   profile.
3. **The default.** `forward_client` opt-in per entry (recommended), or on for every
   local type (stdio, fork, docker) and opt-in only for http.
4. **Open mode.** Forward nothing (recommended), or a self-reported label marked as
   untrusted.
5. **mcp-wiki: trailer or author.** If a trailer, which key (`Hub-Client` proposed).
   If the author, which email.
6. **Upstream MCP.** Whether to ask for request `_meta` on `MCP::Server::Context`,
   which would remove the `handle` override. That is a public tracker, so it is your
   call and nothing is filed.

## Follow-up cards (proposed — the dispatching agent files them)

- **p5-mcp-hub: implement caller forwarding** (mcp-hub-worker). Covers `Auth`,
  `Facade`, `Upstream`, `forward_client` in `Config` and its reload rule, POD, and the
  `mcp-hub-core`/`mcp-hub-runtime` skill text. It touches `Config.pm`, so it starts
  after k46 lands.
- **p5-mcp-hub: tests for it** (mcp-hub-test-writer), as listed in **Tests**.
- **p5-mcp-wiki: record the calling client.** The `handle` override (stdio only,
  never overwriting), `client` in the change event, the trailer or author per
  decision 5, stripping the key from `reason`, sanitising the value, and a `client`
  field in the history tools.

## Left to the builder

- Whether façade code passes the principal or the context.
- The exact `call_tool` signature, as long as calls without a caller keep today's
  params byte for byte.
- Where `mcp.auth` is stashed.
- The value sanitising on the wiki side.

## Calls made by Claude, not by the maintainer

- **`mcp.auth` stash, not the transport's `auth` callback.** The callback is the
  documented route. But with it set, MCP 0.15's `_scopes` turns `undef` into `[]`, so
  a tool that declares `scopes` is refused with `-32003` (the prototype confirms
  this). The stash key is read unconditionally in `_handle_request`, but it is not
  documented, so a test pins it. No hub or mcp-wiki tool declares scopes today.
- **`principal` is set for every authenticated request**, whatever `forward_client`
  says. One side effect: MCP 0.15 binds sealed `input_required` state to the
  principal, so one client can no longer replay another client's state. That is
  correct.
- **`prompts/get` and `resources/read` carry the key too.** It costs one helper, and
  mcp-wiki needs only `tools/call`.
- **The client name is forwarded verbatim.** The hub does not restrict or rename
  it; consumers sanitise.
- **The draft lives in `docs/superpowers/specs/`** next to its siblings, not in
  `docs/superpowers/` as the brief said: no draft lives there.
