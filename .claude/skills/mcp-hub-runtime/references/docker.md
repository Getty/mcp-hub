# Docker und Compose — ein Container pro Start

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
`depends_on` und deren Bedingungen (Poll auf `ps -a`, ohne Obergrenze — compose hat
keine, ein Stop beendet es). Das Warten sagt, worauf: `waiting_for` in der Status-Zeile ab
der ersten Antwort (jede noch offene Abhängigkeit mit State/Health ihrer Container), `warn`
im Log nach `depends_warn_after` (30 s), dann alle `depends_warn_interval` (60 s) —
Attribute, keine Config. Ein HTTP-Start wartet in `up` selbst; das sagt nichts. Compose
stoppt nie eine Abhängigkeit und recreatet nie, was existiert; Compose ≥ 2, kein
podman-compose.

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
(compose: `compose`, `service`, beim Warten auf `depends_on` `waiting_for`), `pid`/`rss_kb`
bleiben `undef`.
