---
name: mcp-hub-runtime
description: Load with mcp-hub-core before changing how the hub talks to or shows upstreams — the upstream types (stdio legacy JSON-RPC, remote HTTP/SSE, in-process or forked Perl class), the manifest cache, the façade, the /all aggregate, the wire rules for server-initiated traffic, the native servers, the dynamic routing.
user-invocable: false
model: inherit
---

# mcp-hub-runtime

`mcp-hub-core` sagt, **was** der Hub ist (Architektur, Invarianten, Config, CLI).
Diese Skill sagt, **wie** er sich verhält: die Protokoll-Details der
Upstream-Typen, der Manifest-Cache, die Façade, das `/all`-Aggregat, die Regeln
für server-initiierten Verkehr, die Native-Server und das dynamische Routing.
Die Design-Specs zu den Alternativen B/C liegen in `docs/superpowers/specs/`.

## Die Upstream-Typen

### Stdio — Legacy-JSON-RPC über einen Socket-Pair

`fork`/`exec`, kein CPAN-Dependency fürs Prozess-Handling. stdin/stdout sind **ein**
`AF_UNIX`-Socket-Pair (als `Mojo::IOLoop::Stream`), stderr eine Pipe, die auf
`debug` geloggt wird. Jede Anfrage ist ein non-blocking Promise, korreliert über
eine fortlaufende id; ein Request-Timeout schickt `notifications/cancelled` und
lehnt das Promise ab.

Handshake: `initialize` mit Protokoll `2025-06-18` (der Server antwortet, was er
will — seine Version wird übernommen) → `notifications/initialized` →
`tools/list` **mit Cursor-Pagination** (`nextCursor` wird verfolgt) →
`prompts/list`/`resources/list` nur, wenn die Capabilities sie deklarieren;
`-32601` wird toleriert.

stdout wird an Newlines gesplittet, jede Zeile als JSON dekodiert; eine kaputte
Zeile wird übersprungen (debug). Der Line-Buffer ist bei 16 MB gekappt — dann
wird der Kindprozess gekillt. Exit 127 beim Start ist ein Konfigurationsproblem:
die Meldung nennt das Kommando ("is it installed and executable?"). Drei Exits
binnen 5 s → `failed`.

### Http — Streamable HTTP oder HTTP+SSE

`Mojo::UserAgent`, zwei Agenten: der Stream-UA (SSE-GET) läuft **ohne** Timeout,
der POST-UA mit `request_timeout` (Default 60 s) — sonst kappt der POST-Timeout
den langlebigen SSE-Stream. `type: "http"` = Streamable HTTP (Antwort auf dem
POST, JSON oder `text/event-stream`), `type: "sse"` = HTTP+SSE (langlebiger
GET-Stream). `headers` trägt das Auth; eine Session-Id aus `Mcp-Session-Id` wird
mitgeschickt. Drei Fehlschläge binnen 5 s → `failed`.

Eine `https`-URL braucht TLS in diesem Perl: `IO::Socket::SSL` 2.009+ und
`MOJO_NO_TLS` ungesetzt. `Mojo::IOLoop::TLS` entscheidet das einmal beim Laden —
fehlt es, stirbt `Upstream::Http->new` mit einem Grund, der den Fix nennt, und
der Hub behält einen `failed`-Upstream mit diesem Grund; kein Retry, `refresh`
oder Reload heilt das, nur Modul installieren und Daemon neu starten. Dieselbe
Prüfung (`Http::_tls_missing`, derselbe Text) läuft in `Upstream::Compose->new`
für die `url` eines compose-Eintrags. Ein `docker`-Eintrag (und compose ohne
`url`) braucht sie nicht: die Adresse baut der Hub selbst, immer `http://`.

### Perl — In-Process, ohne Kindprozess

`class` via `Mojo::Loader`, `new(%args)` — `args` ist bei `class` ein **Objekt**
(keine Liste) und wird nicht expandiert. Die Hub-Instanz wird nur injiziert,
wenn die Klasse ein `hub`-Attribut hat (`$class->can('hub')`). Die Instanz
**ist** der `server` — oder hat eine `server`-Methode, die einen liefert
(Option (a), wie `MCP::Wiki::Server`; geteilt in `Upstream::_load_class` /
`_server_of`) — und beantwortet `tools/list` selbst: kein Manifest, kein
Cache. State immer `ready`; `stop` und `refresh_p` sind No-ops. Eine Klasse, die
nicht ladbar ist oder weder `MCP::Server` ist noch `server` hat, lässt den
Konstruktor sterben — der Hub macht daraus einen `failed`-Upstream mit Begründung.
Ein langsames Tool blockiert hier die ganze IOLoop.

### Fork — `class` mit `"hub": {"fork": true}`

`Upstream::Fork` ist eine `Stdio`-Subklasse; nur `_build_server`, `_hash`,
`_apply_manifest` und `_spawn` sind anders. **Beim Build** wird die Klasse im Hub
geladen, eine Wegwerf-Instanz beantwortet `initialize`/`tools/list` (und
`prompts/list`/`resources/list` laut Capabilities) über ihr eigenes `handle` mit
einem Legacy-`MCP::Server::Context`; `instructions` kommen vom Server-Objekt (das
Legacy-`initialize` von MCP 0.15 liefert sie nicht). Danach werden ihre
tool/prompt/resource-Listen geleert — Tool-Closures über `$self` sind ein Zyklus —
und die Instanz freigegeben. Kein Cache, kein Hash. Verweigert (→ Placeholder):
Klassen mit `hub`-Attribut, Listing per Promise, kein `/proc/self/fd`.

**Beim ersten Call** wird `fork` statt `fork`/`exec` gemacht; der Worker setzt
`$0 = "mcp-hub-worker NAME"`, Signale wie `exec` (gefangene → DEFAULT, HUP →
IGNORE, Maske leer), `Mojo::IOLoop->reset({freeze => 1})`, stdin/stdout auf den
Socket, stderr auf die Pipe, reguläre Dateien über `/proc/self/fd/N` neu geöffnet
(Position und Flags aus fdinfo), `/dev/null` per dup2 über jeden anderen fd > 2,
`srand()`, ein zuletzt kompiliertes `END { POSIX::_exit($?) }`, dann eine frische
Instanz und `->to_stdio`; Ende immer mit `_exit` (0, oder 3 mit der Meldung auf
stderr — die letzten Zeilen werden zum Exit-Hint). Läuft der Hub mit mehr als
einem Thread, wird nicht geforkt; das zählt wie ein fehlgeschlagener Start.
Lifecycle, Timeouts, Crash-Loop: alles von `Stdio`. Status-Zeile: `type` `fork`
plus `pss_kb` aus `/proc/PID/smaps_rollup`.

## Der Manifest-Cache

Unter `<cache_dir>/manifests/`, Datei `<name>-<hash>.json`. Der Hash entsteht aus
den ersten 16 Hex-Zeichen des SHA-256 über `[command, args, cwd]` (bei HTTP über
`[url, type]`) — bewusst **nicht** über `env`. Writes sind atomar: eine Temp-Datei
im selben Verzeichnis, dann `rename`. Es gibt **kein TTL**: ein veraltetes
Manifest kostet nur eine falsche Tool-Beschreibung bis zum nächsten Refresh.
`fresh` vergleicht den gespeicherten Hash mit dem aktuellen.

## Die Façade

`Facade->build($upstream, $manifest)` baut eine `Facade::Server`; `apply`
ersetzt die Listen **in place**, damit die gemountete Instanz (und ihre
Notification-Abonnenten) über einen Manifest-Refresh hinweg dieselbe bleibt.
Jedes Tool ruft `$upstream->call_tool`, jeder Prompt `get_prompt`, jede Resource
`read_resource` — Ergebnisse (`content`, `isError`, `structuredContent`) kommen
unverändert zurück.

Extras: `title`, `icons` und `_meta` stehen am Manifest-Eintrag. Tool-Extras
hängen an `Facade::Tool->extra`, Prompt-Extras (nach Name) und Resource-Extras
(nach URI) an `Facade::Server->extra`. `Facade::Server` mischt sie beim
Rendering von `tools/list`, `prompts/list` und `resources/list` in das Ergebnis
zurück — `MCP::Server` rendert sie sonst nicht. Claude-Code-Annotationen wie
`anthropic/maxResultSizeChars` und `anthropic/requiresUserInteraction` überleben
so den Weg durch den Hub.

## Das `/all`-Aggregat

`Aggregate->rebuild(\@upstreams)` baut die Tools und Prompts aller Upstreams mit
`<name>__`-Präfix; die `instructions` sind die aneinandergehängten
Upstream-Instructions, jeder Block mit `## <name>` überschrieben. Resources
werden **nicht** aggregiert (opake URIs würden kollidieren). Der Tool-Filter des
Profils benutzt das Präfix, um `servers`- und `tools`-Regeln anzuwenden.

## Server-initiierter Verkehr

Der Hub terminiert alles, was der Upstream anfordert:

| Anfrage | Antwort |
|---|---|
| `ping` | `{}` |
| `roots/list` | `{roots: []}` |
| alles andere mit `id` (z. B. `sampling/createMessage`, `elicitation/create`) | Error `-32601` ("Method not supported by mcp-hub") |

`notifications/(tools|prompts|resources)/list_changed` → Manifest stale, im
Hintergrund `refresh_p`. `notifications/message` → Log auf der Ebene aus
`params.level` (`debug`/`info`/`warn`/`error`). `notifications/progress` und
alles andere werden verworfen.

## Die Native Server

`Native::ClaudeHistory` liest `$CLAUDE_CONFIG_DIR` bzw. `~/.claude`, Unterordner
`projects/`; vier Tools: `list_projects`, `list_sessions`,
`search_conversations` (Substring-Suche, **kein** Volltext-Index in v1 — streamt
und filtert) und `get_conversation`. `Native::ClaudeSessions` findet laufende
`claude`-Prozesse über `/proc/*/comm` (plus `cwd`) — **Linux-only**, andernfalls
ein Error-Result (`proc_root` ist testbar überschreibbar). `Native::Status`
liefert `hub_status` und `hub_refresh` (letzteres braucht in clients mode ein
`admin`-Profil). `rss_kb` (Resident set size) ist **kein** Tool, sondern ein
Stat-Attribut am Upstream — es steckt im Status-Report.

## Routing zur Laufzeit

Eine einzige Route `POST /#name`, registriert **nach** `/all` und `/_hub/*`. Der
Upstream wird pro Request nachgeschlagen; `to_action` hängt am Upstream-Objekt
(`$up->action`) und wird also nur einmal gebaut. Ein unbekannter Name und ein
Server außerhalb des Profils liefern **byte-identisch** dasselbe 404.

Die Setup-Seite (`GET /`) ist eine Inline-JS-Seite: der Login holt das Token per
`fetch` mit Authorization-Header und ersetzt das Dokument.

## Die Stellschrauben

Der `hub`-Block kennt genau: `listen`, `cache_dir`, `idle_timeout`,
`request_timeout`, `profiles`, `clients`, `public_profile`, `auto_reload`. Pro
Server-Eintrag: `idle_timeout`, `always_on`, `request_timeout` und `fork` (im
`hub`-Block des Eintrags; auf einem In-process-`class`-Eintrag sind die drei
ersten ein Fehler, auf einem `url`-Eintrag `idle_timeout`; `fork` gibt es nur auf `class`). Ein Tippfehler in einem Key fällt beim Start auf, z. B.
`mcpServers.playwright.hub.idle_timeout`.

## Test-Hooks

Jede Unit ist allein testbar: `Config` auf Strings, `Manifest` auf temp dir,
`Auth` auf einem Config-Hash, `Façade` auf einem Manifest-Hash mit Mock-Upstream,
`Stdio` gegen `t/upstream/echo.pl` (Perl `MCP::Server::Legacy`, Tools
`echo`/`sleep`/`fail`/`die`/`exit`/`notify` — der einzige Upstream, den die Suite
spawnt; der Server selbst ist die Klasse `t/lib/EchoServer.pm`, die `t/fork.t` als
`class` forkt), die Natives gegen `t/fixtures/claude/projects/`.
