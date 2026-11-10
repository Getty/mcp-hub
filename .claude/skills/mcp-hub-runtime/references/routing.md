# Routing zur Laufzeit

Eine einzige Route `POST /#name`, registriert **nach** `/all` und `/_hub/*`. Der
Upstream wird pro Request nachgeschlagen; die Action hängt am Upstream-Objekt
(`$up->action`) und wird also nur einmal gebaut. Ein unbekannter Name und ein
Server außerhalb des Profils liefern **byte-identisch** dasselbe 404.

Gebaut wird sie, wie die von `/all` in `_setup_routes`, von `MCP::Hub::Endpoint->action`
statt `to_action`: der HTTP-Transport von MCP 0.15 mit zwei Abweichungen. Er hält seinen
Server **schwach** — bei `to_action` halten Server und Transport einander, und jeder je
servierte Server (Façade samt Manifest, Class-Instanz) überlebte den Reload, der seinen
Upstream verwarf; den Server hält der Upstream, für `/all` der Hub. Und `_handle`
(überschreibt eine private Methode von MCP) reicht die sofortige Antwort eines
`tools/call`/`prompts/get`/`resources/read` als Promise weiter, so dass MCP sie als
Event-Stream schickt und dabei den Inactivity-Timeout der Verbindung abschaltet — wie bei
jedem Upstream außerhalb des Hubs. Direkt gerendert verlor ein In-process-Call, der die
Loop länger hielt, unter EV seine Antwort: `Mojo::IOLoop::Stream` setzt den Timer nach
dem Handler mit libevs gecachter Zeit von vor dem Call neu, er feuert vor dem Write
(unter Poll nicht; Binary und Docker-Image laufen auf Poll). Fehler-Antworten, alles mit
eigenem Status und die Listen gehen unverändert als JSON; ein Tool, das nach langem
Blockieren stirbt, verliert seine 500 unter EV weiterhin. Für Tests heißt das: die
Antwort eines In-process-Calls ist `text/event-stream`, `->json` ist leer — die
`sse`-Events vor dem Request abonnieren (`rpc` in `t/aggregate-auth.t`).

Die Setup-Seite (`GET /`) ist eine Inline-JS-Seite: der Login holt das Token per
`fetch` mit Authorization-Header und ersetzt das Dokument.
