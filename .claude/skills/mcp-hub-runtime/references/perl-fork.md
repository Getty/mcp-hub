# Perl und Fork — `class`-Einträge

## Perl — In-Process, ohne Kindprozess

`class` via `Mojo::Loader`, `new(%args)` — `args` ist bei `class` ein **Objekt**
(keine Liste) und wird nicht expandiert. Die Hub-Instanz wird nur injiziert,
wenn die Klasse ein `hub`-Attribut hat (`$class->can('hub')`). Die Instanz
**ist** der `server` — oder hat eine `server`-Methode, die einen liefert
(Option (a), wie `MCP::Wiki::Server`; geteilt in `Upstream::_load_class` /
`_server_of`) — und beantwortet `tools/list` selbst: kein Manifest, kein
Cache. State immer `ready`; `stop` und `refresh_p` sind No-ops — eine gestoppte
Instanz bedient weiter, mit allen Tools. Erst `let_go` (ein Reload hat den Eintrag
ersetzt oder entfernt) leert tools/prompts/resources ihres Servers: Closures über die
Instanz sind ein Zyklus durch ihren Server, wie bei der Wegwerf-Instanz von Fork; ein
laufender Call hält, was er ausführt, und antwortet noch. Eine Klasse, die
nicht ladbar ist oder weder `MCP::Server` ist noch `server` hat, lässt den
Konstruktor sterben — der Hub macht daraus einen `failed`-Upstream mit Begründung.
Ein langsames Tool blockiert hier die ganze IOLoop; seine Antwort kommt trotzdem an,
gestreamt (`MCP::Hub::Endpoint`).

## Fork — `class` mit `"hub": {"fork": true}`

`Upstream::Fork` ist eine `Stdio`-Subklasse; nur `_build_server`, `_hash`,
`_apply_manifest` und `_spawn` sind anders. **Beim Build** wird die Klasse im Hub
geladen, eine Wegwerf-Instanz beantwortet `initialize`/`tools/list` (und
`prompts/list`/`resources/list` laut Capabilities) über ihr eigenes `handle` mit
einem Legacy-`MCP::Server::Context`; `instructions` kommen vom Server-Objekt (das
Legacy-`initialize` von MCP 0.15 liefert sie nicht). Danach werden ihre
tool/prompt/resource-Listen geleert — Tool-Closures über `$self` sind ein Zyklus —
und die Instanz freigegeben. Kein Cache, kein Hash. Eine Error-Antwort auf
`prompts/list`/`resources/list` ist eine leere Liste wie in `_list_all_p`, das auch
Handshake und Refresh des Workers lesen (`_handle_list` mit `$lenient`); bleibt einem
Worker-Start die Antwort aus, behält er, was die Klasse beim Build listete
(`{class_lists}`, Forks `_cached_manifest`). Verweigert
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
