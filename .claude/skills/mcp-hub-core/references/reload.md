# Reload

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
