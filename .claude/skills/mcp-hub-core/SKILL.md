---
name: mcp-hub-core
description: Load before editing p5-mcp-hub — the one-process MCP hub, MCP::Server façades over stdio/HTTP/Docker/in-process upstreams, lazy start and idle stop, manifest cache, open-vs-clients auth, the /all aggregate, native Claude-history servers. The mechanics behind them are in mcp-hub-runtime.
user-invocable: false
model: inherit
---

# mcp-hub-core

MCP::Hub ist **ein** Mojolicious-Prozess, der beliebig viele MCP-Server einbettet
(stdio wie context7/playwright, remote HTTP, Docker-Image/Compose-Service, in-process
Perl) und jeden davon jedem Agenten als **eigenen HTTP-Endpunkt** anbietet — jeder
Upstream **einmal pro Maschine** statt einmal pro Agent-Session, **lazy** beim ersten
`tools/call` gestartet und im Idle gestoppt. Slogan: *a lot of MCP for very little RAM*.
Tool-Namen (`mcp__context7__resolve-library-id`) und Permission-Regeln bleiben, weil
jeder Upstream über eine **eigene `MCP::Server`-Instanz** (die Façade) gezeigt wird. `MCP`
0.15 bleibt wie ausgeliefert, bis auf zwei Abweichungen in `MCP::Hub::Endpoint` (Server
schwach gehalten, jeder Call gestreamt); der Hub liefert nur Upstream-Client und Klebstoff.

## Referenzen — briefing lädt nur diese Datei; vor einer Änderung im Bereich lesen

| Änderung an … | lies |
|---|---|
| der Mechanik hinter einer Invariante (Server-Verweigerung, Kinder, Idle-Zeiten, Crash-Loop, Auth-Codes, `/all`-Filter) | `references/invariants.md` — derselbe fette Titel, voller Text |
| `Config.pm`, einem Key, einer Eintragsart, `${VAR}`, `bin/mcp-hub`, `Command/*` | `references/config-cli.md` |
| `reload`, `schedule_reload`, `let_go`, Nachfolgern (`predecessors`), Auth-Tausch | `references/reload.md` |
| Upstream-Typen, Manifest-Cache, Façade, `/all`, Natives (auch ihr JSON-Decoder fürs Binary), Routing, Test-Fixtures | Skill `mcp-hub-runtime` (`.claude/skills/mcp-hub-runtime/`) |

## Vocabulary

| Begriff | Bedeutung |
|---|---|
| **upstream** | Ein eingebetteter Server: `Upstream::Stdio`, `Upstream::Http`, `Upstream::Perl`, `Upstream::Fork`, `Upstream::Docker`, `Upstream::Compose`. Basisklasse `MCP::Hub::Upstream` |
| **engine** | Der Transport **eines** Container-Laufs (`Docker::Stdio` oder `Docker::Http`), je Start neu gebaut; Lifecycle und Crash-Loop bleiben beim Docker-Upstream, seinem Owner |
| **façade** | Die `MCP::Server`-Instanz, die einen Upstream agentenseitig zeigt; `MCP::Hub::Facade->build($upstream, $manifest)` |
| **manifest** | Gecachte `tools`/`prompts`/`resources`-Liste eines Upstreams; erlaubt `tools/list` ohne Prozess |
| **mode** | *open* (keine Tokens, jeder sieht alles) oder *clients* (Bearer → Profil). **Abgeleitet**, nicht deklariert |
| **profile** | Benannter Permission-Satz: `servers`, `tools` allow/deny, `admin` |
| **worker** | Ein aus dem Hub ge`fork`ter Kindprozess **ohne exec** für eine `class` mit `"hub": {"fork": true}` (`Upstream::Fork`) |

## Module map

```
bin/mcp-hub               # globales --config/-c, nur vor dem Command-Namen
lib/MCP/Hub.pm            # die App: startup lädt Config, baut Upstreams, mountet Routen
lib/MCP/Hub/Config.pm     # JSON/YAML laden, validieren, ${VAR}, Defaults, Mode. Reine Daten
lib/MCP/Hub/Auth.pm       # Authorization-Header → client → profile; `under`-Handler, Tool-Filter
lib/MCP/Hub/Manifest.pm   # Manifest-Cache lesen/schreiben, Hash, Freshness
lib/MCP/Hub/Upstream.pm   # Basis: state, server, start_p, stop, let_go, refresh_p, touch, stats
lib/MCP/Hub/Upstream/{Stdio,Http,Perl,Fork,Docker,Compose}.pm  # die Typen (mcp-hub-runtime)
lib/MCP/Hub/Upstream/Docker/{Engine,Stdio,Http}.pm # Engine: vor dem Transport (Owner, Hash, Teardown)
lib/MCP/Hub/Upstream/ErrorAnswer.pm # Rejection für eine JSON-RPC-Error-Antwort; `_answered` erkennt sie
lib/MCP/Hub/Docker.pm     # einziger Weg zum docker-CLI (run_p), Name/Labels, owner_id, Orphans
lib/MCP/Hub/Child.pm      # jedes Kind: fds > 2 zu, Env ohne MOJO_REUSE, Exit per watch_exit
lib/MCP/Hub/Facade.pm     # baut die MCP::Server-Façade aus einem Manifest
lib/MCP/Hub/Facade/Tool.pm   # MCP::Tool-Subklasse: validate_input aus, `extra`-Hash für Rendering
lib/MCP/Hub/Facade/Server.pm # MCP::Server-Subklasse: rendert die `extra`-Felder in tools/list mit
lib/MCP/Hub/Aggregate.pm  # der /all-Server: Union aller Tools mit `<name>__`-Präfix
lib/MCP/Hub/Endpoint.pm   # HTTP-Transport jedes Endpunkts und von /all (die zwei Abweichungen)
lib/MCP/Hub/Native/*.pm   # natives (in-process, ohne Subprozess): ClaudeHistory, ClaudeSessions, Status
lib/MCP/Hub/Help.pm       # die HTML-Setup-Seite an GET / (token-gated in clients mode)
lib/MCP/Hub/Commands.pm   # Mojolicious::Commands-Subklasse: eigene zuerst, prefork/cgi/psgi/hypnotoad/morbo verweigert
lib/MCP/Hub/Command/*.pm  # daemon, config, status, refresh, reload, token
```

## Core invariants — Kurzform; voller Text je Titel in `references/invariants.md`

- **Ein Prozess bedient HTTP und hält allen State — niemals prefork/hypnotoad.** Ein
  zweiter Prozess spawnte eigene Kinder und spaltete den State. `mcp-hub daemon` ist ein
  einzelner `Mojo::Server::Daemon`; `MCP::Hub::Commands` und der `before_server_start`-Hook
  verweigern jeden anderen Server (`Commands::server_refusal`). Kinder sind exec'te
  Upstreams oder geforkte Class-Worker; ein Worker fährt nie die IOLoop des Hubs, hält
  keinen seiner fds oder Signal-Handler und endet mit `_exit` (`Upstream::Fork`,
  `t/fork.t`). Tool-Calls sind non-blocking Promises in der einen IOLoop — nur ein
  In-process-`class`-Tool läuft in ihr und hält den Hub an; seine Antwort geht gestreamt.
- **Kein Kindprozess darf die Loop blockieren.** docker-CLI nur über
  `MCP::Hub::Docker->run_p` (nie `system`/Backticks), jeder Exit über
  `MCP::Hub::Child::watch_exit` (nie ein blockierendes `waitpid`). **Jede Zuweisung an
  `$SIG{CHLD}` im Hub-Prozess, auch eine `local`e, entfernt libevs Handler für immer**;
  `'IGNORE'` macht jeden Exit-Status `unknown`.
- **Lazy start, idle stop — das ist eine Zusage.** `tools/list` kommt aus dem gecachten
  Manifest, ohne Prozess; erst `tools/call`/`prompts/get`/`resources/read` ruft
  `start_p` — nie ein Spawn in `startup` oder beim Config-Load. Idle-Stopp: EOF,
  `SIGTERM` nach `EOF_GRACE`, `SIGKILL` nach `KILL_GRACE`, bis dahin `stopping`; ein
  `list_changed` des stoppenden Kinds startet nichts. Kein Countdown, solange ein Call
  oder Refresh in flight ist (`_held_p`). `always_on` startet eager ohne Idle-Timer.
- **Manifest-Hash geht über `[command, args, cwd]` — nie über `env`.** `env` kann
  Secrets halten; ein veraltetes Manifest kostet nur eine falsche Beschreibung bis zum
  Refresh (kein TTL). Ein neuer Hash-Input invalidiert jeden Cache — bewusst
  entscheiden. HTTP hasht `[url, type]`, docker/compose Image bzw. Projekt plus Angebot
  (`Docker::hash_input`, `Compose::_hash`), nie `docker_command`; `fork` hasht nichts.
- **Die Façade darf `extra` nicht verlieren.** `MCP::Server` rendert nur Spec-Felder;
  `title`, `icons`, `_meta` (z. B. `anthropic/maxResultSizeChars`) hängen an
  `Facade::Tool`, `Facade::Server` mischt sie zurück — auch an `/all` (`Aggregate` ist ein
  `Facade::Server`). Wer eine Hälfte ohne `extra` anfasst, streift Annotationen still ab.
- **`Facade::Tool->validate_input` gibt `0` zurück — mit Absicht.** Der Upstream prüft
  selbst, `JSON::Schema::Tiny` weist `$ref`-lastige Schemata ab; Output nie re-validieren.
- **Tool-Filterung hängt am `tools`-Event und gilt für list UND call.** Verboten heißt
  „not found" (`-32602`). `/all` filtert auch am `prompts`-Event, nach der Herkunft
  (`Aggregate->origin`), **nie** nach dem Namenspräfix (Servernamen dürfen `__` enthalten);
  ohne Profil schließt `/all` in clients mode (`Hub::_aggregate_profile`).
- **Mode wird abgeleitet, nicht deklariert.** `clients` leer → *open* (kein Token,
  Admin-API offen; auch ein `.mcp.json` ohne `hub`-Block); gesetzt → *clients* (Bearer
  nötig, sonst 401; ohne Token greift `public_profile`, falls gesetzt). Tokens
  konstant-zeitig vergleichen (`slow_eq` aus `Crypt::Misc`).
- **404 vs 401 vs 503 tragen Bedeutung** — nie zu einer leeren Tool-Liste zusammenlegen.
  Nicht im Profil → **404** (der Client soll nicht erfahren, dass es ihn gibt). Token
  fehlt/falsch → **401** + `WWW-Authenticate: Bearer`. Kein erstes Manifest oder
  `failed` → **503** mit Grund (`not ready yet` nur bei `starting`). Admin-API ohne
  `admin`-Profil → **403**.
- **`failed` ist sichtbar und klebt bis zum expliziten `refresh`.** Ein nicht baubarer
  Eintrag wird ein Placeholder (`state => 'failed'`, `error`) und bleibt in Status,
  Setup-Seite, `mcp-hub config` und `/all`. 3 Exits, Fehlstarts oder Connect-Fehler in
  5 s → `failed`, ein gescheiterter Fetch ohne Manifest sofort; nur `refresh_p` räumt.
  Ein Stop, der einen Start absagt, ist kein Fehlschlag (`Hub::_called_off`).
- **Die Setup-Seite liest das Token ausschließlich aus `Authorization: Bearer`.** Kein
  `?token=`, kein Form-POST, keine `POST /`-Route. Ohne Token: Formular, nie Servernamen.
- **`/all` ruft die Original-Tool-Objekte direkt** (`$t->call(...)`): alles gilt wie am
  eigenen Endpunkt; Resources werden **nicht** aggregiert.
- **Server-initiierter Verkehr wird terminiert, nicht weitergereicht** (Sampling,
  Elicitation: Non-goal); die Antworten: `mcp-hub-runtime`, „Server-initiierter Verkehr“.
- **Native Module sind `MCP::Server`-Subklassen und laufen auch standalone** (Tools in
  `new`); `Upstream::Perl` injiziert den Hub nur bei `$class->can('hub')`, und
  `Upstream::Fork` verweigert solche Klassen — ein Worker hätte nur eine tote Hub-Kopie.

## Config und CLI — Details in `references/config-cli.md`

Eine Datei, JSON **oder YAML — die Endung entscheidet**; `Config->from_file` ist der
**einzige** Einstieg „Pfad → validierte Config", danach läuft `from_data` — nichts darf
nur in YAML ausdrückbar sein. `--config PATH` (`-c`) gilt global, aber nur **vor** dem
Command-Namen. `mcpServers` ist ein Superset von `.mcp.json`; genau eines von `command`,
`class`, `url`, `docker` oder `compose` je Eintrag. Unbekannte Keys und eine **unset**
`${VAR}` ohne Default sind Fehler — mit JSON-Pfad in der Meldung.

Der `hub`-Block kennt genau: `listen`, `cache_dir`, `idle_timeout`, `request_timeout`,
`profiles`, `clients`, `public_profile`, `auto_reload`, `docker_command`, `docker_network`;
der `hub`-Block eines Eintrags `idle_timeout`, `always_on`, `request_timeout`, `fork`
(wer welche verweigert: Referenz). Tippfehler fallen beim Start auf, z. B.
`mcpServers.playwright.hub.idle_timeout`. CLI: `daemon`, `config`, `status`,
`refresh [NAME]` (der einzige Weg aus `failed`), `reload`, `token`; ohne Hub enden
`status`/`refresh`/`reload` mit Exit 1, nie 0.

## Reload — volle Mechanik in `references/reload.md`

`MCP::Hub->reload` ist **synchron** und der einzige Mechanismus; SIGHUP, `hub.auto_reload`,
`POST /_hub/reload` und `mcp-hub reload` lösen nur aus (`schedule_reload`).

- **Erst vollständig validieren, dann mutieren** — nie halb anwenden, nie den Daemon beenden.
- **Diff pro normalisiertem Eintrag.** Unverändert → **selbes Objekt, selber pid, selbe
  Stats, selber Idle-Timer**; geändert → nur dieser Upstream neu; neu → gewärmt ohne Spawn.
- **Ein ersetzter oder entfernter Upstream wird gehalten, bis sein Stop vorbei ist, und
  wendet nichts mehr an** (`Upstream::_dropped`); ein stdio-/Fork-Nachfolger wartet darauf.
- **profiles/clients/public_profile werden in place getauscht**. **Broken Placeholder
  wird bei jedem Reload neu versucht**. `hub.listen`/`hub.cache_dir`: erst nach Neustart.

## Tests

`prove -lr t/` ist der kanonische Lauf — **rekursiv**, weil `t/native/` und `t/upstream/`
Subdirs sind, die das nackte `prove -l t/` still überspringt; `dzil test` ist das
Release-Äquivalent. Die Suite braucht **weder node noch Netz noch Docker-Daemon** —
Ausnahmen nur opt-in, sonst `skip_all`: `t/npx.t` (`MCP_HUB_TEST_NPX=1`), `t/docker-live.t`
(echter Daemon und `mcp/time`, `MCP_HUB_TEST_DOCKER=1`) — beide auch mit `RELEASE_TESTING`
— und `t/wiki-live.t` (`MCP_HUB_TEST_WIKI=1`).
`t/hub.t` fährt `Test::Mojo` gegen `MCP::Hub` mit temp Config/Cache, getrieben von
`MCP::Client`; Natives gegen `t/fixtures/claude/projects/`. Test-Hooks: `mcp-hub-runtime`.

## Conventions

`Mojo::Base -strict, -signatures` durchgängig — **kein** Moo/Moose (`perl-mojo`).
Ausnahme zu `getty-perl-core` („in einer Klasse ist jeder Helper eine Methode"): ein
Helper ohne `$self` darf ein nackter privater Sub bleiben, wo die Datei das schon so hält
(`_wrap_tool`, `_listed_extra`, `_join_sections` in `Aggregate`, `_merge` in
`Facade::Server`, `_bearer` in `Auth`); neuer Code folgt seiner Datei. POD im
`[@Author::GETTY]`-Stil; `# ABSTRACT:` auf jedem Modul, `# PODNAME:` auf `bin/mcp-hub`.
`.claude/` und `CLAUDE.md` gehen mit ins Tarball (Bundle-Default). Geteilte Skills statt
Wiederholung: Release `getty-perl-release-author-getty`, dist.ini `perl-release-dist-ini`,
MCP-Grundlagen `perl-mcp`, Docker `docker`.
