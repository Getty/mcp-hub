#!/bin/sh
# A stdio MCP server in POSIX sh with one tool, echo. It lets the packed mcp-hub
# be smoke-tested on a machine without Perl (scripts/binary-smoke.sh mounts it
# as a stdio upstream); t/binary.t keeps it working against the Perl hub.
#
#   sh t/upstream/echo.sh [MARKER]
#
# Every start appends "start <pid>" to MARKER, so a caller can tell whether and
# when the hub spawned it. The parsing leans on mcp-hub's framing: one JSON
# object per line with sorted keys (Mojo::JSON), so a request -- and only a
# request -- starts with {"id":N, and a notification is skipped. Mojo::JSON
# writes "/" as "\/", so a method name matches in both spellings.
[ -n "${1:-}" ] && echo "start $$" >>"$1"

reply() { printf '{"id":%s,"jsonrpc":"2.0","result":%s}\n' "$1" "$2"; }

while IFS= read -r line; do
  id=$(printf '%s\n' "$line" | sed -n 's/^{"id":\([0-9][0-9]*\),.*/\1/p')
  [ -n "$id" ] || continue
  case "$line" in
    *'"method":"initialize"'*)
      reply "$id" '{"capabilities":{"tools":{}},"protocolVersion":"2025-06-18","serverInfo":{"name":"echo-sh","version":"1.0"}}' ;;
    *'"method":"tools/list"'* | *'"method":"tools\/list"'*)
      reply "$id" '{"tools":[{"description":"Echo msg back","inputSchema":{"properties":{"msg":{"type":"string"}},"required":["msg"],"type":"object"},"name":"echo"}]}' ;;
    *'"method":"tools/call"'* | *'"method":"tools\/call"'*)
      # Plain text only: a msg with a quote or a backslash is not echoed.
      msg=$(printf '%s\n' "$line" | sed -n 's/.*"arguments":{"msg":"\([^"\\]*\)"}.*/\1/p')
      reply "$id" "{\"content\":[{\"text\":\"$msg\",\"type\":\"text\"}],\"isError\":false}" ;;
    *'"method":"ping"'*)
      reply "$id" '{}' ;;
    *)
      printf '{"error":{"code":-32601,"message":"method not found"},"id":%s,"jsonrpc":"2.0"}\n' "$id" ;;
  esac
done
