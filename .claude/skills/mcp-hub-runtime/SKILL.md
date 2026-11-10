---
name: mcp-hub-runtime
description: Load with mcp-hub-core before changing how the hub talks to or shows upstreams — the upstream types (stdio legacy JSON-RPC, remote HTTP/SSE, in-process or forked Perl class, Docker image or Compose service), the manifest cache, the façade, the /all aggregate, the wire rules for server-initiated traffic, the native servers, the dynamic routing.
user-invocable: false
model: inherit
---

# mcp-hub-runtime

`mcp-hub-core` sagt, **was** der Hub ist (Architektur, Invarianten, Config, CLI). Diese
Skill sagt, **wie** er sich verhält: Upstream-Typen, Manifest-Cache, Façade, `/all`,
server-initiierter Verkehr, Natives, Routing. Die Design-Specs zu den Alternativen B/C
liegen in `docs/superpowers/specs/`.

## Referenzen — briefing lädt nur diese Datei; vor einer Änderung im Bereich lesen

| Änderung an … | lies |
|---|---|
| `Upstream::Stdio` und was Fork und Docker-stdio erben: Handshake, Line-Buffer, Stop/EOF, `stopping`, Refresh-Bindung | `references/stdio.md` |
| `Upstream::Http`: `req_ua`, SSE-Stream, Sessions, `404`-Retry, `_cancel`, TLS | `references/http.md` |
| `Upstream::Perl`, `Upstream::Fork`: `class` laden, Wegwerf-Instanz, Worker-Rezept | `references/perl-fork.md` |
| `Upstream::Docker`/`Compose`: Modus je Start, Engine, Readiness, Labels, `depends_on` | `references/docker.md` |
| `Facade*`, `_show_manifest`, Fehler-Antworten, `let_go`/`_dropped`, Extras | `references/facade.md` |
| `Aggregate`, `/all`-Filter, `server/discover`, Namenskollisionen | `references/aggregate.md` |
| `Native::*`: History lesen, `meta_cache`, Zeitpunkte, JSON-Decoder, `/proc` | `references/natives.md` |
| Routen, `MCP::Hub::Endpoint`, gestreamte Antworten, Setup-Seite | `references/routing.md` |

## Verträge über alle Transporte

- Jede Anfrage ist ein non-blocking Promise; jede Ablehnung liest `upstream NAME: …`.
  Eine JSON-RPC-Error-Antwort lehnt als `Upstream::ErrorAnswer` ab, alles ohne Antwort
  (Timeout, Stop, Kind oder Verbindung weg, HTTP-Fehlerstatus) als String — unterschieden
  per `_answered` (isa), **nie am Text**.
- Handshake: `initialize` mit Protokoll `2025-06-18` (die Version der Antwort gilt) →
  `notifications/initialized` → `tools/list` **mit Cursor-Pagination** (`nextCursor`) →
  `prompts/list`/`resources/list` nur, wenn die Capabilities sie deklarieren.
- Listen: eine Error-Antwort auf `prompts/list`/`resources/list` ist eine leere Liste;
  ohne Antwort behält ein Start die Liste aus dem Cache (`_kept_list`), ein Refresh
  scheitert und lässt das alte Manifest; ein Fehler auf `tools/list` lässt beide scheitern.
- Ein Request-Timeout lehnt als `upstream NAME: timed out after Ns` ab und schickt
  `notifications/cancelled` mit der id und dem Grund als `reason` (`_cancel`) — nie für
  `initialize` (Spec).
- `upstream NAME: stopped` ist Vertrag: so scheitert, was ein Stop abschneidet, und
  `Hub::_called_off` erkennt genau diesen Text — ein abgesagter Start ist kein
  gescheiterter Fetch (kein error-Log, kein `failed`).
- Über einen Reload: wer losgelassen ist (`_dropped`, per `refaddr` gegen
  `upstreams_by_name`), spawnt nichts, schreibt keinen Cache und benachrichtigt niemanden.
  Ein stdio-/Fork-Start wartet auf `stopped_p` aller `Hub->predecessors`, ein
  Container-Start über `%SETTLING`; Http und Docker/Compose fragen `predecessors` nicht.
- Ein stdio-Upstream (und wer von ihm erbt) hat höchstens ein Kind: ein Call während eines
  Stops wartet auf `_gone_p`. Jedes exec'te Kind, auch jeder `docker`-Lauf:
  `Child::close_inherited_fds` (fds > 2 zu), `child_env` ohne `MOJO_REUSE`, `watch_exit`
  direkt nach dem `fork`; der Fork-Worker legt `/dev/null` darüber (`inherited_fds`).

## Die Upstream-Typen

- **Stdio:** `fork`/`exec`; stdin/stdout **ein** `AF_UNIX`-Socket-Pair, stderr eine Pipe
  auf `debug`. Zeilen-JSON, eine kaputte Zeile wird übersprungen; der Line-Buffer ist bei
  16 MB gekappt (Kill, zählt zur Crash-Loop); Exit 127 nennt das Kommando. Stop: EOF erst
  nach `drain`, `SIGTERM` nach `EOF_GRACE` (2 s), `SIGKILL` nach `KILL_GRACE` (5 s). Ein
  Refresh ist an das Kind gebunden, auf dem er begann. Drei Exits binnen 5 s → `failed`.
- **Http:** `req_ua` trägt jeden POST, ohne Inactivity-Timeout — `request_timeout`
  (Default 60 s) ist die einzige Grenze; der SSE-GET läuft roh auf `Mojo::IOLoop`
  (`_open_sse_p`), weil `Mojo::UserAgent` keinen chunked Event-Stream parst.
  `type: "http"` = Streamable HTTP, `"sse"` = HTTP+SSE; `headers` trägt das Auth. Jeder
  Start öffnet eine neue Session, ein Stop beendet sie per `DELETE`; ein `404` auf eine
  Session-Id → neue Session, der Request geht genau einmal neu. `https` braucht
  `IO::Socket::SSL` 2.009+, sonst ein `failed`-Upstream, den nur ein Neustart heilt.
- **Perl** (`class`): einmal instanziiert, den Hub nur bei `$class->can('hub')`; die
  Instanz **ist** der `server` oder hat `server` und beantwortet `tools/list` selbst —
  kein Manifest, State immer `ready`, `stop`/`refresh_p` No-ops; erst `let_go` leert die
  Listen ihres Servers. Ein langsames Tool blockiert die ganze IOLoop.
- **Fork** (`class` + `"hub": {"fork": true}`): `Stdio`-Subklasse; Manifest beim Build
  aus einer Wegwerf-Instanz (kein Cache, kein Hash), beim ersten Call `fork` ohne `exec`
  nach festem Rezept (Signale, `Mojo::IOLoop->reset`, fds, `_exit`). Mehr als ein Thread
  → kein Fork. Verweigert (→ Placeholder): Klassen mit `hub`-Attribut, Listing per
  Promise, eine Error-Antwort auf `tools/list`, kein `/proc/self/fd`. Status: `pss_kb`.
- **Docker/Compose:** lazy wie stdio; jeder Start entscheidet stdio oder HTTP neu
  (`_plan_p`) und baut eine Engine (`Docker::Stdio`/`Docker::Http`), die Crash-Loop zählt
  der Upstream über alle Läufe. Readiness ist ein POST-Poll, kein offener Port. Was dem
  Hub gehört, sagen nur die Labels (`mcp-hub.owner`) — nie einen fremden Container
  anfassen. `env` nur als nacktes `-e KEY`; Fehlertexte nur aus stderr (`stderr_tail`).

## Der Manifest-Cache

Unter `<cache_dir>/manifests/`, Datei `<name>-<hash>.json`. Der Hash entsteht aus
den ersten 16 Hex-Zeichen des SHA-256 über `[command, args, cwd]` — bei HTTP über
`[url, type]`, bei docker über `"docker:<image>"` plus `[args, port, path, transport,
volumes, docker_args, stdio]`, bei compose über `"compose:<dir>"` plus `[service, url,
port, path, transport, stdio]` — bewusst **nie** über `env`, nie über
`docker_command`/`docker_network`. Writes sind atomar: eine Temp-Datei
im selben Verzeichnis, dann `rename`. Es gibt **kein TTL**: ein veraltetes
Manifest kostet nur eine falsche Tool-Beschreibung bis zum nächsten Refresh.
`fresh` vergleicht den gespeicherten Hash mit dem aktuellen.

## Façade und `/all`

- `Facade->build($upstream, $manifest)` baut eine `Facade::Server`; `apply` ersetzt die
  Listen **in place**, damit Instanz und Abonnenten über einen Refresh dieselben bleiben.
  Jede Primitive hält ihren Upstream **schwach**; den Server hält allein sein Upstream.
- Ein neues Manifest (`Upstream::_show_manifest`) vergleicht das Rendering vorher/nachher:
  `<kind>/list_changed` nur je geänderter Liste, `/all` über `Hub::rebuild_aggregate`;
  unverändert keine Notification — sonst schickte jeder Neustart nach dem Idle-Stop eine.
- Extras finden ihr Objekt **per Position** (`_pairs`), nie per Name.
- `/all`: Tools und Prompts mit `<name>__`-Präfix, `## <name>`-Instructions, Resources
  nicht. Filter nach `Aggregate->origin`, nie durch Splitten am ersten `__`; `rebuild`
  liest die Extras aus dem eigenen Rendering jedes Upstreams und hängt sie an den Wrapper;
  `_dispatch` schreibt `server/discover` pro Request auf das Profil um.

## Server-initiierter Verkehr

Der Hub terminiert alles, was der Upstream anfordert:

| Anfrage | Antwort |
|---|---|
| `ping` | `{}` |
| `roots/list` | `{roots: []}` |
| alles andere mit `id` (z. B. `sampling/createMessage`, `elicitation/create`) | Error `-32601` ("Method not supported by mcp-hub") |

`notifications/(tools|prompts|resources)/list_changed` → Manifest stale, im
Hintergrund `refresh_p` — nicht von einem stdio-Kind, das gerade gestoppt wird: nur
debug, kein Refresh, der sonst nach jedem Idle-Stop ein Kind ohne Call startete; das
nächste Kind listet seine eigenen. `notifications/message` → Log auf der Ebene aus
`params.level` (`debug`/`info`/`warn`/`error`). `notifications/progress` und
alles andere werden verworfen.

## Natives und Routing

- `Native::ClaudeHistory` liest `$CLAUDE_CONFIG_DIR` bzw. `~/.claude` zeilenweise, nie
  geslurpt, über `meta_cache`; Zeitpunkte per `_iso_ms`, nie als Strings. Jede gelesene
  Zeile geht durch das `decode_json` des eigenen Pakets (Cpanel::JSON::XS mit
  `allow_dupkeys`, sonst `Mojo::JSON`) — kein Decode daran vorbei. `ClaudeSessions` liest
  `/proc` (**Linux-only**, `proc_root` überschreibbar), kein `pgrep`.
- Eine Route `POST /#name`, **nach** `/all` und `/_hub/*`; ein unbekannter Name und ein
  Server außerhalb des Profils liefern **byte-identisch** dasselbe 404. Gebaut von
  `MCP::Hub::Endpoint->action` statt `to_action`: der Server schwach gehalten, und die
  Antwort jedes `tools/call`/`prompts/get`/`resources/read` geht als Event-Stream (Fehler,
  eigene Status und Listen bleiben JSON) — im Test ist `->json` dann leer, die
  `sse`-Events vor dem Request abonnieren (`rpc` in `t/aggregate-auth.t`).

## Test-Hooks

Jede Unit ist allein testbar: `Config` auf Strings, `Manifest` auf temp dir,
`Auth` auf einem Config-Hash, `Façade` auf einem Manifest-Hash mit Mock-Upstream,
`Stdio` gegen `t/upstream/echo.pl` (Perl `MCP::Server::Legacy`, Tools
`echo`/`sleep`/`fail`/`die`/`exit`/`notify`/`slow_lists` — der einzige Upstream, den die Suite
spawnt, außer `t/upstream/echo.sh` in `t/binary.t`; der Server selbst ist die Klasse
`t/lib/EchoServer.pm`, die `t/fork.t` als `class` forkt), Docker/Compose in `t/docker.t`
gegen `t/upstream/fake-docker.pl` per `hub.docker_command` (seine „Container" sind
`echo.pl`-Prozesse, jeder CLI-Aufruf wird protokolliert — kein Daemon, kein Image; die
„Container" enden, sobald der in `$state/owner` genannte Test-Prozess weg ist, auch bei
SIGKILL ohne END), die
Natives gegen `t/fixtures/claude/projects/`.
