# Http — Streamable HTTP oder HTTP+SSE

Ein `Mojo::UserAgent`, `req_ua`, trägt jeden POST (und das `DELETE` einer Session), mit
`request_timeout` (Default 60 s). Der langlebige SSE-GET läuft auf keinem Agenten, sondern
als rohe `Mojo::IOLoop`-Verbindung ohne Timeout (`_open_sse_p`: Header abstreifen,
de-chunken, `Mojo::SSE`) — `Mojo::UserAgent` parst keinen chunked Event-Stream, und die
Server da draußen senden ihren chunked; so kappt auch kein Request-Timeout den Stream.
`req_ua` hat **keinen** Inactivity-Timeout:
`request_timeout` ist die einzige Grenze eines Requests, auch wenn der Remote länger
schweigt als Mojos Default (40 s bzw. `$MOJO_INACTIVITY_TIMEOUT`) — ein langer Call mit
einer JSON-Antwort, ein Event-Stream ohne Keep-alive. Ein Reload, der `request_timeout`
ändert, setzt ihn am selben `req_ua` (`apply_timeouts`), nie an einem neuen: Mojo liest ihn
beim Start eines Requests und stellt dessen Timer damit — ein Request in flight endet auf
seinem Agenten mit der Grenze, mit der er rausging, der nächste hat die neue. Ein
verworfener Agent schließt seine Verbindungen, der Call scheitert als `Premature connection
close`. `type: "http"` = Streamable HTTP
(Antwort auf dem POST, JSON oder `text/event-stream`), `type: "sse"` = HTTP+SSE
(langlebiger GET-Stream). `headers` trägt das Auth. Drei Fehlschläge binnen 5 s → `failed`.
Jede Ablehnung liest `upstream NAME: …` — auch ohne Antwort (refused, `Request
timeout`), wo Mojo `start_p` selbst nur mit seiner Meldung ablehnt: `_http_send_p`
hängt dafür `$fail` als Reject-Handler an. Ein Fehlerstatus liest mit Code vor der Phrase
(`upstream NAME: 500 Internal Server Error`, `_http_error`) — die Phrase allein verbirgt
ihn, und ein Remote schickt womöglich keine —, über beide Transporte, ebenso die
debug-Zeilen eines gescheiterten Notification-POSTs und eines nicht angenommenen `DELETE`.

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
`initialize` genauso. Auf das `DELETE` wartet nichts, auch kein Shutdown: eins, das beim
Shutdown rausgeht, kommt womöglich nicht mehr an, der Remote lässt die Session dann selbst
auslaufen — ein Remote, der nicht antwortet, hält nie einen Shutdown auf. Ein Start nach
einem Stop ist frisch und beginnt erst, wenn der abgebrochene sich gesetzt hat
(`next_start`) — nie zwei Handshakes zugleich. Ein `404` auf
einen Request **mit** Session-Id heißt: die Gegenseite hat die Session beendet → neue
Session (geteilt von allen Requests, die dieselbe verloren), der Request geht genau
einmal neu raus — nie ein Request des Starts, kein `DELETE` für die tote Session. Ein `404` ohne Session-Id ist ein gewöhnlicher Fehler.

Welche Requests die **des Starts** sind, sagt `_handshake_p` selbst (`$of_start` an
`_request_p`, durch `_list_all_p`/`_paginate_p`) — nie aus dem Methodennamen
geraten. Über Streamable HTTP wartet jeder andere Request, der einen Start antrifft
(die nächste Seite eines Refreshs), auf ihn und geht auf dessen Session raus. Trifft
er `stopped` ohne laufenden Start an, geht kein POST raus: er scheitert sofort als
`upstream NAME: stopped` — der Stop hat die Session beendet und ihre Id vergessen. `$on`
ignoriert Http: einen Refresh, den Stop und Start überholen, setzt die nächste Seite auf
der neuen Session fort. Ein Call kommt gar nicht so weit: `start_p` lässt ihn durch, raus
geht er einen Tick später, und dann sieht `_forward_ready_p` noch einmal nach dem
State. Hat ihn dazwischen ein Stop überholt, ist er ein Call auf `stopped`: er startet
den Upstream neu bzw. wartet auf den laufenden Start und geht über beide Transporte auf
dessen Session oder Stream raus — so abgeschickt ginge er auf nichts (Streamable HTTP
`stopped`, SSE `not connected`). Außer ein Reload hat den Upstream losgelassen
(`_dropped`): dann `upstream NAME: stopped`, kein Start, dessen Session niemand beendete.

Eine `https`-URL braucht TLS in diesem Perl: `IO::Socket::SSL` 2.009+ und
`MOJO_NO_TLS` ungesetzt. `Mojo::IOLoop::TLS` entscheidet das einmal beim Laden —
fehlt es, stirbt `Upstream::Http->new` mit einem Grund, der den Fix nennt, und
der Hub behält einen `failed`-Upstream mit diesem Grund; kein Retry, `refresh`
oder Reload heilt das, nur Modul installieren und Daemon neu starten. Dieselbe
Prüfung (`Http::_tls_missing`, derselbe Text) läuft in `Upstream::Compose->new`
für die `url` eines compose-Eintrags. Ein `docker`-Eintrag (und compose ohne
`url`) braucht sie nicht: die Adresse baut der Hub selbst, immer `http://`.
