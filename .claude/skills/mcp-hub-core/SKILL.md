---
name: mcp-hub-core
description: Load before editing p5-mcp-hub — the one-process MCP hub, MCP::Server façades over stdio/HTTP/in-process upstreams, lazy start and idle stop, manifest cache, open-vs-clients auth, the /all aggregate, native Claude-history servers. The mechanics behind them are in mcp-hub-runtime.
user-invocable: false
model: inherit
---

# mcp-hub-core

MCP::Hub ist **ein** Mojolicious-Prozess, der beliebig viele MCP-Server einbettet
(stdio wie context7/playwright, remote HTTP, in-process Perl) und jeden davon jedem
Agenten als **eigenen HTTP-Endpunkt** anbietet — jeder Upstream **einmal pro Maschine**
statt einmal pro Agent-Session, **lazy** beim ersten `tools/call` gestartet und im Idle
gestoppt. Slogan: *a lot of MCP for very little RAM*.

Die agentenseitige Sicht ist unverändert: jeder Upstream behält seine Tool-Namen
(`mcp__context7__resolve-library-id`), bestehende Permission-Regeln greifen weiter. Das
gelingt, weil jeder Upstream über eine **eigene `MCP::Server`-Instanz** (die Façade)
präsentiert wird — Protokoll-, Header-, SSE- und Auth-Schicht bleiben `MCP` 0.15 wie
ausgeliefert; der Hub liefert nur den Upstream-Client und den Klebstoff.

## Vocabulary

| Begriff | Bedeutung |
|---|---|
| **upstream** | Ein eingebetteter Server: `Upstream::Stdio`, `Upstream::Http`, `Upstream::Perl`, `Upstream::Fork` (plus Docker/Compose). Basisklasse `MCP::Hub::Upstream` |
| **façade** | Die `MCP::Server`-Instanz, die einen Upstream agentenseitig repräsentiert; `MCP::Hub::Facade->build($upstream, $manifest)` |
| **manifest** | Gecachte `tools`/`prompts`/`resources`-Liste eines Upstreams; erlaubt `tools/list` ohne laufenden Prozess |
| **mode** | *open* (keine Tokens, jeder sieht alles) oder *clients* (Bearer → Profil). **Abgeleitet**, nicht deklariert |
| **profile** | Benannter Permission-Satz: `servers`, `tools` allow/deny, `admin` |
| **aggregate** | Der `/all`-Endpunkt: Union aller Tools mit `<name>__`-Präfix |
| **native** | In-process `MCP::Server`-Subklasse ohne Subprozess (`Native::ClaudeHistory/ClaudeSessions/Status`) |
| **worker** | Ein aus dem Hub ge`fork`ter Kindprozess **ohne exec**, der eine `class` mit `"hub": {"fork": true}` bedient (`Upstream::Fork`) |

## Module map

```
bin/mcp-hub                     # Mojo::Base -strict -signatures; zieht globales --config/-c
lib/MCP/Hub.pm                  # Die Mojolicious-App: startup lädt Config, baut Upstreams, mountet Routen
lib/MCP/Hub/Config.pm           # JSON/YAML laden, validieren, ${VAR} expandieren, Defaults, Mode ableiten. Reine Daten
lib/MCP/Hub/Auth.pm             # Authorization-Header → client → profile; der `under`-Handler + Tool-Filter
lib/MCP/Hub/Manifest.pm         # Manifest-Cache lesen/schreiben, Hash, Freshness
lib/MCP/Hub/Upstream.pm         # Basisklasse: state, server, start_p, stop, refresh_p, touch, stats
lib/MCP/Hub/Upstream/Stdio.pm   # Kindprozess (fork/exec, Socket-Pair + stderr-Pipe) + Legacy-JSON-RPC-Client
lib/MCP/Hub/Upstream/Http.pm    # Remote-HTTP-Upstream: Streamable HTTP oder HTTP+SSE
lib/MCP/Hub/Upstream/Perl.pm    # `class` einmal instanziieren; die Instanz IST der server oder hat `->server` (Option (a))
lib/MCP/Hub/Upstream/Fork.pm    # `class` + hub.fork: Manifest in-process, Calls in einem geforkten Worker (Stdio-Subklasse)
lib/MCP/Hub/Facade.pm           # baut die MCP::Server-Façade aus einem Manifest
lib/MCP/Hub/Facade/Tool.pm      # MCP::Tool-Subklasse: validate_input aus, `extra`-Hash für Rendering
lib/MCP/Hub/Facade/Server.pm    # MCP::Server-Subklasse: rendert die `extra`-Felder in tools/list mit
lib/MCP/Hub/Aggregate.pm        # der /all-Server
lib/MCP/Hub/Native/*.pm         # ClaudeHistory, ClaudeSessions, Status
lib/MCP/Hub/Help.pm             # die HTML-Setup-Seite an GET / (token-gated in clients mode)
lib/MCP/Hub/Command/*.pm        # daemon, config, status, refresh, reload, token — hinter bin/mcp-hub
```

## Core invariants

- **Ein Prozess bedient HTTP und hält allen State — niemals prefork/hypnotoad.**
  `mcp-hub daemon` ist ein einzelner `Mojo::Server::Daemon`; es gibt bewusst **kein**
  `prefork`-Command. Seine Kindprozesse sind exec'te Upstreams oder geforkte
  Class-Worker. Ein Worker fährt nie die IOLoop des Hubs, hält keinen seiner fds oder
  Signal-Handler und endet mit `_exit` (das Rezept steht in `Upstream::Fork`; `t/fork.t`
  bewacht es). Alles andere (Kinder, Idle-Timer, Manifeste, In-process-Server) lebt in
  der einen IOLoop; Tool-Calls sind non-blocking Promises, damit ein langsamer Upstream
  die anderen nicht blockiert — außer einem In-process-`class`-Eintrag: dessen Tools
  laufen in der Loop, ein langsames hält den ganzen Hub an.
- **Lazy start, idle stop — das ist eine Zusage.** Ein stdio-Upstream mit frischem
  Cache-Manifest startet **nicht** bei Daemon-Start; die Façade kommt aus dem Cache.
  Erst der erste `tools/call`/`prompts/get`/`resources/read` ruft `start_p`; weitere Calls
  während `starting` queuen auf derselben Promise. Jeder Request ruft `touch`; der
  Idle-Timer schließt stdin, `SIGTERM`, nach 5 s `SIGKILL`. `always_on` startet eager
  ohne Idle-Timer. Ein `fork`-Upstream liest sein Manifest beim Build in-process aus
  einer Wegwerf-Instanz (kein Cache, kein Warming) und forkt erst beim ersten Call.
- **Manifest-Hash geht über `[command, args, cwd]` — nie über `env`.** `env` kann
  Secrets halten, ein geänderter Command nutzt nie ein stale Manifest; ein veraltetes
  Manifest kostet nur eine falsche Tool-Beschreibung bis zum Refresh (kein TTL). Ein
  `fork`-Upstream schreibt kein Manifest und hasht nichts (`args` kann Secrets halten).
- **Die Façade darf `extra` nicht verlieren.** `MCP::Server` rendert in `tools/list` nur
  name/description/inputSchema/outputSchema/annotations. `title`, `icons` und `_meta` (z. B.
  `anthropic/maxResultSizeChars`) sind keine Spezifikations-Felder und hängen an
  `Facade::Tool`; wer das `tools/list`-Rendering anfasst, muss sie weiterreichen. Das
  gilt auch für `/all`: `Aggregate` ist ein `Facade::Server` und trägt sie an jedem
  `<u>__<t>`-Tool und -Prompt.
- **`Facade::Tool->validate_input` gibt `0` zurück — mit Absicht.** Der Upstream
  validiert selbst; `JSON::Schema::Tiny` weist manche `$ref`-lastigen Schemata ab. Nicht
  „reparieren"; structured content auch nicht gegen das Output-Schema re-validieren.
- **Tool-Filterung hängt am `tools`-Event und gilt für list UND call.** Ein durch das
  Profil verbotenes Tool ist „not found" (`-32602`), nicht nur unsichtbar. `/all` hängt
  zusätzlich am `prompts`-Event (nur `servers`, keine `tools`-Regel) — sonst listet und
  liefert `/all` Prompts von Servern außerhalb des Profils. Beide `/all`-Filter
  entscheiden nach der Herkunft (`Aggregate->origin`), **nie** nach dem Namenspräfix:
  Servernamen dürfen `__` enthalten (`p` vs. `p__x`).
- **Mode wird abgeleitet, nicht deklariert.** `clients` leer → *open* (kein Token,
  Admin-API offen). `clients` gesetzt → *clients* (Bearer nötig, sonst 401; ohne Token
  greift `public_profile`, falls gesetzt). Ein `.mcp.json` ganz ohne `hub`-Block ist ein
  gültiger open-mode-Config. Tokens werden konstant-zeitig verglichen (`slow_eq` aus
  `Crypt::Misc`).
- **404 vs 401 vs 503 tragen Bedeutung.** Server nicht im Profil → **404** (der Client
  soll nicht erfahren, dass es ihn gibt) — darum zeigt auch `/all` per `server/discover`
  nur die `## <name>`-Instructions der Server im Profil. Fehlendes/falsches Token in clients mode →
  **401** + `WWW-Authenticate: Bearer`. Upstream ohne erstes Manifest oder `failed` →
  **503** mit Grund — `not ready yet` nur, solange der Fetch läuft (`starting`).
  Admin-API ohne `admin`-Profil → **403**.
- **`failed` ist sichtbar und klebt bis zum expliziten `refresh`.** Ein nicht baubarer
  Eintrag (z. B. `class` nicht ladbar) wird nicht verworfen, sondern durch einen
  Placeholder (`state => 'failed'`, `error`) ersetzt — er bleibt in Status, Setup-Seite,
  `mcp-hub config` und `/all`. Ein stdio-Upstream wird nach 3 Exits in 5 s `failed`;
  `start_p` lehnt dann ab, nur `refresh_p` räumt Flag und Exit-Historie. Scheitert der
  Warming-Fetch, der `always_on`-Start oder ein `refresh` eines Upstreams **ohne**
  Manifest, ist er sofort `failed` (`Hub::_fetch_failed` → `Upstream->fail`, dasselbe
  Flag) — kein Retry, nichts versucht es von selbst wieder; mit Manifest gilt weiter die
  Crash-Loop-Regel. Der Warm-up überspringt `failed`.
- **Die Setup-Seite liest das Token ausschließlich aus `Authorization: Bearer`.** Kein
  `?token=`, kein Form-POST, keine `POST /`-Route; das Login-Formular ist Inline-JS.
  Ohne gültiges Token rendert clients mode nur das Formular — nie Servernamen.
- **`/all` ruft die Original-Tool-Objekte direkt.** Sein Tool `<u>__<t>` ruft
  `$t->call(...)` auf, so gelten Façade-Fehlerbehandlung, Filter und In-process-Server
  genauso wie am eigenen Endpunkt; Resources werden **nicht** aggregiert.
- **Server-initiierter Verkehr wird terminiert, nicht weitergereicht.** Sampling und
  Elicitation weiterzuleiten ist ein Non-goal; die Antworten stehen in `mcp-hub-runtime`.
- **Native Module sind `MCP::Server`-Subklassen und laufen auch standalone** (Tools in
  `new`); `Upstream::Perl` injiziert die Hub-Instanz nur bei `$class->can('hub')`.
  `Upstream::Fork` verweigert genau solche Klassen — ein Worker hätte nur eine tote
  Kopie des Hubs.

## Config

Eine Datei, JSON **oder YAML — die Endung entscheidet** (`.yml`/`.yaml` → `YAML::PP`,
lazy geladen, ein Dokument, keine Duplikat-Keys; alles andere → JSON). `--config PATH`
gilt global für alle Kommandos, sonst `$MCP_HUB_CONFIG`, sonst in `~/.config/mcp-hub/`
das erste existierende von `config.json`, `config.yml`, `config.yaml`. YAML ist nur
eine zweite Schreibweise: `Config->from_file` ist der **einzige** Einstieg „Pfad →
validierte Config", danach läuft dieselbe `from_data`-Validierung — nichts darf nur in
YAML ausdrückbar sein.

`mcpServers` ist ein Superset von `.mcp.json` (Einträge 1:1). Genau eines von `command`,
`class`, `url`, `docker` oder `compose` je Eintrag (ein `compose`-Eintrag darf zusätzlich
`url` tragen — wo der Service antwortet) — bei `class` ist `args` ein Objekt
(`class_args`), sonst eine Liste. Ein `class`-Eintrag verweigert `env`, `cwd`, `headers` und `type` (er nimmt
alles über `args`); `hub.idle_timeout`/`request_timeout`/`always_on` gelten nur mit
`"hub": {"fork": true}` (→ `type: 'fork'`), und `hub.fork` nur auf einem `class`-Eintrag. Ein
`command`-Eintrag verweigert `headers` und jedes `type` außer `stdio` (das Claude Code in
`.mcp.json` schreibt), ein `url`-Eintrag `env`, `cwd`, `args` und `hub.idle_timeout`. Ein Profil hat `servers` (Array, Default `['*']`), `tools`
(`{server: {allow: [...], deny: [...]}}`) und `admin`; ein Client hat `token` und
`profile` (beide Pflicht). Die Schlüsselliste des `hub`-Blocks steht in `mcp-hub-runtime`.

`${VAR}` und `${VAR:-default}` werden in `command`, jedem `args`-Element, jedem
`env`-Wert, `cwd`, `url`, jedem `headers`-Wert sowie im `hub`-Block in `listen`,
`cache_dir` und jedem Client-`token` expandiert — eine **unset** Variable ohne Default
ist ein Config-Fehler (strenger als Claude Code, das den Literal behält). Server-Namen
matchen `^[A-Za-z0-9][A-Za-z0-9_-]*$`; `all` und führendes `_` sind reserviert.
Unbekannte Keys sind ein Fehler — mit JSON-Pfad in der Meldung.

## CLI (`bin/mcp-hub`)

`daemon` (Vordergrund, single daemon), `config [--client NAME] [--all] [--url BASE]`
(druckt `{"mcpServers": …}`; in clients mode ist `--client` nötig und fügt den Bearer
hinzu), `status` (ruft `GET /_hub/status`), `refresh [NAME]` (`POST /_hub/refresh`; auch
der einzige Weg aus `failed`), `reload` (`POST /_hub/reload`, druckt die Diff-Summary,
Exit ≠ 0 bei abgelehnter Config), `token` (32 Zufallsbytes base64url, fasst die Config
nie an). `status`/`refresh`/`reload` nehmen `--client NAME` und `--url BASE`.

## Reload

`MCP::Hub->reload` ist **synchron** und der einzige Mechanismus; SIGHUP (nur im
`daemon`-Command; `EV::signal` unter EV, sonst `%SIG`), `hub.auto_reload` (Poll per
Pfad-`stat`, Intervall = Hub-Attribut `auto_reload_interval`), `POST /_hub/reload` und
`mcp-hub reload` sind nur Auslöser, gebündelt über `schedule_reload`. Regeln:

- **Erst vollständig validieren, dann mutieren.** Ungültige Datei → nichts ändert sich,
  Fehler geloggt und zurückgegeben. Nie halb anwenden, nie den Daemon beenden.
- **Diff pro normalisiertem Eintrag.** Unverändert → **selbes Objekt, selber pid, selbe
  Stats, selber Idle-Timer** (`t/reload.t` prüft `refaddr`); nur Timeouts →
  `apply_timeouts` in place. Geändert → nur dieser Upstream neu, Entfernt → `stop` + 404.
  Neu → gewärmt wie beim Daemon-Start, d. h. mit gecachtem Manifest **kein Spawn**.
- **profiles/clients/public_profile werden in place getauscht** (`auth->config($new)`);
  `Auth::last_seen` lebt auf `Auth`, nicht auf der Config, dann `notify_list_changed`.
  `/all` bekommt `tools/` **und** `prompts/list_changed`, sobald ein Eintrag added/
  removed/changed ist oder die Access-Regeln sich bewegt haben (`t/reload.t` hört per
  `subscriptions/listen` mit).
- **Broken Placeholder wird bei jedem Reload neu versucht**; ein crash-gelooptes stdio-
  `failed` oder ein gescheiterter erster Fetch nicht — dort bleibt `refresh` der Weg zurück.
- `hub.listen`/`hub.cache_dir` sind nicht live anwendbar → Warnung in der Summary; der
  Config-Pfad wird beim Start festgehalten, der Default-Lookup läuft nur einmal.

## Tests

`prove -lr t/` ist der kanonische Lauf — **rekursiv**, weil `t/native/` und `t/upstream/`
Subdirs sind, die das nackte `prove -l t/` still überspringt. `dzil test` ist das
Release-Äquivalent. Die Suite braucht **weder node noch Netz** — eine Ausnahme:
`t/npx.t` fährt einen echten npx-Server, aber nur mit `MCP_HUB_TEST_NPX=1` oder unter
`RELEASE_TESTING`, sonst `skip_all`. `t/hub.t` fährt `Test::Mojo` gegen `MCP::Hub` mit
temp Config/Cache, getrieben von `MCP::Client`; die Natives laufen gegen
`t/fixtures/claude/projects/`.

## Conventions

`Mojo::Base -strict, -signatures` durchgängig — **kein** Moo/Moose in dieser Distribution
(`perl-mojo`). POD folgt der Deklaration im `[@Author::GETTY]`-Stil; `# ABSTRACT:` auf
jedem Modul, `# PODNAME:` auf `bin/mcp-hub`. `.claude/` und `CLAUDE.md` gehen mit ins
Tarball (Bundle-Default). Geteilte Skills statt Wiederholung: Release `getty-perl-release-author-getty`,
dist.ini `perl-release-dist-ini`, MCP-Grundlagen `perl-mcp`, Docker `docker`.
