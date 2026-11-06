---
name: mcp-hub-runtime
description: Load with mcp-hub-core before changing how the hub talks to or shows upstreams — the upstream types (stdio legacy JSON-RPC, remote HTTP/SSE, in-process or forked Perl class, Docker image or Compose service), the manifest cache, the façade, the /all aggregate, the wire rules for server-initiated traffic, the native servers, the dynamic routing.
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
eine fortlaufende id; ein Request-Timeout lehnt das Promise als `upstream NAME: timed out
after Ns` ab und schickt `notifications/cancelled` mit der id und diesem Grund als
`reason`, wie Http (`_cancel`) — nie für `initialize` (Spec). Fork und Docker-stdio erben
das mit `_request_p`.

Handshake: `initialize` mit Protokoll `2025-06-18` (der Server antwortet, was er
will — seine Version wird übernommen) → `notifications/initialized` →
`tools/list` **mit Cursor-Pagination** (`nextCursor` wird verfolgt) →
`prompts/list`/`resources/list` nur, wenn die Capabilities sie deklarieren; jeder
Fehler darauf ist beim Start eine leere Liste (beim Refresh nicht, siehe Façade). Ist
das Kind am Ende des Handshakes weg, scheitert der Start trotzdem, mit dessen
Exit-Grund (`$child->{exited}`; nur stdout zu → auf den Exit warten) — nie `ready` ohne
Kind; der Exit zählt einmal zur Crash-Loop.

stdout wird an Newlines gesplittet, jede Zeile als JSON dekodiert; eine kaputte
Zeile wird übersprungen (debug). Der Line-Buffer ist bei 16 MB gekappt — dann
wird der Kindprozess gekillt. Exit 127 beim Start ist ein Konfigurationsproblem:
die Meldung nennt das Kommando ("is it installed and executable?"). Drei Exits
binnen 5 s → `failed`.

Zwischen `fork` und `exec` schließt `Child::close_inherited_fds` jeden fd > 2 — der
Listen-Socket des Hubs ist nicht close-on-exec, ein Kind, das den Hub überlebt, hielte
sonst den Port —, und `child_env` lässt `MOJO_REUSE` weg; dasselbe gilt für jeden
`docker`-Lauf (`Docker::run_p`), der Fork-Worker legt `/dev/null` darüber
(`inherited_fds`). Den Exit-Status holt `watch_exit`, aufgesetzt direkt nach dem `fork`.
Stop: `shutdown` SHUT_WR (EOF) — erst nach `drain`, wenn der Stream noch puffert: ein im
selben Tick geschriebener Request ginge sonst verloren (das Kind endet ohne ihn auf EOF, er
scheitert als dessen Exit) und der Stream schriebe ihn endlos gegen den geschlossenen Socket
(EPIPE-Spin) → nach `EOF_GRACE` (2 s) `SIGTERM` → nach `KILL_GRACE`
(5 s) `SIGKILL`; wer auf EOF endet, sieht nie ein Signal. Ein Kind, das stdout schließt
und weiterlebt, wird nach `KILL_GRACE` gekillt. Es läuft immer höchstens ein Kind: ein
Call während eines Stops wartet auf dessen Ende (`_gone_p`) und startet das nächste.
Was das Kind nicht mehr erreicht (`_refused`: kein Stream — Kind weg oder stdout zu —
oder EOF geschickt), geht nicht raus und scheitert sofort als `upstream NAME: not
connected` bzw. `stopped`, statt den Request-Timeout abzuwarten. Ein Stop während des
Starts lässt ihn als `stopped` scheitern, welchen Schritt er auch abschneidet (wie Http):
sofort, wenn der nächste Request nicht rausgeht, sonst mit der Antwort oder dem Ende des
Kinds — endet es auf den EOF, bevor es den Request in flight beantwortet, lehnt der Start
trotzdem als `stopped` ab, nicht als `exited (…)`. Nicht gezählt, das Kind bleibt dem Stop
(kein Signal, wenn es auf EOF endet), geloggt auf debug (`start called off by a stop`, wie
Http), nie als `handshake failed` auf error; Kriterium ist `$child->{eof}`. Fork und
Docker-stdio erben das mit `start_p` (Docker lehnt einen Start, den ein Stop abbricht, ebenso
als `upstream NAME: stopped` ab).

Ein Refresh (`refresh_p`, nur bei `ready` mit pid) ist an das Kind gebunden, auf dem er
begann: `_list_all_p(0, $self->{child})` reicht es als `$on` bis `_request_p`, und jeder
seiner Requests scheitert sofort (`the child the refresh began on is gone`), sobald das
Kind nicht mehr das laufende ist oder EOF bekam. Zwischen zwei Listen kann die Loop den
Exit und einen Call samt neuem Kind abwickeln — ungebunden nähme der Refresh dessen Listen
für die alten. Fork und Docker-stdio erben das. Http bindet nicht (unten); die Transporte
unterscheiden sich vorerst mit Absicht.

### Http — Streamable HTTP oder HTTP+SSE

`Mojo::UserAgent`, zwei Agenten: der Stream-UA (SSE-GET) läuft **ohne** Timeout,
der POST-UA mit `request_timeout` (Default 60 s) — sonst kappt der POST-Timeout
den langlebigen SSE-Stream. Der POST-UA (`req_ua`) hat **keinen** Inactivity-Timeout:
`request_timeout` ist die einzige Grenze eines Requests, auch wenn der Remote länger
schweigt als Mojos Default (40 s bzw. `$MOJO_INACTIVITY_TIMEOUT`) — ein langer Call mit
einer JSON-Antwort, ein Event-Stream ohne Keep-alive. `type: "http"` = Streamable HTTP
(Antwort auf dem POST, JSON oder `text/event-stream`), `type: "sse"` = HTTP+SSE
(langlebiger GET-Stream). `headers` trägt das Auth. Drei Fehlschläge binnen 5 s → `failed`.
Jede Ablehnung liest `upstream NAME: …` — auch ohne Antwort (refused, `Request
timeout`), wo Mojo `start_p` selbst nur mit seiner Meldung ablehnt: `_http_send_p`
hängt dafür `$fail` als Reject-Handler an.

Über SSE kommt jede Antwort auf dem Stream, der POST trägt nur den Request. Nimmt die
Gegenseite ihn nicht (Fehlerstatus, keine Antwort, refused), scheitert sein Request sofort
mit `upstream NAME: <Grund>` wie über Streamable HTTP (`_sse_post_failed`), statt den
Request-Timeout abzuwarten; 202 oder jedes andere 2xx heißt angenommen. Ein Request des Hubs
ist nur ein Objekt mit `method` **und** `id`: eine eigene Antwort (ping, roots/list) trägt
die id des Remote-Requests, die der eines eigenen gleichen kann — ihr gescheiterter POST,
wie der einer Notification, wird nur auf debug geloggt. Der Callback hält den Upstream
schwach. Zur Connect-Failure-Loop zählt ein gescheiterter POST nur über den gescheiterten
Start, wie jeder andere.

Einen Request, den der Hub per Timeout aufgibt, sagt er auf der Gegenseite ab wie beim
stdio-Kind — ein Verbindungsabbruch ist laut Spec keine Absage, der Remote arbeitete sonst
weiter: Streamable HTTP, wenn `req_ua` den POST mit `Request timeout` abbricht (Mojos
Meldung, `TIMED_OUT`); SSE, wenn sein Timer feuert. `_cancel` schickt
`notifications/cancelled` mit der id, mit der er rausging, und dem Grund seiner
Ablehnung als `reason`, wie jede Notification (Streamable HTTP mit Session-Id und
ausgehandelter Version, SSE an den Endpoint). Nie für `initialize` (Spec); nichts, wenn der
Upstream nicht `ready`/`starting` ist oder nicht mehr auf der Session des Requests (`$sent`)
bzw. seinem Stream sitzt — ein Stop hat die Session beendet oder beendet sie nach dem
letzten Call. Fire-and-forget: der Request ist schon abgelehnt; ein gescheiterter POST
ändert nichts und wird, wie der jeder Notification, über beide Transporte nur auf debug
geloggt (`POST of METHOD failed: …`; Streamable HTTP in `_http_post`).

Streamable-HTTP-Sessions: jeder Start öffnet eine **neue** Session — sein `initialize`
trägt weder Session-Id noch `MCP-Protocol-Version`, die Id kommt nur aus dessen Antwort
(`Mcp-Session-Id`), spätere Requests tragen Id und ausgehandelte Version. Ein Stop
beendet die Session mit einem `DELETE`, aber erst, wenn der letzte Call darauf fertig
ist — ein Call auf `ready` läuft über Streamable HTTP weiter (über SSE scheitert er als
stopped); ein gescheiterter oder abgebrochener Start beendet die Session seines
`initialize` genauso. Ein Start nach einem Stop ist frisch und beginnt erst, wenn der
abgebrochene sich gesetzt hat (`next_start`) — nie zwei Handshakes zugleich. Ein `404` auf
einen Request **mit** Session-Id heißt: die Gegenseite hat die Session beendet → neue
Session (geteilt von allen Requests, die dieselbe verloren), der Request geht genau
einmal neu raus — nie ein Request des Starts, kein `DELETE` für die tote Session. Ein `404` ohne Session-Id ist ein gewöhnlicher Fehler.

Welche Requests die **des Starts** sind, sagt `_handshake_p` selbst (`$of_start` an
`_request_p`, durch `_list_all_p`/`_paginate_p`) — nie aus dem Methodennamen
geraten. Über Streamable HTTP wartet jeder andere Request, der einen Start antrifft
(Call, nächste Seite eines Refreshs), auf ihn und geht auf dessen Session raus. Trifft
er `stopped` ohne laufenden Start an, geht kein POST raus: er scheitert sofort als
`upstream NAME: stopped` — der Stop hat die Session beendet und ihre Id vergessen. `$on`
ignoriert Http: einen Refresh, den Stop und Start überholen, setzt die nächste Seite auf
der neuen Session fort.

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
und die Instanz freigegeben. Kein Cache, kein Hash. Eine Error-Antwort auf
`prompts/list`/`resources/list` ist eine leere Liste wie in `_list_all_p`, das auch
Handshake und Refresh des Workers lesen (`_handle_list` mit `$lenient`). Verweigert
(→ Placeholder): Klassen mit `hub`-Attribut, Listing per Promise, eine Error-Antwort
auf `tools/list`, kein `/proc/self/fd`.

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

### Docker und Compose — ein Container pro Start

`Upstream::Docker` (`"docker": IMAGE`) und `Upstream::Compose` (`"compose": DIR` plus
`service`; Docker-Subklasse, nur die Kommandos sind anders) sind lazy wie stdio: Manifest
aus dem Cache, Idle-Stop, `always_on`; die Crash-Loop (3 gescheiterte Starts oder Crashes
binnen `fail_window` 5 s) zählt der Upstream über alle Läufe.

**stdio oder HTTP entscheidet jeder Start neu** (`_plan_p`, `mode`) — docker nach dem
Pull: `"stdio": true` → stdio; `port` → HTTP darauf; genau ein `EXPOSE`-Port → HTTP;
mehrere → Startfehler; keiner → stdio. Compose liest das Projekt per `docker compose
config --format json` (der Hub parst nie YAML): `stdio`; `url` → HTTP genau dorthin;
`port` (muss unter `ports:` publiziert sein); genau ein publizierter Port; mehrere →
Fehler; keiner → stdio. Landet es bei stdio, sind gesetzte `path`/`type`/`headers` ein
Startfehler. Was lange dauert (Pull oder Build eines fehlenden Images, Abhängigkeiten),
läuft **vor** dem Handshake und ohne Timeout, damit `request_timeout` nur den Server misst.

**Engine pro Start.** Der Transport kann nicht die Klasse sein: jeder Start baut eine
Engine — `Docker::Stdio` (`docker run -i --rm …` bzw. `docker compose run --rm -T
--no-deps …` als gewöhnliches Stdio-Kind) oder `Docker::Http` (Transport von
`Upstream::Http`). `Docker::Engine` steht in deren `@ISA` vor dem Transport: die Engine
ist nirgends gemountet, hält ihren Owner schwach, teilt dessen Façade und Hash, reicht jedes Manifest
und `_held_p` an ihn weiter und zählt keine Crash-Loop. Ein ungebetener Exit oder ein
abgerissener SSE-Stream im Betrieb → `owner->_engine_down`.

HTTP-Container: `docker run -d`, Port auf `127.0.0.1::PORT` (mit `hub.docker_network`
stattdessen `--network`, Adresse `mcp-hub-<name>:PORT`), Adresse per `docker port`,
Pfad-Default `/mcp`. **Readiness** (`_ready_p`): ein offener Port beweist nichts — POST
alle 0,5 s, bis irgendein HTTP-Status kommt; Abbruch, wenn der Container endet (`docker
wait`, Fehler mit dem Ende von `docker logs`) oder nach `request_timeout`; kam der Port
aus `EXPOSE`/`ports:`, rät der Fehler zu `"stdio": true`. Compose übernimmt einen schon
laufenden Service (kein `up`, nie gestoppt), sonst `up -d --no-recreate SERVICE` und beim
Stop `compose stop SERVICE`. Für stdio vorher Pull/Build, `up -d --no-recreate` der
`depends_on` und deren Bedingungen (Poll auf `ps -a`). Compose stoppt nie eine
Abhängigkeit und recreatet nie, was existiert; Compose ≥ 2, kein podman-compose.

**Was dem Hub gehört, sagen nur die Labels.** Name `mcp-hub-<name>`, Labels
`mcp-hub.server`, `mcp-hub.owner` (Zufalls-Id in `<cache_dir>/docker-owner` — ohne sie
startet kein Container) und `mcp-hub.run` (je Start). Vor jedem Start entfernt
`remove_orphans_p` eigene Reste, jeden Treffer per `inspect` nachgeprüft — nie einen
fremden; ein fremder gleichnamiger lässt den Start scheitern. Ein Start wartet (max.
30 s, `%SETTLING` je cache_dir + Name, auch über einen Reload), bis der vorige Container
des Servers weg ist. Stop: stdio wie jedes Stdio-Kind, danach der Container per
`run`-Label weg; HTTP `docker stop -t 5` + `rm -f`; `stopped_p` → der Daemon wartet
beim Shutdown. `env` geht als nacktes `-e KEY`, der Wert nur über die Umgebung des
CLI-Prozesses. Fehlertexte tragen nur stderr (`stderr_tail`), nie stdout — `compose
config` liefert das ganze Projekt samt Secrets. Status-Zeile: `container` und `mode`
(compose: `compose`, `service`), `pid`/`rss_kb` bleiben `undef`.

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

## Die Façade

`Facade->build($upstream, $manifest)` baut eine `Facade::Server`; `apply`
ersetzt die Listen **in place**, damit die gemountete Instanz (und ihre
Notification-Abonnenten) über einen Manifest-Refresh hinweg dieselbe bleibt.
Jedes Tool ruft `$upstream->call_tool`, jeder Prompt `get_prompt`, jede Resource
`read_resource` — Ergebnisse (`content`, `isError`, `structuredContent`) kommen
unverändert zurück. Jede Primitive hält ihren Upstream **schwach** (Upstream → Server →
Primitive → Upstream wäre ein Zyklus, ein per Reload ersetzter Upstream würde nie frei);
die Upstream-Liste des Hubs und ein laufender Call halten ihn. Ist er weg, antwortet die
Primitive mit einem Error-Result.

Ein neues Manifest (Start oder Refresh, `Upstream::_show_manifest`) vergleicht
das eigene Rendering der drei Listen vorher/nachher: der eigene Endpunkt bekommt
`<kind>/list_changed` je geänderter Liste, `/all` über
`Hub::rebuild_aggregate(@changed)` nur für `tools`/`prompts`. Unverändert →
keine Notification — sonst schickte jeder Neustart nach dem Idle-Stop eine.

Fehler-Antworten: beantwortet der Upstream einen Request mit einem JSON-RPC-Error, lehnt
der Transport mit einer `Upstream::ErrorAnswer` ab (`_error_answer`; `error` = das
Original, stringifiziert zu `upstream NAME: <message>`), ohne Antwort — Timeout, Stop,
Kind oder Verbindung weg, HTTP-Fehlerstatus — mit einem String. Unterschieden wird per
`_answered` (isa), nie am Text. In `_list_all_p` ist eine Error-Antwort auf
`prompts/list`/`resources/list` eine leere Liste; keine Antwort lässt einen Refresh
scheitern: das alte Manifest bleibt, nichts gespeichert, niemand benachrichtigt
(`Http::refresh_p` fängt das selbst und loggt debug, Stdio lehnt ab). Ein Start nimmt
beides als leer — offene Maintainer-Entscheidung (k143); nur ein stdio-Kind, das bis zum
Ende des Handshakes weg ist, lässt ihn scheitern. Ein Fehler auf `tools/list` lässt beide
scheitern.

Ein Upstream, den ein Reload ersetzt oder entfernt hat, ist gestoppt, aber ein laufender
Start oder Refresh läuft zu Ende — und wendet nichts an: `_apply_manifest` (Basis und
Fork; die Engine reicht an ihren Owner durch) fragt zuerst `_dropped`. Hält
`upstreams_by_name` unter dem Namen nicht genau dieses Objekt (`refaddr`): kein
Cache-Write (den der Nachfolger teilen kann, der Hash lässt `env` aus), keine
Notification, nur ein debug-Log; ohne Hub ist nichts dropped. Sicher, weil `reload` die
neue Map zwar erst nach `_warm_upstream` setzt, aber synchron, und jedes `_apply_manifest`
in einem Promise-Callback läuft; der Cache-Load beim Build geht direkt über
`Facade->apply`. Wer daran dreht, hält `_apply_manifest` aus jedem synchronen Pfad in
`reload`/`_warm_upstream` heraus — sonst gälte der neue Upstream selbst als dropped.

Extras: `title`, `icons` und `_meta` stehen am Manifest-Eintrag. Tool-Extras
hängen an `Facade::Tool->extra`, Prompt-Extras (nach Name) und Resource-Extras
(nach URI) an `Facade::Server->extra`. `Facade::Server` mischt sie beim
Rendering von `tools/list`, `prompts/list` und `resources/list` in das Ergebnis
zurück — `MCP::Server` rendert sie sonst nicht. Claude-Code-Annotationen wie
`anthropic/maxResultSizeChars` und `anthropic/requiresUserInteraction` überleben
so den Weg durch den Hub. Gerenderter Eintrag und Objekt finden sich **per Position**
(`_pairs`; `_tools`/`_prompts` reichen die Objekte des Events durch), nie per Name;
weicht an einer Position der Name ab, wird nichts gemischt.

## Das `/all`-Aggregat

`Aggregate->rebuild(\@upstreams)` baut die Tools und Prompts aller Upstreams mit
`<name>__`-Präfix; die `instructions` sind die aneinandergehängten
Upstream-Instructions, jeder Block mit `## <name>` überschrieben. Resources
werden **nicht** aggregiert (opake URIs würden kollidieren). Die Filter des Profils
entscheiden nach der **Herkunft** jedes Eintrags — `Aggregate->origin($entry)` liefert
`(server, eigener Name)`, in `rebuild` per `refaddr` am Wrapper-Objekt gemerkt —, **nie**
durch Splitten des Namens am ersten `__`: ein Servername darf selbst `__` enthalten
(`p__x`), und ein Profil `[p]` darf dessen `p__x__…` nicht erreichen. Am `tools`-Event
`servers`- und `tools`-Regeln (`Auth::filter_aggregate`), am `prompts`-Event nur
`servers` (`filter_aggregate_prompts`); ein Eintrag ohne bekannte Herkunft fällt weg.
`tools/call`/`prompts/get` suchen in der gefilterten Liste — Verborgenes ist „not found".

Bekannte Grenze: zwei Server können denselben `/all`-Namen erzeugen (`p` mit Tool
`x__echo`, `p__x` mit `echo` → beide `p__x__echo`). Beide werden gelistet, der Call trifft
den ersten in Servernamen-Reihenfolge; sieht das Profil nur einen, ist es dieser, und
jeder wird mit seinen eigenen `title`/`icons`/`_meta` gelistet. Darum
die Herkunft am Objekt und keine Name→Server-Map — die müsste einen der beiden falsch
zuordnen. `t/aggregate-origin.t` hält das fest; `__` in Servernamen zu verbieten
(Config) ist Entscheidung des Maintainers.

Extras: `Aggregate` ist ein `Facade::Server`. `rebuild` liest `title`/`icons`/`_meta`
aus dem **eigenen Rendering** jedes Upstream-Servers (`_handle_tools_list` /
`_handle_prompts_list` mit leerem Context, also ohne Profil-Filter; dort per Name, auf
einem Endpunkt eindeutig) — nicht aus den Objekten: ein In-process-Server hat plain
`MCP::Tool`s ohne `extra` und rendert sie selbst. Danach hängen sie **am Wrapper**:
Tool-Extras an `Facade::Tool->extra`, Prompt-Extras im privaten `_prompt_extras` per
`refaddr` des Wrappers (überschriebenes `_prompt_extra`) — `$agg->extra->{prompts}`
bleibt leer. Zurückgemischt wird nach dem Filter. Jeder Wrapper übernimmt außerdem
`scopes`, `cache_ttl` und `cache_scope` des Originals (`_primitive_fields`): der Call
geht am Scope-Check des Original-Servers vorbei, also prüft `/all` selbst. Nur
In-process-Klassen setzen sie; Manifest-Tools tragen sie nie.

Selbstbeschreibung pro Request: `MCP::Server` beantwortet `server/discover` (und das
Legacy-`initialize`, `MCP::Server::Legacy::legacy_result`) aus den **ungefilterten**
Listen, ohne Event, mit `cacheScope` = `$server->cache_scope` (`public`). `Aggregate`
überschreibt darum `_dispatch` und schreibt das Ergebnis pro Request um: `tools`/
`prompts`-Capability nur, wenn die per Event gefilterte Liste etwas enthält; bei
`server/discover` nur die `## <name>`-Abschnitte, die das neue `instructions`-Event
übrig lässt (der Hub filtert die Servernamen mit `allows_server`), und `cacheScope:
private`, sobald ein Filter-Event Abonnenten hat. Das `instructions`-Attribut bleibt die
volle Verkettung. Das Legacy-`initialize` trägt in MCP 0.15 gar keine Instructions.

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
`search_conversations` (Substring-Suche, **kein** Volltext-Index in v1) und
`get_conversation`. Session-Dateien werden zeilenweise gelesen, nie geslurpt; die Suche
dekodiert eine Zeile nur, wenn ihre Rohbytes den Treffer halten können (`_raw_skip` —
auch JSON-Escapes zählen). `meta_cache` hält je Datei dev/inode/size/mtime und den Offset
nach der letzten ganzen Zeile: unverändert → nicht gelesen, nur gewachsen → ab dem
Offset, sonst von vorn. `Native::ClaudeSessions` findet laufende
`claude`-Prozesse über `/proc/*/comm` (plus `cwd`) und liest von deren Session-Datei nur
Kopf und Ende — **Linux-only**, andernfalls
ein Error-Result (`proc_root` ist testbar überschreibbar). Kein `pgrep`: der läse
dieselben Namen, `hidepid` verbirgt ihm dasselbe. `Native::Status`
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
`request_timeout`, `profiles`, `clients`, `public_profile`, `auto_reload`,
`docker_command`, `docker_network`. Pro
Server-Eintrag: `idle_timeout`, `always_on`, `request_timeout` und `fork` (im
`hub`-Block des Eintrags; auf einem In-process-`class`-Eintrag sind die drei
ersten ein Fehler, auf einem `url`-Eintrag `idle_timeout`; `fork` gibt es nur auf `class`). Ein Tippfehler in einem Key fällt beim Start auf, z. B.
`mcpServers.playwright.hub.idle_timeout`.

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
