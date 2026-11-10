# Config und CLI

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
`profile` (beide Pflicht). Die Schlüsselliste des `hub`-Blocks steht in SKILL.md (Config).

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
hinzu), `status` (ruft `GET /_hub/status`), `refresh [NAME]` (`POST /_hub/refresh`; auch
der einzige Weg aus `failed`), `reload` (`POST /_hub/reload`, druckt die Diff-Summary,
Exit ≠ 0 bei abgelehnter Config), `token` (32 Zufallsbytes base64url, fasst die Config
nie an). `status`/`refresh`/`reload` nehmen `--client NAME` und `--url BASE`; antwortet
dort kein Hub, enden alle drei mit Exit 1 und `hub is not running at …` auf stderr
(`local $! = 1; die`), nie mit Exit 0.
