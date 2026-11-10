# Stdio — Legacy-JSON-RPC über einen Socket-Pair

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
`prompts/list`/`resources/list` nur, wenn die Capabilities sie deklarieren; eine
Error-Antwort darauf ist eine leere Liste, ohne Antwort behält der Start die Liste aus
dem Cache (`_kept_list`). Ist
das Kind am Ende des Handshakes weg, scheitert der Start trotzdem, mit dessen
Exit-Grund (`$child->{exited}`; nur stdout zu → auf den Exit warten) — nie `ready` ohne
Kind; der Exit zählt einmal zur Crash-Loop.

stdout wird an Newlines gesplittet, jede Zeile als JSON dekodiert; eine kaputte
Zeile wird übersprungen (debug). Der Line-Buffer ist bei 16 MB gekappt — dann
wird der Kindprozess gekillt (error-Log), und der Kill zählt wie ein Crash zur
Crash-Loop: Requests in flight scheitern als `exited (signal 9)`, ist er der dritte, liest
der Fehler `3 exits within 5s: line buffer exceeded 16MB` (`_record_exit` mit Grund).
Ungezählt spawnte jeder Call einen Server neu, der bei jedem Start seinen stdout flutet,
und nie `failed`. Exit 127 beim Start ist ein Konfigurationsproblem:
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
und weiterlebt, wird nach `KILL_GRACE` gekillt. Ab dem Stop, bis der Exit verarbeitet ist,
steht der Upstream auf `stopping` (`failed` bleibt `failed`), auch nach einem Start, den
der Stop absagt, solange dessen Kind lebt. Es läuft immer höchstens ein Kind: ein
Call während eines Stops wartet auf dessen Ende (`_gone_p`) und startet das nächste —
außer ein Reload hat den Upstream inzwischen losgelassen: `start_p` fragt vor jedem Spawn
`_dropped` und lehnt als `upstream NAME: stopped` ab, für jeden Aufrufer (Call, Refresh,
Warming, `always_on`). Auch über einen Reload: hält der Hub einen losgelassenen
gleichnamigen Vorgänger (`Hub->predecessors`), wartet der Start — schon `starting`, in
`{waiting}` — auf dessen `stopped_p` und spawnt erst dann (`_launch`); ein `stop` in der
Wartezeit sagt ihn ab (debug `start called off by a stop`). Ohne Hub (die
Docker-Engine) wartet nichts.
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
als `upstream NAME: stopped` ab). Der Text ist Vertrag: `Hub::_called_off` erkennt genau
ihn, und weder `_warm_upstream` noch `Hub::refresh_p` nimmt einen so abgesagten Start als
gescheiterten Fetch — kein error-Log, kein `failed`.

Ein Refresh (`refresh_p`, nur bei `ready` mit pid) ist an das Kind gebunden, auf dem er
begann: `_list_all_p(0, $self->{child})` reicht es als `$on` bis `_request_p`, und jeder
seiner Requests scheitert sofort (`the child the refresh began on is gone`), sobald das
Kind nicht mehr das laufende ist oder EOF bekam. Zwischen zwei Listen kann die Loop den
Exit und einen Call samt neuem Kind abwickeln — ungebunden nähme der Refresh dessen Listen
für die alten. Fork und Docker-stdio erben das. Http bindet nicht; die Transporte
unterscheiden sich vorerst mit Absicht. Trifft ein Refresh `stopping` an, fragt er das
Kind nichts: er wartet wie ein Call auf `_gone_p` und fragt das nächste, das er dafür
startet — außer ein Reload hat den Upstream inzwischen losgelassen, dann scheitert er in
`start_p` als `upstream NAME: stopped` (oben): das Kind stoppte sonst niemand.
