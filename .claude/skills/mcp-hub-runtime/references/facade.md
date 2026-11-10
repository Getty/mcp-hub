# Die Façade

`Facade->build($upstream, $manifest)` baut eine `Facade::Server`; `apply`
ersetzt die Listen **in place**, damit die gemountete Instanz (und ihre
Notification-Abonnenten) über einen Manifest-Refresh hinweg dieselbe bleibt.
Jedes Tool ruft `$upstream->call_tool`, jeder Prompt `get_prompt`, jede Resource
`read_resource` — Ergebnisse (`content`, `isError`, `structuredContent`) kommen
unverändert zurück. Jede Primitive hält ihren Upstream **schwach** (Upstream → Server →
Primitive → Upstream wäre ein Zyklus, ein per Reload ersetzter Upstream würde nie frei);
die Upstream-Liste des Hubs (nach einem Reload `leaving`, bis sein Stop vorbei ist) und
ein laufender Call halten ihn. Ist er weg, antwortet die Primitive mit einem Error-Result.
Den Server hält allein sein Upstream — der Transport des Endpunkts nur schwach
(`MCP::Hub::Endpoint`).

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
(`Http::refresh_p` fängt das selbst und loggt debug, Stdio lehnt ab). Ein Start ohne
Antwort geht mit der Liste aus dem Cache weiter (`_kept_list` über `_cached_manifest`,
loggt info): als leer genommen, landete sie über der guten im Cache, und die Listener
hörten von einer Änderung, die keiner gemeldet hat. Ohne Cache ist sie leer; der nächste
Refresh fragt neu. Nur ein stdio-Kind, das bis zum Ende des Handshakes weg ist, lässt den
Start scheitern. Ein Fehler auf `tools/list` lässt beide scheitern.

Ein Upstream, den ein Reload ersetzt oder entfernt hat, ist losgelassen (`let_go`:
gestoppt, ein In-process-`class` mit geleerten Listen) und bleibt gehalten
(`Hub::_let_go`: in `leaving` per `refaddr`), bis sein `stopped_p` sich setzt — so wartet
`shutdown_p` auch auf sein Kind oder seinen Container. Darauf wartet auch der Nachfolger:
ein stdio-/Fork-Start holt die gleichnamigen aus `leaving` (`Hub->predecessors`) und
spawnt erst nach deren `stopped_p` (bis 7 s, `EOF_GRACE` + `KILL_GRACE`), ein
Container-Start wartet über `%SETTLING` (max. 30 s). Http und Docker/Compose fragen
`predecessors` nicht — wechselt ein Server von stdio zu http oder docker, überlappen
altes und neues weiter. Ein
laufender Start oder Refresh des alten läuft zu Ende — und wendet nichts an:
`_apply_manifest` (Basis und Fork; die Engine reicht an ihren Owner durch) fragt zuerst
`_dropped`. Hält
`upstreams_by_name` unter dem Namen nicht genau dieses Objekt (`refaddr`): kein
Cache-Write (den der Nachfolger teilen kann, der Hash lässt `env` aus), keine
Notification, nur ein debug-Log; ohne Hub ist nichts dropped. Deshalb setzt `reload` die
neue Map, bevor es wärmt (`_apply_config`): vorher gälte der neue Upstream selbst als
dropped, und `start_p` spawnte für ihn nichts. Der Cache-Load beim Build, noch vor dem
Tausch, geht direkt über `Facade->apply`, nicht über `_apply_manifest`.

Extras: `title`, `icons` und `_meta` stehen am Manifest-Eintrag. Tool-Extras
hängen an `Facade::Tool->extra`, Prompt-Extras (nach Name) und Resource-Extras
(nach URI) an `Facade::Server->extra`. `Facade::Server` mischt sie beim
Rendering von `tools/list`, `prompts/list` und `resources/list` in das Ergebnis
zurück — `MCP::Server` rendert sie sonst nicht. Claude-Code-Annotationen wie
`anthropic/maxResultSizeChars` und `anthropic/requiresUserInteraction` überleben
so den Weg durch den Hub. Gerenderter Eintrag und Objekt finden sich **per Position**
(`_pairs`; `_tools`/`_prompts` reichen die Objekte des Events durch), nie per Name;
weicht an einer Position der Name ab, wird nichts gemischt.
