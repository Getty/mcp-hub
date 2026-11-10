# Core invariants — die volle Mechanik

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
  Elicitation weiterzuleiten ist ein Non-goal; die Antworten stehen in `mcp-hub-runtime`
  unter „Server-initiierter Verkehr“.
- **Native Module sind `MCP::Server`-Subklassen und laufen auch standalone** (Tools in
  `new`); `Upstream::Perl` injiziert die Hub-Instanz nur bei `$class->can('hub')`.
  `Upstream::Fork` verweigert genau solche Klassen — ein Worker hätte nur eine tote
  Kopie des Hubs.
