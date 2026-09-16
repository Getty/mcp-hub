---
name: mcp-hub-core
description: Load before editing p5-mcp-hub — the one-process MCP hub, MCP::Server façades over stdio/HTTP/in-process upstreams, lazy start & idle stop, manifest cache, open-vs-clients auth, the /all aggregate, native Claude-history servers.
user-invocable: false
model: inherit
---

# mcp-hub-core

MCP::Hub ist **ein** Mojolicious-Prozess, der beliebig viele MCP-Server einbettet
(stdio wie context7/playwright, remote HTTP, in-process Perl) und jeden davon jedem
Agenten auf der Maschine als **eigenen HTTP-Endpunkt** anbietet. Kernidee: jeden
Upstream **einmal pro Maschine** statt einmal pro Agent-Session laufen lassen, **lazy**
beim ersten `tools/call` starten und im Idle wieder stoppen. Slogan: *a lot of MCP for
very little RAM*.

Die agentenseitige Sicht ist unverändert: jeder Upstream behält seine Tool-Namen
(`mcp__context7__resolve-library-id` bleibt gleich), bestehende Permission-Regeln greifen
weiter. Das gelingt, weil jeder Upstream über eine **eigene `MCP::Server`-Instanz**
(die Façade) präsentiert wird — die agentenseitige Protokoll-, Header-, SSE- und
Auth-Schicht ist `MCP` 0.15 wie ausgeliefert; der Hub liefert nur den Upstream-Client
und den Klebstoff. (Design-Alternativen B/C in `docs/superpowers/specs/`.)

## Vocabulary

| Begriff | Bedeutung |
|---|---|
| **upstream** | Ein eingebetteter Server: `Upstream::Stdio`, `Upstream::Http`, `Upstream::Perl`. Basisklasse `MCP::Hub::Upstream` |
| **façade** | Die `MCP::Server`-Instanz, die einen Upstream agentenseitig repräsentiert; `MCP::Hub::Facade->build($upstream, $manifest)` |
| **manifest** | Gecachte `tools`/`prompts`/`resources`-Liste eines Upstreams; erlaubt `tools/list` ohne laufenden Prozess |
| **mode** | *open* (keine Tokens, jeder sieht alles) oder *clients* (Bearer → Profil). **Abgeleitet**, nicht deklariert |
| **profile** | Benannter Permission-Satz: `servers`, `tools` allow/deny, `admin` |
| **aggregate** | Der `/all`-Endpunkt: Union aller Tools mit `<name>__`-Präfix |
| **native** | In-process `MCP::Server`-Subklasse ohne Subprozess (`Native::ClaudeHistory/ClaudeSessions/Status`) |

## Module map

```
bin/mcp-hub                     # Mojo::Base -strict -signatures; zieht globales --config/-c
lib/MCP/Hub.pm                  # Die Mojolicious-App: startup lädt Config, baut Upstreams, mountet Routen
lib/MCP/Hub/Config.pm           # JSON laden, validieren, ${VAR} expandieren, Defaults, Mode ableiten. Reine Daten
lib/MCP/Hub/Auth.pm             # Authorization-Header → client → profile; der `under`-Handler + Tool-Filter
lib/MCP/Hub/Manifest.pm         # Manifest-Cache lesen/schreiben, Hash, Freshness
lib/MCP/Hub/Upstream.pm         # Basisklasse: state, server, start_p, stop, refresh_p, touch, stats
lib/MCP/Hub/Upstream/Stdio.pm   # Kindprozess (fork/exec, 3 pipes) + Legacy-JSON-RPC-Client
lib/MCP/Hub/Upstream/Http.pm    # Remote-HTTP-Upstream: Streamable HTTP oder HTTP+SSE
lib/MCP/Hub/Upstream/Perl.pm    # `class` einmal instanziieren; die Instanz IST der server
lib/MCP/Hub/Facade.pm           # baut die MCP::Server-Façade aus einem Manifest
lib/MCP/Hub/Facade/Tool.pm      # MCP::Tool-Subklasse: validate_input aus, `extra`-Hash für Rendering
lib/MCP/Hub/Facade/Server.pm    # MCP::Server-Subklasse: rendert die `extra`-Felder in tools/list mit
lib/MCP/Hub/Aggregate.pm        # der /all-Server
lib/MCP/Hub/Native/*.pm         # ClaudeHistory, ClaudeSessions, Status
lib/MCP/Hub/Command/*.pm        # daemon, config, status, refresh, token — hinter bin/mcp-hub
```

Jede Unit ist allein testbar: `Config` auf Strings, `Manifest` auf temp dir, `Auth` auf
einem Config-Hash, `Façade` auf einem Manifest-Hash mit Mock-Upstream, `Stdio` gegen
`t/upstream/echo.pl`, die Natives gegen Fixtures.

## Core invariants

- **Ein Prozess, niemals prefork/hypnotoad.** `mcp-hub daemon` ist ein einzelner
  `Mojo::Server::Daemon`. Jeder Worker würde eigene Kinder spawnen und eigenen State
  halten — das killt den ganzen Zweck. Es gibt bewusst **kein** `prefork`-Command.
  Alles (Kinder, Idle-Timer, Manifeste, In-process-Server) lebt in dieser einen IOLoop.
  Tool-Calls sind non-blocking Promises, damit ein langsamer Upstream die anderen nicht
  blockiert.
- **Lazy start, idle stop — das ist eine Zusage.** Ein stdio-Upstream mit frischem
  Cache-Manifest startet **nicht** bei Daemon-Start; die Façade kommt aus dem Cache,
  `tools/list` wird ohne Prozess beantwortet. Erst der erste `tools/call`/`prompts/get`/
  `resources/read` ruft `start_p`; weitere Calls während `starting` queuen auf derselben
  Promise. Jeder Request ruft `touch`; der Idle-Timer schließt stdin, `SIGTERM`, nach
  5 s `SIGKILL`. `always_on` startet eager und hat keinen Idle-Timer.
- **Manifest-Hash geht über `[command, args, cwd]` — nie über `env`.** `env` kann
  Secrets halten. Ein geänderter Command nutzt daher nie ein stale Manifest. Kein TTL:
  ein veraltetes Manifest kostet eine falsche Tool-Beschreibung bis zum nächsten
  Refresh, und Refresh ist billig. Writes sind atomar (temp + rename). HTTP-Upstreams
  hashen über `[url, type]`.
- **Die Façade erhält `extra`-Felder, sonst gehen sie verloren.** `MCP::Server` rendert
  in `tools/list` nur name/description/inputSchema/outputSchema/annotations. Claude-Code-
  spezifische Felder (`title`, `icons`, `_meta` wie `anthropic/maxResultSizeChars`,
  `anthropic/requiresUserInteraction`) hängen als `extra` an `Facade::Tool`, und
  `Facade::Server` überschreibt das Rendering, um sie zurückzumischen. Wer das Rendering
  anfasst, muss `extra` weiterreichen.
- **`Facade::Tool->validate_input` gibt `0` zurück — mit Absicht.** Der Upstream
  validiert selbst; `JSON::Schema::Tiny` weist manche `$ref`-lastigen Schemata ab. Nicht
  „reparieren". Ergebnisse (`content`, `isError`, `structuredContent`) werden unverändert
  durchgereicht, structured content **nicht** gegen das Output-Schema re-validiert — der
  Upstream wird vertraut.
- **Tool-Filterung hängt am `tools`-Event und gilt für list UND call.** Ein durch das
  Profil verbotenes Tool ist „not found" (`-32602`), nicht nur unsichtbar. Der Filter
  ist ein Handler auf dem `tools`-Event jedes gemounteten `MCP::Server`.
- **Mode wird abgeleitet, nicht deklariert.** `clients` leer → *open* (kein Token,
  Admin-API offen). `clients` gesetzt → *clients* (Bearer nötig, sonst 401; ohne Token
  greift `public_profile`, falls gesetzt). Ein `.mcp.json` ganz ohne `hub`-Block ist ein
  gültiger open-mode-Config. Tokens werden konstant-zeitig verglichen (`slow_eq` aus
  `Crypt::Misc`).
- **404 vs 401 vs 503 tragen Bedeutung.** Server nicht im Profil → **404** (der Client
  soll nicht erfahren, dass es ihn gibt). Fehlendes/falsches Token in clients mode →
  **401** + `WWW-Authenticate: Bearer`. Upstream, der sein erstes Manifest noch holt
  oder `failed` ist → **503** `{"error": …}` (damit `claude mcp list` den Fehler zeigt
  statt eines Servers mit null Tools). Nicht zu „leere Tool-Liste" verwässern.
- **`/all` ruft die Original-Tool-Objekte direkt.** Für jeden Upstream `u` und Tool `t`
  registriert das Aggregate `<u>__<t>`, dessen `code` `$t->call(...)` aufruft — so gelten
  Façade-Fehlerbehandlung, Filter und In-process-Server genauso wie am eigenen Endpunkt.
  Resources werden **nicht** aggregiert (opake URIs würden kollidieren).
- **Server-initiierter Verkehr wird terminiert, nicht weitergereicht.** `ping`→`{}`,
  `roots/list`→`{roots:[]}`, `sampling/createMessage`/`elicitation/create`/alles andere
  mit `id`→Error `-32601`. `notifications/tools/list_changed` → Manifest stale, `refresh_p`
  im Hintergrund. Sampling/Elicitation an den Agenten zu forwarden ist ein Non-goal.
- **Native Module sind `MCP::Server`-Subklassen, die auch standalone laufen.** Sie
  registrieren ihre Tools in `new`, also funktioniert `->to_stdio` außerhalb des Hubs.
  `Upstream::Perl` injiziert die `MCP::Hub`-Instanz nur, wenn `$class->can('hub')`.

## Upstream-Typen

- **Stdio** — `fork`/`exec` mit 3 pipes, kein CPAN-Dependency fürs Prozess-Handling.
  Legacy-Handshake (`initialize` mit `2025-06-18`, akzeptiert was der Server antwortet →
  `notifications/initialized` → `tools/list` mit Cursor-Pagination). stdout wird auf
  Newlines gesplittet, jede Zeile als JSON dekodiert; Line-Buffer bei 16 MB gekappt,
  Kind sonst gekillt. `prompts/list`/`resources/list` nur wenn die Capabilities es
  deklarieren; `-32601` toleriert. 3 Exits binnen 5 s → `failed`.
- **Http** — Remote-MCP über `Mojo::UserAgent`. `type: "http"` = Streamable HTTP
  (Antwort auf dem POST), `type: "sse"` = HTTP+SSE (langlebiger GET-Stream, eigener UA
  ohne Timeout, damit der POST-Timeout ihn nicht kappt). `headers` fürs Auth.
- **Perl** — lädt `class` via `Mojo::Loader`, `new(%$args)` (+`hub` wenn möglich),
  Instanz ist der `server`. State immer `ready`; `stop`/`refresh_p` sind No-ops; kein
  Manifest (die Instanz beantwortet `tools/list` selbst).

## Config

Eine JSON-Datei: `--config PATH`, sonst `$MCP_HUB_CONFIG`, sonst
`~/.config/mcp-hub/config.json`. `mcpServers` ist ein Superset von `.mcp.json` (Einträge
1:1). Genau eines von `command` oder `class` je Eintrag. `${VAR}` und `${VAR:-default}`
werden in `command`, jedem `args`-Element, jedem `env`-Wert und `cwd` expandiert — eine
** unset** Variable ohne Default ist ein Config-Fehler beim Laden (strenger als Claude
Code, das den Literal behält). Server-Namen matchen `^[A-Za-z0-9][A-Za-z0-9_-]*$`; `all`
und führendes `_` sind reserviert. Unbekannte Keys in einem Eintrag sind ein Fehler —
Tippfehler tauchen beim Start auf, mit JSON-Pfad in der Meldung
(`mcpServers.playwright.hub.idle_timeout`).

## CLI (`bin/mcp-hub`)

`daemon` (Vordergrund, single daemon), `config [--client NAME] [--all] [--url BASE]`
(druckt `{"mcpServers": …}`; in clients mode ist `--client` nötig und fügt den Bearer
hinzu), `status` (ruft `GET /_hub/status`), `refresh [NAME]` (`POST /_hub/refresh`),
`token` (32 Zufallsbytes base64url, fasst die Config nie an). `--config`/`MCP_HUB_CONFIG`
gelten für alle.

## Natives — Claude-History

`Native::ClaudeHistory` liest `$CLAUDE_CONFIG_DIR` bzw. `~/.claude`, Unterordner
`projects/`; Tools `list_projects`, `list_sessions`, `search_conversations`,
`get_conversation` (Substring-Suche, kein Volltext-Index in v1 — streamt und filtert).
`Native::ClaudeSessions` findet laufende `claude`-Prozesse über `/proc/*/comm` (+`cwd`);
**Linux-only**, andernorts Error-Result. `Native::Status` liefert `hub_status`/`hub_refresh`
(letzteres braucht `admin`), `rss_kb` aus `/proc/<pid>/status`.

## Tests

`prove -lr t/` ist der kanonische Lauf — **rekursiv**, weil `t/native/` und `t/upstream/`
Subdirs sind, die das nackte `prove -l t/` still überspringt. `dzil test` ist das
Release-Äquivalent. `t/upstream/echo.pl` ist der einzige Upstream, den die Suite spawnt
(Perl `MCP::Server::Legacy`, Tools `echo`/`sleep`/`fail`/`die`/`exit`/`notify`) — **kein
node, kein Netz**. `t/hub.t` fährt `Test::Mojo` gegen `MCP::Hub` mit temp Config/Cache,
getrieben von `MCP::Client`. Die Natives laufen gegen `t/fixtures/claude/projects/`.

## Conventions

`Mojo::Base -strict, -signatures` durchgängig — **kein** Moo/Moose in dieser Distribution
(`perl-mojo`). POD folgt der Deklaration im `[@Author::GETTY]`-Stil; `# ABSTRACT:` auf
jedem Modul, `# PODNAME:` auf `bin/mcp-hub`. `.claude/` ist via `[PruneFiles]` aus dem
Tarball. Release-Mechanik: skill `getty-perl-release-author-getty`. dist.ini:
`perl-release-dist-ini`. MCP-Server-Grundlagen: `perl-mcp`. Docker-Distribution:
`docker`.
