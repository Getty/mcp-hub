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

Die agentenseitige Sicht ist unverändert: jeder Upstream behält seine Tool-Namen
(`mcp__context7__resolve-library-id`), bestehende Permission-Regeln greifen weiter. Das
gelingt, weil jeder Upstream über eine **eigene `MCP::Server`-Instanz** (die Façade)
präsentiert wird — Protokoll-, Header-, SSE- und Auth-Schicht bleiben `MCP` 0.15 wie
ausgeliefert, bis auf zwei Abweichungen im HTTP-Transport jedes Endpunkts
(`MCP::Hub::Endpoint`: Server schwach gehalten, jeder Call gestreamt); der Hub liefert
nur den Upstream-Client und den Klebstoff.

## Vocabulary

| Begriff | Bedeutung |
|---|---|
| **upstream** | Ein eingebetteter Server: `Upstream::Stdio`, `Upstream::Http`, `Upstream::Perl`, `Upstream::Fork`, `Upstream::Docker`, `Upstream::Compose`. Basisklasse `MCP::Hub::Upstream` |
| **engine** | Der Transport **eines** Container-Laufs (`Docker::Stdio` oder `Docker::Http`), bei jedem Start neu gebaut; Lifecycle und Crash-Loop bleiben beim Docker-Upstream, seinem Owner |
| **façade** | Die `MCP::Server`-Instanz, die einen Upstream agentenseitig repräsentiert; `MCP::Hub::Facade->build($upstream, $manifest)` |
| **manifest** | Gecachte `tools`/`prompts`/`resources`-Liste eines Upstreams; erlaubt `tools/list` ohne laufenden Prozess |
| **mode** | *open* (keine Tokens, jeder sieht alles) oder *clients* (Bearer → Profil). **Abgeleitet**, nicht deklariert |
| **profile** | Benannter Permission-Satz: `servers`, `tools` allow/deny, `admin` |
| **aggregate** | Der `/all`-Endpunkt: Union aller Tools mit `<name>__`-Präfix |
| **native** | In-process `MCP::Server`-Subklasse ohne Subprozess (`Native::ClaudeHistory/ClaudeSessions/Status`) |
| **worker** | Ein aus dem Hub ge`fork`ter Kindprozess **ohne exec**, der eine `class` mit `"hub": {"fork": true}` bedient (`Upstream::Fork`) |

## Module map

```
bin/mcp-hub                     # Mojo::Base -strict -signatures; zieht globales --config/-c (nur vor dem Command-Namen)
lib/MCP/Hub.pm                  # Die Mojolicious-App: startup lädt Config, baut Upstreams, mountet Routen
lib/MCP/Hub/Config.pm           # JSON/YAML laden, validieren, ${VAR} expandieren, Defaults, Mode ableiten. Reine Daten
lib/MCP/Hub/Auth.pm             # Authorization-Header → client → profile; der `under`-Handler + Tool-Filter
lib/MCP/Hub/Manifest.pm         # Manifest-Cache lesen/schreiben, Hash, Freshness
lib/MCP/Hub/Upstream.pm         # Basisklasse: state, server, start_p, stop, let_go, refresh_p, touch, stats
lib/MCP/Hub/Upstream/Stdio.pm   # Kindprozess (fork/exec, Socket-Pair + stderr-Pipe) + Legacy-JSON-RPC-Client
lib/MCP/Hub/Upstream/Http.pm    # Remote-HTTP-Upstream: Streamable HTTP oder HTTP+SSE
lib/MCP/Hub/Upstream/Perl.pm    # `class` einmal instanziieren; die Instanz IST der server oder hat `->server` (Option (a))
lib/MCP/Hub/Upstream/Fork.pm    # `class` + hub.fork: Manifest in-process, Calls in einem geforkten Worker (Stdio-Subklasse)
lib/MCP/Hub/Upstream/Docker.pm  # Image als Upstream: pro Start stdio oder HTTP, Readiness, Crash-Loop, Container-Cleanup
lib/MCP/Hub/Upstream/Compose.pm # ein Service eines Compose-Projekts; Docker-Subklasse, nur die Kommandos anders
lib/MCP/Hub/Upstream/Docker/Engine.pm      # was beide Engines vor ihren Transport legen (Owner, Hash, Teardown)
lib/MCP/Hub/Upstream/Docker/{Stdio,Http}.pm # die Engines: Stdio- bzw. Http-Transport eines Container-Laufs
lib/MCP/Hub/Upstream/ErrorAnswer.pm        # Rejection für eine JSON-RPC-Error-Antwort; liest sich wie der String, `_answered` erkennt sie
lib/MCP/Hub/Docker.pm           # der einzige Weg zum docker-CLI (run_p), Name/Labels, owner_id, hash_input, Orphan-Cleanup
lib/MCP/Hub/Child.pm            # jedes Kind: fds > 2 zu, Env ohne MOJO_REUSE, Exit per watch_exit
lib/MCP/Hub/Facade.pm           # baut die MCP::Server-Façade aus einem Manifest
lib/MCP/Hub/Facade/Tool.pm      # MCP::Tool-Subklasse: validate_input aus, `extra`-Hash für Rendering
lib/MCP/Hub/Facade/Server.pm    # MCP::Server-Subklasse: rendert die `extra`-Felder in tools/list mit
lib/MCP/Hub/Aggregate.pm        # der /all-Server
lib/MCP/Hub/Endpoint.pm         # HTTP-Transport jedes Endpunkts und von /all: hält den Server schwach, streamt jeden Call
lib/MCP/Hub/Native/*.pm         # ClaudeHistory, ClaudeSessions, Status
lib/MCP/Hub/Help.pm             # die HTML-Setup-Seite an GET / (token-gated in clients mode)
lib/MCP/Hub/Commands.pm         # Mojolicious::Commands-Subklasse: eigene Commands zuerst, prefork/cgi/psgi/hypnotoad/morbo verweigert
lib/MCP/Hub/Command/*.pm        # daemon, config, status, refresh, reload, token — hinter bin/mcp-hub
```

## Core invariants

- **Ein Prozess bedient HTTP und hält allen State — niemals prefork/hypnotoad.**
  `mcp-hub daemon` ist ein einzelner `Mojo::Server::Daemon`; `MCP::Hub::Commands`
  verweigert `prefork`, `cgi` und `psgi` — auch per Env-Detection (`PLACK_ENV`,
  `PATH_INFO`/`GATEWAY_INTERFACE`) — und das Laden unter hypnotoad, jeweils mit Grund und
  Verweis auf `daemon`. Was nie durch `Commands::run` kommt (ein eigenes Skript reicht die
  App einem Server), fängt der `before_server_start`-Hook in `MCP::Hub::startup`: jeder
  Server, der nicht genau `Mojo::Server::Daemon` ist — Prefork/hypnotoad, CGI, PSGI,
  Daemon-Subklassen —, stirbt dort mit derselben Meldung (`Commands::server_refusal`),
  bevor er lauscht oder forkt; ebenso morbos Worker, ein nackter Daemon, erkannt an
  `$INC{'Mojo/Server/Morbo.pm'}`. Die Kindprozesse des Hubs sind exec'te Upstreams oder
  geforkte Class-Worker. Ein Worker fährt nie die IOLoop des Hubs, hält keinen seiner fds
  oder Signal-Handler und endet mit `_exit` (das Rezept steht in `Upstream::Fork`; `t/fork.t`
  bewacht es). Alles andere (Kinder, Idle-Timer, Manifeste, In-process-Server) lebt in
  der einen IOLoop; Tool-Calls sind non-blocking Promises, damit ein langsamer Upstream
  die anderen nicht blockiert — außer einem In-process-`class`-Eintrag: dessen Tools
  laufen in der Loop, ein langsames hält den ganzen Hub an. Seine Antwort geht trotzdem
  gestreamt hinaus (`Endpoint::_handle` reicht sie als Promise weiter); direkt gerendert
  verlor ein Call, der die Loop länger als den Inactivity-Timeout (30 s) hielt, unter EV
  seine Antwort.
- **Kein Kindprozess darf die Loop blockieren.** Der docker-CLI läuft nur über
  `MCP::Hub::Docker->run_p` (fork/exec, nie `system`/Backticks), jeder Kind-Exit kommt
  über `MCP::Hub::Child::watch_exit` (nie ein blockierendes `waitpid`). Unter EV reapt
  libev jedes Kind selbst; **jede Zuweisung an `$SIG{CHLD}` im Hub-Prozess, auch eine
  `local`e, entfernt libevs Handler für immer** (danach nur noch Polling), `'IGNORE'`
  macht jeden Exit-Status `unknown`.
- **Lazy start, idle stop — das ist eine Zusage.** Ein stdio-, docker- oder
  compose-Upstream mit frischem Cache-Manifest startet **nicht** bei Daemon-Start; die
  Façade kommt aus dem Cache. Erst der erste
  `tools/call`/`prompts/get`/`resources/read` ruft `start_p`; weitere Calls
  während `starting` queuen auf derselben Promise. Jeder Request ruft `touch`; der
  Idle-Stopp schickt einem Kind erst EOF auf stdin, `SIGTERM` erst nach 2 s
  (`EOF_GRACE`), `SIGKILL` 5 s danach (`KILL_GRACE`); bis es weg ist, steht der
  Upstream auf `stopping`. Ein `list_changed` dieses Kinds startet nichts — sonst
  spawnte jeder Idle-Stopp ein Kind, nach dem kein Call gefragt hat. Calls und der Refresh
  eines laufenden Upstreams sind in flight (`_held_p`): kein Countdown, solange einer
  läuft. Der Countdown zählt ab der letzten Nutzung (`touch`: Call oder Start,
  `{used_at}` auf `steady_time`); ein Refresh ist keine — er hält ihn nur an, danach
  läuft der Rest weiter, und war `idle_timeout` schon um, stoppt er sofort. Sonst hielte
  sich ein Kind, das öfter als `idle_timeout` `list_changed` schickt, ewig am Leben;
  `last_used` bleibt der letzte Call. `always_on` startet eager
  ohne Idle-Timer. Ein `fork`-Upstream liest sein Manifest beim Build in-process aus
  einer Wegwerf-Instanz (kein Cache, kein Warming) und forkt erst beim ersten Call.
- **Manifest-Hash geht über `[command, args, cwd]` — nie über `env`.** `env` kann
  Secrets halten, ein geänderter Command nutzt nie ein stale Manifest; ein veraltetes
  Manifest kostet nur eine falsche Tool-Beschreibung bis zum Refresh (kein TTL). HTTP
  hasht `[url, type]`, docker und compose Image bzw. Projekt plus was das Angebot formt
  (`Docker::hash_input`, `Compose::_hash`) — auch dort nie `env`, nie `docker_command`.
  Ein `fork`-Upstream schreibt kein Manifest und hasht nichts (`args` kann Secrets halten).
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
  Servernamen dürfen `__` enthalten (`p` vs. `p__x`). Ohne Profil im Stash (kein
  Controller, ein Weg an der Auth-Bridge vorbei) schließt `/all` in clients mode — keine
  Tools, Prompts und Instructions, `tools/call` not found —, open mode zeigt alles
  (`Hub::_aggregate_profile`).
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
  `mcp-hub config` und `/all`. Ein stdio-Upstream wird nach 3 Exits in 5 s `failed` (auch
  der Kill eines Kinds, das eine Zeile über 16 MB schreibt, ist so ein Exit), ein
  docker/compose-Upstream nach 3 gescheiterten Starts oder Crashes in 5 s (über alle
  Container-Läufe gezählt, nie von der Engine), ein HTTP-Upstream nach 3 Connect-Fehlern
  in 5 s;
  `start_p` lehnt dann ab, nur `refresh_p` räumt Flag und Exit-Historie. Scheitert der
  Warming-Fetch, der `always_on`-Start oder ein `refresh` eines Upstreams **ohne**
  Manifest, ist er sofort `failed` (`Hub::_fetch_failed` → `Upstream->fail`, dasselbe
  Flag) — kein Retry, nichts versucht es von selbst wieder; mit Manifest gilt weiter die
  Crash-Loop-Regel. Sagt ein Stop den Warming-Fetch, den `always_on`-Start oder einen
  `refresh` ab (ein Reload ersetzt oder entfernt den Upstream, der Shutdown), ist das kein
  Fehlschlag: kein error-Log, kein `failed`, der Upstream bleibt `stopped`
  (`Hub::_called_off`, in `_warm_upstream` wie in `refresh_p`). Der Warm-up überspringt
  `failed`.
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
(`-c`) gilt global für alle Kommandos, aber nur **vor** dem Command-Namen — danach
gehört `-c` dem Command (`get -c` ist der Body, `daemon -c` das Client-Limit); sonst
`$MCP_HUB_CONFIG`, sonst in `~/.config/mcp-hub/`
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
`.mcp.json` schreibt), ein `url`-Eintrag `env`, `cwd`, `args` und `hub.idle_timeout`. Ein
`docker`-/`compose`-Eintrag verweigert jeden Key außerhalb seines `%CONTAINER_KEYS`
(docker ohne `cwd`; compose ohne `args`, `cwd`, `volumes`, `docker_args`), und dessen
Container-Keys (`service`, `stdio`, `port`, `path`, `volumes`, `docker_args`) sind auf
jedem anderen Eintrag ein Fehler. Auf einem Container-Eintrag ist `type` die
HTTP-Variante (`http`/`sse`, normalisiert als `transport`; `type` wird die Art
`docker`/`compose`); `"stdio": true` schließt `port`/`path`/`type`/`headers`/`url` aus,
`url` (nur compose) `port`; `env`-Keys müssen Variablennamen sein (jeder wird ein
nacktes `-e KEY`). Ein Profil hat `servers` (Array, Default `['*']`), `tools`
(`{server: {allow: [...], deny: [...]}}`) und `admin`; ein Client hat `token` und
`profile` (beide Pflicht). Die Schlüsselliste des `hub`-Blocks steht in `mcp-hub-runtime`.

`${VAR}` und `${VAR:-default}` werden in `command`, jedem `args`-Element, jedem
`env`-Wert, `cwd`, `url`, jedem `headers`-Wert, `docker`, `volumes`, `docker_args`,
`compose` sowie im `hub`-Block in `listen`, `cache_dir`, `docker_command`,
`docker_network` und jedem Client-`token` expandiert — eine **unset** Variable ohne Default
ist ein Config-Fehler (strenger als Claude Code, das den Literal behält). Server-Namen
matchen `^[A-Za-z0-9][A-Za-z0-9_-]*$`; `all` und führendes `_` sind reserviert.
Unbekannte Keys sind ein Fehler — mit JSON-Pfad in der Meldung.

## CLI (`bin/mcp-hub`)

`daemon` (Vordergrund, single daemon), `config [--client NAME] [--all] [--url BASE]`
(druckt `{"mcpServers": …}`; in clients mode ist `--client` nötig und fügt den Bearer
hinzu), `status` (ruft `GET /_hub/status`; antwortet dort kein Hub, Exit 1 mit `hub is
not running at …` auf stderr), `refresh [NAME]` (`POST /_hub/refresh`; auch der einzige
Weg aus `failed`), `reload` (`POST /_hub/reload`, druckt die Diff-Summary,
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
  `apply_timeouts` in place, ein neues `idle_timeout` zählt ab der letzten Nutzung.
  Geändert → nur dieser Upstream neu, Entfernt → `let_go` + 404.
  Neu → gewärmt wie beim Daemon-Start, d. h. mit gecachtem Manifest **kein Spawn** — erst,
  wenn `upstreams_by_name` die neue Map hält; vorher gälte er selbst als losgelassen.
- **Ein ersetzter oder entfernter Upstream wird gehalten, bis sein Stop vorbei ist, und
  wendet nichts mehr an.** `_let_go` ruft sein `let_go` — es stoppt ihn, ein
  In-process-`class` leert dazu tools/prompts/resources seines Servers (nur hier, nie bei
  einem bloßen `stop`: die Instanz bedient danach weiter) — und hält ihn, bis sein
  `stopped_p` sich setzt; `shutdown_p` wartet auch auf ihn (in den 20 s des Daemons). Mit
  ihm geht sein Server: weder Transport noch Listener am Endpunkt halten ihn. Der
  Nachfolger wartet auf ihn: ein stdio-/Fork-Start spawnt erst, wenn `stopped_p` aller
  `Hub->predecessors(NAME)` (die gleichnamigen in `leaving`) gesetzt ist — bis ~7 s
  `starting`, Call, Refresh, Warming und `always_on` hängen sich an; der Reload selbst
  wartet nie, ein `stop` in der Wartezeit (zweiter Reload, Shutdown) sagt den Start ab.
  Bleibt der Server stdio oder Fork, laufen altes und neues Kind nie nebeneinander.
  Ein Start oder Refresh, der seinen `stop` überlebt, schreibt keinen Cache und
  benachrichtigt niemanden (`Upstream::_dropped`, per `refaddr` gegen `upstreams_by_name`).
  Ein Call oder Refresh, der auf das Ende des alten Kinds wartet, oder ein HTTP-Call, den
  der Stop überholt hat, startet für ihn nichts mehr: er scheitert als
  `upstream NAME: stopped` — das Kind oder die Session beendete sonst niemand. Bei stdio
  prüft das `start_p` selbst, für jeden Aufrufer.
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
Release-Äquivalent. Die Suite braucht **weder node noch Netz noch Docker-Daemon** —
Ausnahmen nur opt-in, sonst `skip_all`: `t/npx.t` (echter npx-Server,
`MCP_HUB_TEST_NPX=1` oder `RELEASE_TESTING`), `t/docker-live.t` (echter Daemon und
`mcp/time`, `MCP_HUB_TEST_DOCKER=1` oder `RELEASE_TESTING`), `t/wiki-live.t`
(`MCP_HUB_TEST_WIKI=1`). `t/hub.t` fährt `Test::Mojo` gegen `MCP::Hub` mit
temp Config/Cache, getrieben von `MCP::Client`; die Natives laufen gegen
`t/fixtures/claude/projects/`.

## Conventions

`Mojo::Base -strict, -signatures` durchgängig — **kein** Moo/Moose in dieser Distribution
(`perl-mojo`). Ausnahme zu `getty-perl-core` („in einer Klasse ist jeder Helper eine
Methode"): ein Helper, der kein `$self` braucht, darf ein nackter privater Sub bleiben, wo
die Datei das schon so hält — etwa `_wrap_tool`, `_listed_extra`, `_join_sections` in
`Aggregate`, `_merge` in `Facade::Server`, `_bearer` in `Auth`; neuer Code folgt der Datei,
in der er steht. POD folgt der Deklaration im `[@Author::GETTY]`-Stil; `# ABSTRACT:` auf
jedem Modul, `# PODNAME:` auf `bin/mcp-hub`. `.claude/` und `CLAUDE.md` gehen mit ins
Tarball (Bundle-Default). Geteilte Skills statt Wiederholung: Release `getty-perl-release-author-getty`,
dist.ini `perl-release-dist-ini`, MCP-Grundlagen `perl-mcp`, Docker `docker`.
