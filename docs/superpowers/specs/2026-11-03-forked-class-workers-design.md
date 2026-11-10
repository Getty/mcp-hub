# Forked class workers — Design

**Status:** Accepted 2026-11-04 (see **Decisions**) and implemented the same day for
k42 and k38; written for k37 by mcp-hub-worker on 2026-11-03. Where the build differs
from the draft, the section says so and **As built** at the end lists it. The
maintainer asked for this design after the k29 research pointed at
its option (c). Any decision that is not a quote of that request is Claude's call,
and each one is listed under **Calls made by Claude, not by the maintainer** at the
end.

This design bends a standing hazard: "one daemon process — never a prefork/hypnotoad
path". Whether that is acceptable is the maintainer's decision. **The decision for
the maintainer** puts that question, and nothing below assumes the answer.

The mechanism was prototyped in a scratchpad against a running hub. The numbers in
**Memory**, and the evidence column of **Fork safety**, come from that prototype.
Test setup: Linux 6.12, perl 5.40.1, Mojolicious 9.49, MCP 0.15, MCP::Wiki 0.002 and
Git::Raw 0.90.

## Intent

A Perl MCP server class that the hub can load (mcp-wiki first) should cost about as
little memory as an in-process class, but without stalling the hub the way an
in-process class does. The two existing options each fail one side:

- **In process**, `MCP::Wiki::Server`'s `get_section_history` walks the git history
  inside the hub's single IOLoop. Here that stalled the loop for 1.6–2.2 s per call.
  In k29, it held up an unrelated upstream for 5.1 s.
- **As a stdio child**, it costs a whole second perl: about 52 MB PSS while running,
  and 1.5–3.6 s to start.

The middle path has three parts:

1. The hub loads the class itself, so `tools/list` needs no process.
2. Calls run in a worker that the hub forks from itself, with no exec.
3. The hub talks to that worker with the stdio client it already has.

The worker is ready in about 30 ms because it shares its pages with the hub. It is
stopped when idle, like a stdio child, and a slow call blocks nobody but the worker
itself.

## Goals

1. **No process for listing.** `tools/list`, `prompts/list` and `resources/list` come
   from the class loaded in the hub, with no process and no disk cache.
2. **Calls run in a worker.** `tools/call`, `prompts/get` and `resources/read` run in
   a forked worker. A slow call stalls no other upstream and no HTTP client.
3. **Same lifecycle as stdio.** That means lazy start, idle stop, `always_on`, request
   timeout and cancel, crash loop → `failed`, `refresh`, a reload that rebuilds only
   what changed, and a shutdown that reaps.
4. **A worker holds nothing of the hub.** Not the port, not a client connection, not
   another upstream's pipe, no signal handler of the hub's and no END block.
5. **mcp-wiki works unchanged.** mcp-wiki 0.002, as released on CPAN, is mountable
   without changes.

## Non-goals

- **`env` and `cwd` for a forked class, in v1.** A class takes its configuration
  through `args`. The hub's in-process manifest is built without `env`/`cwd`, so
  adding them would let the façade and the worker disagree.
- **A class that drives its own event machinery** (EV or AnyEvent watchers, threads).
  The worker runs `to_stdio`, which is a blocking line loop. Promises are waited on
  with a fresh Mojo reactor.
- **Concurrency for one entry.** There is never more than one worker per entry, and
  no parallelism inside a worker. Calls queue, exactly as they do for a stdio child.
- **A zygote/fork server, or a subprocess per call.** See **Alternatives**.
- **Kernel-assisted death signalling** (`PR_SET_PDEATHSIG`). The worker ends when it
  reads EOF.
- **Windows** (no fork). **macOS and the BSDs are out of scope in v1**, because the fd
  rule below relies on Linux's `/proc/self/fd` semantics.
- **A manifest cache for forked classes.**

## Anti-goals

- **A worker that serves HTTP, holds the listening socket or runs the hub's loop.**
  The worker never returns from the fork into the hub's code.
- **A worker that keeps anything else the hub has open.** That covers client
  connections (a client would wait for EOF until the worker exits), other upstreams'
  sockets and pipes, and libev's epoll fd and eventfd.
- **A worker that inherits a hub signal handler** (Mojo's TERM handler, libev's
  SIGCHLD), or that reacts to the hub's `kill -HUP`.
- **A worker that runs the hub's END blocks or global destruction.**
- **A worker start that stalls the hub** for longer than the `fork` itself.

## The decision for the maintainer

**What the rule protects.** The rule "one daemon process — never a prefork/hypnotoad
path" (skill `mcp-hub-core`) protects three things: one IOLoop, one set of upstream
children, and one place where state lives. Prefork and hypnotoad break all three:

- N processes accept HTTP, and each runs the loop.
- Each spawns its own stdio children.
- Each keeps its own idea of which upstream is running.
- A reload happens per process.

A forked class worker is a different kind of process:

| | prefork / hypnotoad worker | forked class worker | stdio child (today) |
|---|---|---|---|
| Serves HTTP, holds the port | yes, every worker | no — the listening socket becomes `/dev/null` | no |
| Runs the hub's IOLoop | yes | no — the loop is frozen and never re-entered | no |
| Owns hub state (upstreams, manifests, auth) | a copy each, diverging | a dead copy, never run | no |
| Spawns upstream children | yes, duplicates | no | no |
| Lifecycle owned by | the prefork manager | the hub's `Upstream` object (spawn, idle stop, crash loop, reap) | the hub's `Upstream` object |
| Starts as | a copy of the hub | a copy of the hub | a freshly exec'd program |
| Inherits fds, signals, XS state | all of it | all of it — neutralised by a recipe | stdin/stdout/stderr only (exec resets the rest) |
| Shares memory with the hub | copy-on-write | copy-on-write | no |

**What actually bends.** The worker is a copy of the hub that never execs. It
contains everything the hub holds at the moment of the fork, and only the isolation
recipe in **Mechanism** makes that harmless.

The recipe covers everything the hub holds today; the prototype checked each item.
But it turns into a standing invariant: *anything the hub process holds must either
be harmless to inherit or be neutralised by the recipe.* A future change could break
workers without failing anything else, for example by adding:

- a thread,
- a C-level signal handler,
- an fd type the recipe does not know,
- an END block with side effects.

The isolation tests in **Tests** are what guard that invariant.

**Proposed wording** of the hazard, if the answer is yes. It would go in `CLAUDE.md`,
`.claude/rules/mcp-hub-rules.md`, `mcp-hub-core` and the "Process model" POD of
`MCP::Hub`:

> One process serves HTTP and owns all state — never a prefork/hypnotoad path. Its
> child processes are exec'd upstreams or forked class workers. A worker never runs the
> hub's loop, holds none of its fds or signal handlers, and ends with `_exit`.

**Question for the maintainer:** may the hub fork class workers without exec, under
that reworded rule?

- **Yes:** this design is implemented through the follow-up cards below.
- **No:** mcp-wiki stays a stdio upstream, as k29 recommends. That works today with
  the CPAN mcp-wiki: about 52 MB PSS while running, nothing when idle-stopped, and a
  1.5–3.6 s cold start. This draft is then kept as rejected.

## Configuration

```json
"wiki": {
  "class": "MCP::Wiki::Server",
  "args":  { "wiki_root": "/home/me/wiki", "use_git": true },
  "hub":   { "fork": true, "idle_timeout": 600 }
}
```

Setting `hub.fork` on a `class` entry makes it a forked class. The value is treated
as truthy, like `always_on`. The normalized entry is `type: 'fork'`, with `class` and
`class_args` exactly as for a `class` entry today.

| Key | Meaning |
|---|---|
| `class` | Class name, loaded in the hub at build. Either an `MCP::Server` subclass, **or** a class whose instances have a `server` method returning one (option (a), see **mcp-wiki**). |
| `args` | JSON object, passed to `new` in the hub and again in each worker. Not expanded: no `${VAR}` and no `~`, as for every `class` entry today, so write absolute paths. |
| `hub.fork` | `true` runs calls in a forked worker. |
| `hub.idle_timeout`, `hub.always_on`, `hub.request_timeout` | Exactly as for stdio, with defaults from the global `hub` block. |

**Config errors**, each with its JSON path:

- `hub.fork` on a `command`, `url`, `docker` or `compose` entry:
  `mcpServers.wiki.hub.fork: 'fork' only applies to a 'class' entry`.
- `env`, `cwd`, `headers` or `type` on any `class` entry, forked or not (k38):
  `mcpServers.wiki.env: 'env' does not apply to a forked 'class' entry, which takes
  its settings through 'args'` (the `, which …` part only for `env` and `cwd`; "a
  'class' entry" when it is not forked).
- `hub.idle_timeout`, `hub.request_timeout` or `hub.always_on` on a `class` entry
  without `hub.fork` (k38): `mcpServers.run.hub.idle_timeout: 'idle_timeout' does
  not apply to an in-process 'class' entry, only with "fork": true`.

**Build errors.** The entry becomes a failed placeholder, just as a class that fails
to load does today (`_broken_upstream`). It is listed, it reports the error, and a
reload retries it.

- The class is neither an `MCP::Server` nor has a `server` method:
  "X is neither an MCP::Server subclass nor has a `server` method returning one".
- The class has a `hub` attribute: "X needs the live hub (it has a `hub` attribute)
  and cannot run in a forked worker; drop `hub.fork`". `Native::Status` is the
  example: its tools read the hub's upstreams.
- Listing returns a promise: "X answered tools/list with a promise; a forked class
  must list synchronously". MCP::Server's own list methods are synchronous.
- `/proc/self/fd` is not there: "hub.fork needs Linux (the worker's fd isolation
  reads /proc/self/fd)".

**Start error.** A failed start counts toward the crash loop, as a failed stdio
start does:

- The hub runs more than one thread at fork time: "cannot fork a worker for X: the
  hub runs N threads". This is read from `/proc/self/status`.

## Mechanism

### In the hub, at build: the class and its manifest

1. **Load the class** with `Mojo::Loader::load_class`, as `Upstream::Perl` does.
2. **Build one throwaway instance** with `args`, and take its `MCP::Server` (the
   instance itself, or its `->server`).
3. **Read the manifest through the class's own JSON-RPC handler**, in process:
   `$server->handle($req, MCP::Server::Context->new(legacy => '2025-06-18'))`.
   - Send `initialize` and `tools/list`, plus `prompts/list` and `resources/list`
     when the capabilities announce them.
   - The worker answers with the same handler over stdio, so the façade shows
     exactly what the worker will serve.
   - Read `instructions` off the server object. MCP 0.15's legacy `initialize` does
     not include them (checked): not in process, and not from the worker either.
4. **Apply the manifest to the façade** (`MCP::Hub::Facade->apply`) and set
   `manifest_fetched_at`.
5. **Drop the instance.** The hub keeps the loaded modules (shared with every
   worker), the façade and the instructions, but not the object. So no repository
   handle and no open file of the class's sits in the hub when it forks.
   - *As built:* letting go is not enough. A tool closure that captures the
     instance — mcp-wiki's do, and so does any `$self->tool(code => sub { $self … })`
     — is a cycle through the server, and the instance would never be freed. The
     hub therefore empties the throwaway server's `tools`, `prompts` and
     `resources` before it lets go. A class whose instances share one server object
     (a class-level singleton) would lose its lists with that; none is known, and
     the POD names the throwaway instance.

**Cost:** 13–43 ms per entry, at daemon start and whenever a reload rebuilds the
entry (measured for mcp-wiki with its 15 tools; it covers construction plus the four
in-process requests). The memory cost is the class's modules: +5.9 MB USS for
mcp-wiki (see **Memory**), the same as a `class` entry costs today.

**No cache, no hash.** The manifest comes from code that is in memory anyway, so it
is exact and cheap to re-read; a disk cache could only be stale. If a cache is ever
added, it would hash `[class, $class->VERSION, args]`. Since `args` may hold secrets,
that is one more reason not to add one.

### The worker: forked on first use

**When it forks.** `tools/call`, `prompts/get` or `resources/read` calls `start_p`,
which forks where `Upstream::Stdio` would spawn. Nothing forks at daemon start, at
build or at reload. There is no warming, because the manifest is already there.

**In the hub (the parent):**

- Create a socketpair and a stderr pipe, as `Upstream::Stdio::_spawn` does, then
  `fork`.
- Close the child's ends, attach the parent's ends to `Mojo::IOLoop::Stream`s, and
  handshake through `_handshake_p`.
- Apply the manifest from the worker's handshake to the façade in memory only
  (nothing goes to disk), keeping the in-process `instructions`.

Measured timings:

- The `fork` stalls the hub for 2.3–5.7 ms at 71 MB RSS.
- The worker is ready in 21–35 ms (fork, construction, handshake).
- The first call takes 15–30 ms.

**In the worker (the child).** Everything runs inside one `eval` that ends in
`POSIX::_exit`, so the worker never returns into the IOLoop callback it was forked
from:

1. **Rename the process:** `$0 = "mcp-hub-worker NAME"`. `pidof mcp-hub` is the
   documented HUP target, and after the rename it no longer matches the worker.
2. **Reset signals the way `exec` would:**
   - every caught signal goes back to `DEFAULT`;
   - ignored ones stay ignored (perl ignores FPE, Mojo::IOLoop ignores PIPE);
   - `HUP` is ignored, because `pkill -HUP -f mcp-hub` still matches the worker's
     argv;
   - `__WARN__` and `__DIE__` are cleared, and so is the signal mask.

   Assigning to `%SIG` also replaces C-level handlers, such as libev's SIGCHLD
   handler.
3. **Freeze the hub's loop:** `Mojo::IOLoop->reset({freeze => 1})`.
   - The hub's loop, reactor, streams and timers stay referenced and dormant.
   - So `Mojo::IOLoop::Stream::DESTROY` never runs for them. It would call `close`,
     which fires the hub's close handlers inside the worker.
   - The worker's own `->wait` gets a fresh reactor. That is `Mojo::Reactor::Poll`,
     because `Mojo::Reactor::EV->new` hands out EV only once per process.
4. **Point the standard handles at the hub:** stdin and stdout go to the socket,
   stderr to the pipe.
5. **Neutralise every other fd:**
   - A regular file is reopened through `/proc/self/fd/N`, at the same position and
     with the same access and append flags. That gives the worker a new open file
     description, so it never moves the hub's offset. This matters for module `DATA`
     handles, a log file and a packed hub's own archive; it also keeps a deleted
     file working.
   - Anything else (sockets, pipes, epoll, eventfd, ttys) gets `/dev/null` dup2'ed
     over it.
   - This uses dup2 rather than close: a dormant inherited Perl handle may still
     close its fd number later, and that must not hit a fresh fd of the class.
6. **Reseed:** `srand()`. Otherwise every worker would repeat the hub's `rand`
   sequence.
7. **Guard `exit`:** `eval 'END { POSIX::_exit($?) }'`. Compiled last, it runs
   first: an `exit` in class code ends the worker with its status, without the hub's
   END blocks or global destruction.
8. **Build a fresh instance** with `args` (never the hub's), and run
   `$server->to_stdio`.
9. **Exit:**
   - `to_stdio` returns on EOF, and the worker calls `_exit(0)`.
   - If it dies, the message goes to stderr (the hub logs it and makes it the exit
     hint), and the worker calls `_exit(3)`.

**Output buffers.** Perl flushes all output handles before `fork` (perlfunc), so no
buffered hub output is written twice. The stdio transport autoflushes STDOUT.

**Module.** `MCP::Hub::Upstream::Fork` (the name is Claude's call) is a subclass of
`Upstream::Stdio`. It overrides four methods: `_build_server`, `_hash`,
`_apply_manifest` and `_spawn`. *As built*, it also overrides `_on_stderr`,
`_on_close` and `_exit_hint` (the stderr tail as exit hint, drained before the exit
is handled, as `Docker::Stdio` does) and `status_row` (`pss_kb`); `Stdio::_spawn`'s
parent side moved into `Stdio::_attach`, which both share. Everything else is
reused unchanged:

- the JSON-RPC client, timeouts and `notifications/cancelled`;
- answers to server requests (`ping`, `roots/list`);
- `list_changed` → refresh;
- the idle timer, the crash-loop window and stop/KILL.

The prototype is exactly that subclass.

### Calls

**One request at a time**, as with any stdio child: the transport reads the next
line only after it has answered. A slow call holds only its own worker.

**Timeouts.** A timed-out call sends `notifications/cancelled`, which a synchronous
tool cannot honour. The worker stays busy until the call returns, and the next call
waits, just as with a stdio mcp-wiki.

**What tool code sees.** Tool code in the worker gets a stdio
`MCP::Server::Context`:

- no controller, no HTTP request and no profile;
- `has_scope` is true for every scope (in MCP 0.15, no scopes means allowed).

A class whose tools read the HTTP request therefore cannot be forked. The build
cannot detect that, so the POD has to say it.

### Idle stop, crash, restart

All of this works as for stdio:

- **Idle stop.** Idle leads to `stop`: the worker gets EOF, TERM if it has not exited
  `EOF_GRACE` (2 s) later, then KILL after `KILL_GRACE` (5 s).
- **Next call.** The next call forks a new worker from the hub as it is at that
  moment. That also resets the worker's copy-on-write erosion.
- **Crash loop.** Three exits within `fail_window` make the upstream `failed`, which
  sticks until `refresh`. Meanwhile `tools/list` keeps answering from the façade.
- **Refresh.** `refresh` on a stopped or failed worker forks and handshakes;
  `Upstream::Stdio::refresh_p` stays unchanged.

### Shutdown and SIGTERM

**Normal shutdown.** `shutdown_p` stops every upstream, a worker as in an idle stop
(EOF, TERM after the grace), and waits for the workers to exit, bounded by the
daemon's 20 s. In the prototype, which sent EOF and TERM together, the worker was gone in 51–53 ms, even in the middle of a
1.5 s libgit2 call. Without the signal reset it took 1247 ms: the inherited Mojo TERM
handler runs at Perl level and is deferred until the XS call returns.

**Hub killed with SIGKILL.** The kernel closes the hub's end of the socketpair. The
worker reads EOF after its current call and exits. That follows from the transport's
read loop; it was not measured. The worker's stderr pipe then has no reader, and
because SIGPIPE is ignored, a write to it fails instead of killing the worker.

**A risk, fixed since (k39).** `stop` now sends EOF first and TERM only after a 2 s
grace, for every child. Before that, as this section was written: `stop` sent TERM together with EOF. For a
worker, and equally for a stdio mcp-wiki, that can kill a git commit halfway. It may
then leave `.git/index.lock` behind, after which every write fails until the file is
removed. That is libgit2's lock-file behaviour; it was not reproduced here, and the
window is about 25 ms per commit. A `stop` that sends EOF first and TERM only after a
grace period applies to every child, so it is a follow-up card, not part of this
design.

### SIGHUP and reload

- **The worker ignores HUP**; only the hub reloads.
- **Unchanged entry:** the upstream and its running worker stay, as today.
- **Changed entry** (`class`, `args` or `hub.*`): the old upstream is stopped (the
  worker gets EOF, TERM after the grace) and a new one is built. That means a new throwaway
  instance and a new manifest, and no worker until the next call; that worker starts only
  once the old one has exited.
- **Added entry:** its class is loaded at that point.
- **Class code is never reloaded.** `require` of an already-loaded module does
  nothing, so a newer mcp-wiki installed on disk reaches the hub and its workers
  only after a daemon restart. A stdio upstream would pick it up at its next spawn.
  This is the same as for a `class` entry today.
  - One corner case: a module whose compile failed halfway can look loaded on a
    retry, because `Mojo::Loader::load_class` returns early once the class
    `can('new')`. That is one more reason to restart.

### Status

The status row has `type` `fork`. While the worker runs, it shows the worker's `pid`;
the states are those of stdio.

`rss_kb` (VmRSS) counts every shared page. It reports 63–67 MB for a worker whose own
memory is 7–15 MB. A fork row should therefore carry `pss_kb` from
`/proc/PID/smaps_rollup` (Claude's call). The builder decides whether stdio rows get
it too.

## Fork safety inside a running Mojo::IOLoop

"Control" means the prototype run with the recipe switched off (`nosafety`), from a
hub that is otherwise identical.

| Inherited | What goes wrong without care | Design | Evidence (prototype) |
|---|---|---|---|
| **Listening socket** | The worker keeps the port open. A restarted hub cannot bind while the worker is busy, and new clients queue on a socket nobody accepts. | `/dev/null` over it | With the recipe, a new hub can bind after the old one dies while the worker is busy. In the control, bind fails and clients still connect to the dead hub's backlog. |
| **Client connections** | A client sees no EOF when the hub closes its connection, because the worker still holds it. | `/dev/null` | EOF after 22–53 ms. Control: 15.4 s, which was the worker's lifetime. |
| **Other upstreams' sockets and pipes** | A stdio child would not see EOF when the hub stops it, and its stderr pipe stays open. | `/dev/null` | Worker fds: 0/1 the socketpair, 2 its own pipe, everything else `/dev/null`. Control: the echo upstream's socketpair and pipe were inherited. |
| **EV vs Poll** | libev's epoll fd and eventfd are shared with the hub. libev in a forked child needs `loop_fork`. libev's C SIGCHLD handler would reap the worker's own children. | The worker never touches libev: the loop is frozen, libev's fds are nulled and CHLD is reset. Its own waits run on a fresh Poll reactor. Under Poll (the packed hub ships without EV) the same recipe holds. | Three EV runs and one Poll run gave the same results. The worker's reactor was `Mojo::Reactor::Poll`. |
| **Timers** | Hub timers (idle timers, recurring ones) fire inside the worker. | The frozen loop never runs. | A hub timer armed before the fork fired 0 times in the worker. |
| **Log handle** | With Mojo::Log on STDERR, the worker writes into the hub's log unmarked. With a log file, the two share an offset. | stderr is the worker's own pipe; the hub logs it under the server's name (`_on_stderr`). A log file is reopened with `O_APPEND`. | The fd table above. Reopening was checked by `reopen.pl`: own offset, same position, a deleted file still readable. |
| **Git::Raw / libgit2 and other XS** | A repository opened in the hub is shared with the worker (fds, mmapped pack windows, caches). A mutex held by another thread at fork time stays locked forever in the child. | The hub drops its instance before any fork, so no repository is open; the worker opens its own. A fork is refused when the hub runs more than one thread. libcrypto (linked by Git::Raw) reseeds its RNG after fork from OpenSSL 1.1.1 on — background knowledge, not exercised, since the wiki makes no network calls. | At fork time the hub's fd list holds no `.git` file. Threads: 1. |
| **`$$`-dependent state** | Objects that cached the hub's pid. | Perl updates `$$` after fork. Mojo::UserAgent resets itself on a pid change. `srand()`. The dead copies of the hub's `Upstream` objects, with their child pids, never run. | — |
| **DESTROY and END** | Inherited streams close on destruction and fire hub close handlers, e.g. an `Upstream::Stdio` `_on_close` reaping a sibling. Hub END blocks run (a packed hub's PAR cleanup, File::Temp unlinks). | Freezing keeps those objects alive. `_exit` skips global destruction. The END guard catches `exit`. | `exit 7` in class code: the hub's END block did not run, and the exit status stayed 7. Without the guard, the hub's END block ran in the worker. |
| **Signal handlers** | Mojo's TERM/INT handler (Perl-level and deferred, so stops are slow), libev's CHLD handler, HUP. | `exec`-like reset; HUP ignored. | SigCgt 0; SigIgn = HUP, FPE, PIPE. Control: SigCgt = INT, TERM, CHLD. |
| **Process name** | `pidof mcp-hub` returns the worker too, so `kill -HUP $(pidof mcp-hub)` hits it. | `$0` renamed | `pidof` matches the worker without the rename, and only the hub with it. |
| **Buffered output** | Hub output written twice. | Perl flushes before `fork`. | — |
| **Threads** | Locks held by another thread. | Fork refused when the hub runs more than one thread. | A loaded hub with the wiki ran 1 thread. |

## The hazards, one by one

- **Lazy start.** `tools/list` costs no process. The class is loaded at build, as a
  `class` entry is today, and a worker is forked only on a call. Two changes follow:
  `%LAZY` gains `fork`, and `_warm_upstream` skips it.
- **The façade keeps `extra`.** A fork entry goes through the façade, just as stdio
  does:
  - `Facade->apply` reads the class's own list rendering into `Facade::Tool`'s
    `extra`, and `Facade::Server` merges it back.
  - A class that renders `title`, `icons` or `_meta` keeps them on its endpoint.
  - One difference from today's in-process mount: there the class's own MCP::Server
    answers agents directly, so it would pass fields the façade does not know (MCP
    0.15 has none). Through the façade only the known fields pass, as for stdio.
  - `/all` drops extras for every type; that is k30.
- **404 / 401 / 503.**
  - 404 (not in profile) and 401 (bad token) are decided at route level and do not
    change.
  - 503 "not ready yet" never applies: the façade is filled at build with
    `manifest_fetched_at` set.
  - A failed worker (crash loop) makes `tools/call` return `isError` with the refresh
    hint, while `tools/list` still answers. The list is never silently empty.
  - A build failure produces the failed placeholder, as today.
- **Config stays JSON-expressible.** The new knob is `hub.fork`, with the errors and
  JSON paths listed in **Configuration**. There is no new CLI flag.
- **Manifest hash.** Not involved. Nothing goes to disk and `_hash` is unused, so the
  `[command, args, cwd]` rule for stdio is untouched. `args`, which may carry
  secrets, is never hashed or written anywhere.
- **One process.** See **The decision for the maintainer**.

## Memory

### Method

- **Source.** Every number comes from `/proc/PID/smaps_rollup`:
  - USS = `Private_Clean + Private_Dirty`;
  - PSS (each shared page divided among the processes that map it);
  - `Swap` was 0 for every measured process.
- **Headline figure.** The cost of a running worker is **ΔPSS over the hub and the
  worker together**, compared with the hub before the fork. Neither the worker's RSS
  nor its USS alone is the cost: RSS counts the pages it shares, and USS misses the
  pages the *hub* has to make private once the worker holds the old copy.
- **Setup.** A real `MCP::Hub` app under `Mojo::Server::Daemon->run`, with:
  - the EV reactor;
  - one warm stdio upstream (`t/upstream/echo.pl`);
  - one external HTTP client holding a keep-alive connection;
  - a 20 ms recurring timer to measure loop lag;
  - an `echo` call every 100 ms to measure an unrelated upstream's latency.
- **Wiki.** A generated wiki of 300 pages and 1000 commits (loose objects, 20 MB
  `.git`). Each upstream got its own copy.
- **One round** of the workload: 3 × `get_section_history`, 5 search misses,
  60 × `update_paragraph` (each one a git commit), 20 × `get_page` and
  2 × `list_pages`.
- **Runs:**
  - three EV runs of 3 rounds each (run 1 lost its USS figures to a script bug; its
    PSS figures are kept);
  - one Poll run of 1 round;
  - one control run with the recipe off.

  The same workload then went through an exec'd stdio `mcp-wiki --git`, and once
  through the history tool called in process.
- **Load.** The machine was loaded by a parallel `pp` build (load average 5–6).
  Timings are noisy for that reason; memory figures are not load-sensitive.

### Numbers

| | USS | PSS | RSS |
|---|---|---|---|
| Hub before the fork (class loaded, manifest built) | 58.7–59.1 MB | 60.8–62.3 MB | 71.0–71.6 MB |
| Worker, idle after its first call | 7.3–7.4 MB | 33.5–33.9 MB | 63.3–63.8 MB |
| Worker after round 1 | 14.8–15.0 MB | 38.9–39.5 MB | 66.7–67.1 MB |
| Worker after round 3 | 15.1–15.2 MB | 39.4–39.7 MB | 67.1–67.2 MB |
| Hub after the rounds (its own USS was 7.7–8.0 right after the fork) | 12.6–12.9 MB | 38.3–39.6 MB | 71.6–72.2 MB |
| **ΔPSS, hub + worker, after the rounds** | | **+16.2 / +17.4 / +17.8 MB** (EV), **+16.4 MB** (Poll, 1 round) | |
| stdio mcp-wiki, idle after start | 46.0–46.1 MB | 49.1–49.4 MB | 59.8 MB |
| stdio mcp-wiki, after round 3 | 48.9 MB | 51.8–52.3 MB | 62.8–62.9 MB |

The two processes still share 45.4–45.7 MB (`Shared_Dirty`) at the plateau.

**Class load cost in the hub** (USS, measured in a separate script):

- `MCP::Wiki::Server`: +3.9 MB;
- `Git::Raw` and `MCP::Wiki::Git::History`: +1.4 MB;
- one instance: +0.6 MB;
- total: +5.9 MB. k29 measured +6.1 MB.

Dropping the instance does not shrink RSS.

**Time:**

| | Forked worker | stdio mcp-wiki |
|---|---|---|
| Start until ready | 21–35 ms | 1.5–3.6 s |
| Hub stall per fork | 2.3–5.7 ms at 71 MB RSS | — |

Synthetic fork stalls: 0.9 ms at 7 MB, 7.1 ms at 107 MB and 24 ms at 257 MB. That is
about 0.1 ms per MB, for copying the page tables.

**Loop responsiveness while the workload ran:**

| | Max loop lag | Max latency of an unrelated `echo` call |
|---|---|---|
| Forked worker | 6–41 ms | 11–70 ms |
| stdio mcp-wiki | 11–60 ms | 23–50 ms |
| One history call in process | 1579 / 1739 / 2185 ms | (k29: echo held for 5.1 s) |

### Reading them

- **What it costs.** A forked mcp-wiki costs **about 23 MB while it runs**: +5.9 MB
  for the class in the hub, plus about 17 MB ΔPSS. A stdio mcp-wiki costs **about
  52 MB**. When idle-stopped, the forked one still costs **5.9 MB** (the class stays
  loaded) and the stdio one costs **0**.
  - So fork pays off while a wiki runs, and costs a little while it does not. For a
    shared knowledge store used by several agents, running time probably dominates;
    that is Claude's reading and the maintainer's call.
  - A second wiki entry with the same class adds about 0.1 MB in the hub (k29) plus
    its own running worker. That figure was not measured.
- **Correcting k29.** k29's "about 6 MB per running wiki" was the worker's
  `Private_Dirty` after a lighter workload. ΔPSS over both processes is the honest
  figure: **about 17 MB**.
- **Copy-on-write erosion plateaus.** The worker's USS rises in the first round
  (7.4 → 15 MB) and then stays put (15.0 → 15.2 MB over rounds 2–3). The cause is
  perl touching shared data (refcounts, magic) and copying the page. The hub does the
  same on its side: its own USS rises by about 5 MB, because pages it writes become
  private to it and their old copies private to the worker.
  - The worker grows by about 7.7 MB USS. The stdio child grows by about 3 MB under
    the same workload, so about 5 MB of the worker's growth is erosion.
  - Hours of `always_on` were **not measured**. Idle stop doubles as a recycle,
    because the next worker is forked fresh.
- **Transparent huge pages** were `always` on this box. Since Linux 5.8, a
  copy-on-write fault on an anonymous THP copies 4 KiB, not the whole huge page. That
  is background knowledge, not measured here.

## The packed binary (k28, k36)

**A class must be packed into the hub to be mountable.** A packed hub's `@INC` holds
only its PAR archive, and the loader strips `PERL5LIB` (k29). That applies to a fork
entry exactly as to a `class` entry.

**What packing mcp-wiki would take:**

- **Size:** about +3.8 MB on the 13.2 MB binary (Raw.so is 3.5 MB deflated, plus
  0.3 MB of `.pm` files).
- **A different libgit2:** the CPAN build of Git::Raw links libssh2 and
  `libcrypto.so.3`, which fails the binary's runtime-lib check (then
  `scripts/check-binary-libs.sh`, now the bundle's `lib-gate.pl`). Packing would need a
  static libgit2 without SSL.
- **Release coupling:** each hub release would carry a pinned mcp-wiki, so every
  mcp-wiki fix would need a hub release.

**Recommendation: don't pack mcp-wiki into the generic hub binary.**

- Users of the packed hub mount mcp-wiki as stdio. They can use mcp-wiki's own
  binary (see p5-mcp-wiki's binary release design), or a CPAN install with `env`
  `PERL5LIB` as described in k29.
- Fork mode in a packed hub is for classes that are already in it, which means the
  natives (see the ClaudeHistory research card).

**PAR specifics:**

- **Archive fds** (corrected after k44, 2026-11-06 — the draft said a worker's lazy
  `require` reads the archive through these fds). A packed hub holds two read-only
  fds on its own binary: the loader's (fd 3 in the builds measured) and `_FH`, PAR's
  bootstrap handle (fd 5), through which Archive::Zip read the zip's directory at
  start-up. Measured with PAR 1.021 and PAR::Packer 1.064:
  - **A `require` does not read through them.** The first start unpacks the whole
    archive into `PAR_TEMP/inc` and puts its `lib` dirs first in `@INC`, so a
    `require` — in the hub or in a worker — reads plain files from there. A member
    read (`PAR::read_file`) reopens the binary by name; no member keeps a handle.
    So the draft's reason against nulling the fds (a broken `require`) does not
    hold; the reopen rule stays as built.
  - **The reopen rule** gives the worker its own description of each fd. Verified in
    the packed binary by the k44 smoke: a read on them in a worker leaves the hub's
    offsets alone.
  - **The hub's first `fork()` of any kind moves fd 5 once.** Perl flushes every
    handle before a fork; `_FH` still holds read-ahead, so its fd is set back to
    `_FH`'s own position (14285807 to 6027650 in one build). Later forks leave it.
    "The hub's offset is unmoved" holds from the first fork on, which is what the
    smoke compares against.
- **PAR's END cleanup** (only with `--clean`, which is not used today) does not run
  in a worker, because of the END guard.

**Windows is not a target.** A pp-built Windows binary has no real fork, so
`hub.fork` fails there with the non-Linux build error.

## mcp-wiki: option (a)

**The two options.** k29 laid out two ways to mount a class that *holds* an
MCP::Server rather than *being* one:

- **(a)** the hub accepts an instance whose `->server` returns an MCP::Server;
- **(b)** mcp-wiki ships an adapter class that *is* one.

**This design picks (a)**, for four reasons:

- **It works with mcp-wiki 0.002 as released.** There is no release coupling, and
  trying it needs no new mcp-wiki version.
- **"Holds a server" is a common composition** in Perl MCP servers (a Moo class with
  `has server`). With (b), every such distribution would need its own adapter.
- **One helper serves both paths:** taking the server from either kind of instance
  works for the in-process path and the forked one.
- **mcp-wiki's side shrinks to one promise.** `server`, and a cheap constructor,
  become API that it guarantees (card on p5-mcp-wiki). The constructor runs once in
  the hub at build and once in every worker.

**The cost:** a plain `class` entry (without `fork`) could then mount mcp-wiki in
process too, and that stalls the hub on every history call. The POD has to warn about
that, and open question 3 asks whether (a) should apply only together with `fork`.

## Tests

No test spawns node, touches the network or reads the real `~/.claude`. The only
upstream program stays `t/upstream/echo.pl`; the fork tests run its server as a
class.

**Fixtures:**

- **Echo server as a class.** Move `echo.pl`'s server into a `t/lib` class.
  `echo.pl` keeps running it over stdio, and fork entries mount the same class, so
  one fixture covers both transports.
- **Probe tools,** on that class or a subclass used only by the fork tests:
  - `whoami`: pid, `$0`, ppid;
  - `fds`: `readlink` of each `/proc/self/fd/*`;
  - `signals`: the `Sig*` lines of `/proc/self/status`;
  - `sleep`: blocks for N seconds;
  - `exit`: calls `exit N`;
  - `crash`: the worker kills itself (`kill KILL => $$`). A tool that merely dies
    is caught by MCP::Server and answered with a JSON-RPC error (-32603), so it
    is no crash;
  - a tool that renders `title` and `_meta`.
- **Option-(a) fixture:** a composed class with `has server` returning the fixture's
  MCP::Server.
- **Refusal fixture:** a class with a `hub` attribute, which must be refused.
- **Worker-only failure:** a class whose constructor dies only inside a worker
  (its `$0` starts with `mcp-hub-worker`). The hub's manifest builds, the start
  fails, and the constructor's message becomes the exit hint.

**`t/fork.t`** (Test::Mojo + MCP::Client against a temp config and cache dir, like
`t/hub.t`) covers:

- **Config errors with JSON paths:** `hub.fork` on a `command` entry, `env` or `cwd`
  with `hub.fork`.
- **Manifest without a process:**
  - after startup, status shows no pid;
  - `tools/list` equals the class's in-process rendering, extras included, for both
    an MCP::Server subclass and the composed option-(a) class;
  - instructions are present;
  - no 503.
- **Refusals:** the `hub`-attribute class and a non-server class become failed
  placeholders, with the messages from **Configuration**.
- **Lifecycle:**
  - the first call forks, and the worker's pid differs from the hub's;
  - two concurrent calls queue;
  - idle stop with `idle_timeout` 1, then a re-fork on the next call;
  - a crash loop (3 × `crash`) leads to `failed`, and `refresh` brings the worker
    back. *As built:* the server's own endpoint then answers 503 with the reason,
    like any `failed` upstream; through `/all` its tools are still listed and a call
    returns `isError` naming the refresh command;
  - a stop during `sleep 5` leaves the worker gone in under 1 s.
- **Isolation** (Linux; the whole file skips elsewhere):
  - the worker's fds hold no socket inode that the hub holds, except its own
    socketpair;
  - SigCgt is 0, and HUP is ignored;
  - `$0` is `mcp-hub-worker NAME`;
  - a regular file the hub had open is readable in the worker without moving the
    hub's offset.
- **END guard:** an END block in the test writes a marker file. `exit 7` in the
  worker leaves no marker, and the recorded exit status is 7. *As built:* under
  `Mojo::Reactor::EV`, libev's default loop reaps every child itself at top
  priority, and the hub's `waitpid` then finds nothing: the exit reads "unknown".
  That race exists for every child (stdio and docker too, noted on k42); a test
  that looks at an exit status sets `local $SIG{CHLD} = 'DEFAULT'` for it.
- **No stall:** while a worker blocks in `sleep 2`, a recurring timer in the test
  shows a maximum lag under 0.5 s, and a call to the stdio echo upstream answers.
- **Reload:**
  - an unchanged entry keeps its worker (same pid);
  - changed `args` give a new manifest and, on the next call, a new worker;
  - a removed entry's worker is gone.
- **Shutdown:** `shutdown_p` reaps the worker.
- **Thread guard:** the thread count is read through a method the test can override,
  so it reports 2, and the start fails with the message from **Configuration**.

**`t/wiki-live.t`** is an opt-in live test, run with `MCP_HUB_TEST_WIKI=1` or
`RELEASE_TESTING`, and skipped without MCP::Wiki. It mounts `MCP::Wiki::Server` with
a temp `wiki_root` and `use_git`, then does one `write_page`, one `update_paragraph`
and one `get_section_history` through a forked worker.

The native tests in `t/native/` stay as they are, against
`t/fixtures/claude/projects/`. The canonical run stays `prove -lr t/`.

## Alternatives considered

- **Plain in process** (`class` with (a) or (b)). Cheapest in RAM: +5.9 MB in total
  and no worker. But each history call stalls the loop for 1.6–5.1 s, and every other
  upstream and agent waits with it. Rejected for a shared store.
- **A subprocess per call** (`Mojo::IOLoop->subprocess` for each `tools/call`). No
  idle worker, but it forks and constructs on every call and keeps no state between
  calls (mcp-wiki's open repository). Parallel calls would also become parallel git
  writers, which means lock contention. Rejected.
- **A zygote, or fork server.** A clean process forked early would fork workers on
  request. It avoids inheriting the hub's live state, but it is a second long-lived
  process to manage, and it has to load every class a reload adds. Rejected for v1.
  It remains the fallback if the isolation recipe proves brittle.
- **Exec'd stdio** (today). The simplest and most robust option, at about 52 MB PSS
  while running and a 1.5–3.6 s cold start. It is the answer if the maintainer says
  no.

## Open questions for the maintainer

1. **Accept forked class workers** under the reworded one-process rule? (See **The
   decision for the maintainer**.)
2. **Knob shape:** `hub.fork: true` on a `class` entry (proposed), a kind of its own
   (`"fork": "MCP::Wiki::Server"`), or fork as the default for every `class` entry,
   with `hub.fork: false` to opt out?
3. **Option (a)** for plain in-process `class` entries too, or only together with
   `hub.fork`? Proposed: both, as one rule, with a POD warning about stalls.
4. **Pack mcp-wiki into the hub binary?** Recommendation: no.
5. **Close the `class`-entry drift now?** A `class` entry silently ignores `env`,
   `cwd`, `headers`, `type` and the `hub` timeouts. Refusing them with a JSON path
   would break any config that carries them today, even though they do nothing.
6. **`always_on` with fork:** allowed (proposed), even though copy-on-write erosion
   over hours was not measured?

## Decisions (maintainer, 2026-11-04)

All six questions were answered with the recommendation:

1. **Yes**: the hub may fork class workers, under the reworded one-process rule in
   **The decision for the maintainer**.
2. **Knob**: `hub.fork: true` on a `class` entry.
3. **Option (a)** applies to plain in-process `class` entries too, with a POD
   warning that a slow tool stalls the hub.
4. **mcp-wiki is not packed** into the hub binary.
5. **The drift is closed now**: a `class` entry refuses `env`, `cwd`, `headers`,
   `type` and the `hub` timeouts that do not apply, each with its JSON path. Nothing
   breaks for users, because the hub has not been released yet.
6. **`always_on` is allowed** together with `hub.fork`.

## Follow-up cards (proposed — the dispatching agent files them)

**p5-mcp-hub**

- **Forked class workers: `Upstream::Fork`, `hub.fork`, option (a)** (worker lane,
  only if question 1 is answered yes). Implement this design, including `pss_kb` in
  the status row. Also reword the one-process hazard in CLAUDE.md, the rules file,
  `mcp-hub-core` and the "Process model" POD.
- **Tests for forked class workers** (test-writer lane). Move `echo.pl`'s server into
  a `t/lib` class, add probe tools and the option-(a) and refusal fixtures, write
  `t/fork.t` as in **Tests**, and add the opt-in `t/wiki-live.t`.
- **A `class` entry silently ignores `env`, `cwd`, `headers`, `type` and `hub`
  timeouts** (drift). The config accepts them and nothing applies them. Refuse them
  with a JSON path, or document them; see open question 5.
- **Packed hub: smoke a forked worker** (binary-worker lane, after k36). Fork a native
  class from the packed binary, check that a lazy `require` in the worker reads the
  archive through its reopened fds, and check that the hub's offset is unmoved
  (premise corrected in **The packed binary**).
- **Stop children with EOF first, TERM after a grace.** Done with k39: `stop` sends
  EOF, TERM 2 s later, KILL 5 s after that, for stdio as much as for fork. Before, TERM
  came together with EOF and could kill a git commit halfway (`index.lock` left behind).
- **Research: `Native::ClaudeHistory` as a fork candidate.** Its synchronous
  slurp and search run in the hub's loop. Measure the stall on a large history, then
  decide.

**p5-mcp-wiki**

- **Pin `MCP::Wiki::Server->server` as the embedding API.** Add a test and POD. The
  constructor stays cheap and free of side effects: the hub runs it at build and in
  every worker.
- **Note on the existing k62 and k63** (unusable `wiki_root` not caught at startup;
  `~` in `wiki_root`), rather than new cards. The hub expands nothing in class
  `args`, so both bite every hub user. Raise their priority.

## Left to the builder

- **Names:** the module name, the status `TYPE` for fork rows, and whether the
  isolation recipe lives in the upstream or in a small helper module.
- **How the type gates are expressed:** `%LAZY`, `_effective_timeouts`,
  `_warm_upstream`, `_build_upstream` and `_route_server` check `type`. They can
  either learn `fork` or ask the upstream through a method.
- **Process details:** the worker's exit codes, how its last stderr line becomes the
  exit hint, and how `pss_kb` is shown.
- **Error wording:** the exact texts, within the JSON-path convention.

## As built (k42, k38)

What the builder decided, and where the build differs from the draft above:

- **Names:** `MCP::Hub::Upstream::Fork`, status `TYPE` `fork`; the isolation recipe
  lives in the upstream (`_worker`, `_reset_signals`, `_isolate_fds`, `_reopen_file`).
- **Type gates:** `%LAZY` in `MCP::Hub` learns `fork` (idle timeout, warming stop);
  `_build_upstream`, `_warm_upstream` and `_route_server` needed no change, because a
  fork upstream has `manifest_fetched_at` from its build and so is never warmed and
  never 503 "not ready yet".
- **Exit codes:** `0` after EOF, `3` when the instance could not be built or its
  server died (the message on stderr); an `exit` in class code keeps its own code.
  The last five non-blank stderr lines become the exit hint, after
  ` while starting CLASS` when the worker died during the handshake.
- **The thread refusal** goes through `_record_exit` in `_spawn`; for it to count
  toward the crash loop, `Stdio::start_p` now leaves a refused spawn in `failed`
  when `_spawn` recorded the third exit (it used to be `stopped` regardless).
- **Option (a)** is shared by `Upstream::Perl` and `Upstream::Fork` through
  `Upstream::_load_class` and `Upstream::_server_of`; an in-process class keeps its
  instance alive in `$up->{instance}`.
- **`always_on` and the timeouts on an in-process class** are refused (k38), since
  there is no process for them; with `hub.fork` they apply.
- **`pss_kb`:** on fork rows only, shown as a `PSS_KB` column by `mcp-hub status`
  (`-` for every other row). Stdio rows do not get it.
- **Fixtures:** `echo.pl`'s server moved into `t/lib/EchoServer.pm` here already
  (its `exit` tool takes an optional `code`), with `t/lib/ForkProbe.pm` (`whoami`, and
  `title`/`_meta` on `echo`) and the option-(a) `t/lib/ComposedEcho.pm`; `t/fork.t`
  covers part of **Tests**.
- **Not built here:** the remaining probe tools and tests of **Tests** (k43), the
  live `t/wiki-live.t` (k43), the packed-binary smoke (k44), EOF-first stop (k39).

## Calls made by Claude, not by the maintainer

- **Knob:** `hub.fork`, truthy like `always_on`, normalized to `type: 'fork'`.
- **Manifest:** built from a throwaway instance in the hub, through the class's own
  JSON-RPC `handle`, with instructions read off the object. No disk cache and no
  hash.
- **No shared instance:** the hub drops that instance before any fork, and each
  worker builds a fresh one.
- **Reuse:** a subclass of `Upstream::Stdio` (four overrides), one request at a time.
- **The isolation recipe:**
  - signals reset the way `exec` would, with HUP ignored;
  - `reset({freeze => 1})`;
  - the reopen rule for regular files and `/dev/null` over everything else;
  - `srand()`, the END guard, `_exit`;
  - `$0` set to `mcp-hub-worker NAME`.
- **Refusals:** classes with a `hub` attribute, and forks while the hub runs more than
  one thread.
- **Platform:** Linux only in v1; no `env`/`cwd` in v1.
- **mcp-wiki:** option (a) rather than (b).
- **Binary:** do not pack mcp-wiki into the hub binary.
- **Status:** `pss_kb` on fork rows.
- **Measurement:** ΔPSS over hub and worker as the headline figure, not RSS or the
  worker's USS.
- **Upgrades:** class code is never reloaded; a daemon restart is needed after
  upgrading a forked class (as for `class` entries today).
- **Kept out of scope:** EOF-first stop, the class-entry drift and ClaudeHistory are
  follow-up cards here, not parts of this design.
