# Das `/all`-Aggregat

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
Das Profil liefert allen drei Events (auch `instructions`) `Hub::_aggregate_profile`: das
`mcp.profile` aus dem Stash (`Auth::authenticate`); fehlt Controller oder Profil, in open
mode `open_profile`, in clients mode eines ohne Server — fail closed. Ein Handler, der
ohne Profil einfach zurückkehrt, ließe alles durch.

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
