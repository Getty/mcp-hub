# Die Native Server

`Native::ClaudeHistory` liest `$CLAUDE_CONFIG_DIR` bzw. `~/.claude`: die Session-Dateien
in `projects/*/`, je Session die Subagent-Läufe (`<session>/subagents/agent-<id>.jsonl`
plus `agent-<id>.meta.json`) und Claude Codes Prompt-History `history.jsonl` neben
`projects/`. Sechs Tools: `list_projects`, `list_sessions`, `list_subagents`,
`search_conversations` (Substring-Suche, **kein** Volltext-Index in v1; mit
`include_subagents` auch die Läufe), `get_conversation` (mit `agent_id` ein Lauf) und
`list_prompts`. Ein Lauf ist keine Session — `list_projects`/`list_sessions` zählen ihn
nicht —, geht aber durch denselben `meta_cache` und dieselbe Decode-Naht; `agent_id` wird
wie `session_id` nur mit Dateinamen verglichen, nie zum Pfad. Session-, Lauf- und
History-Dateien werden zeilenweise gelesen, nie geslurpt; die Suche (und `list_prompts`'
`query`) dekodiert eine Zeile nur, wenn ihre Rohbytes den Treffer halten können
(`_raw_skip` — auch JSON-Escapes zählen). `meta_cache` hält je Datei dev/inode/size, die
mtime per `Time::HiRes::stat` auf den Bruchteil der Sekunde (so fällt auch ein Neuschreiben
gleicher Größe binnen einer Sekunde auf) und den Offset nach der letzten ganzen Zeile:
unverändert → nicht gelesen, nur gewachsen → ab dem Offset, sonst von vorn. Den ersten
Prompt einer Session hält er auf 500 Zeichen
gekürzt (plus `…`, wenn länger), so sendet ihn `list_sessions`; den eines Laufs **gar
nicht** (kein Tool sendet ihn, Briefings über Tausende Läufe wären der Großteil des
Caches). `list_prompts` liest `history.jsonl` bei jedem Aufruf ganz, zeilenweise und
**ohne Cache** (Claude Code schreibt sie beim Prunen neu), hält nur die neuesten `limit`
Treffer, sendet `display` und nie die eingefügten Inhalte, und setzt `has_transcript`
allein nach den Namen der Session-Dateien, ohne eine zu lesen. `since`/`until` werden per
`_iso_ms` als Zeitpunkte verglichen, nicht als Strings; eine Grenze, die kein Datum und
keine Zeit ist, ist ein Error-Result. `search_conversations` prüft sie an jedem Treffer
gegen dessen eigenen `timestamp` (ohne gültige Zeit kommt er durch) und überspringt keine
Session nach ihrer `last_activity` — die ist die Zeit ihrer letzten Zeile mit Zeit, nicht
ihre neueste. Dieselben Zeitpunkte ordnen
`list_projects`/`list_sessions` (neueste zuerst) und die Läufe (nach Start), per
`_timed`/`_by_time`: `meta_cache` hält je Datei `started_at`/`last_activity` als ms, beim
Lesen geparst, nie im Komparator; bei gleichem Zeitpunkt entscheidet der String, und eine
Zeit ohne Zeitpunkt zählt als die älteste. Kein Key dafür an einem Record, der rausgeht.

Jede Zeile, die `ClaudeHistory` und `ClaudeSessions` lesen (und jede `.meta.json`), geht
durch das `decode_json` des eigenen Pakets; welcher Decoder dahinter steht, entscheidet
sich einmal beim Laden. Ist `JSON::MaybeXS::JSON()` Cpanel::JSON::XS, dekodiert
`JSON::MaybeXS->new(utf8 => 1)` mit `allow_dupkeys`, damit von einem doppelt gehaltenen
Key wie bei Mojo::JSON der letzte Wert gewinnt (Cpanel::JSON::XS verwürfe die Zeile sonst).
Bei jedem anderen Backend (JSON::PP, auf einem Host ohne C-Compiler) dekodiert
`Mojo::JSON::decode_json`, weil JSON::PP manche kaputte oder extreme Zeile anders läse — so
liest jede Installation eine Zeile gleich. Das Tempo von Cpanel::JSON::XS zählt auf
Historien von vielen MB; das Binary packt es mit (`scripts/binary-pp-args.sh` bricht ohne
ab). Encodiert wird weiter mit Mojo::JSON. Die Tests zählen Decodes, indem sie dieses
`decode_json` umhängen — kein Decode an ihm vorbei.

`Native::ClaudeSessions` findet laufende `claude`-Prozesse über `/proc/*/comm` (plus
`cwd`) — **Linux-only**, andernfalls ein Error-Result (`proc_root` ist testbar
überschreibbar). Kein `pgrep`: der läse dieselben Namen, `hidepid` verbirgt ihm dasselbe.
Von der Session-Datei eines Prozesses liest es nur Kopf und Ende, das Ende zurück bis
zur letzten User-Zeile mit Text (Zeilen nur mit Tool-Results übergeht es; trägt keine
User-Zeile Text, ist `last_prompt` null), und kürzt `last_prompt` wie `first_prompt` auf
500 Zeichen plus `…`. `Native::Status`
liefert `hub_status` und `hub_refresh` (letzteres braucht in clients mode ein
`admin`-Profil). `rss_kb` (Resident set size) ist **kein** Tool, sondern ein
Stat-Attribut am Upstream — es steckt im Status-Report.
