# MCP::Hub

A single HTTP MCP server that embeds any number of stdio, remote-HTTP and in-process Perl
MCP servers and hands each of them to every agent on the machine as its own endpoint —
run once per machine, started lazily. Perl / Mojolicious distribution `MCP-Hub`, released
with the `[@Author::GETTY]` Dist::Zilla bundle.

## Delegation

Delegate behavior-relevant code to the right agent instead of touching it yourself — the
principle and the full lane definition live in `.claude/rules/mcp-hub-rules.md`.

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code | `mcp-hub-worker` (default) |
| Write/extend tests | `mcp-hub-test-writer` |
| Pre-release audit | `mcp-hub-release-checker` |

The agents carry their skills via `briefing.skills` (see `.claude/agents/`); the main
agent delegates rather than loading them. Skill sources live under `.claude/skills/` —
architecture and invariants are in `mcp-hub-core`; shared Perl/Mojo/MCP/Docker/release
conventions are hardlinked in from the shared library.

## Coordination & verification

- Work is tracked on this repo's **karr** board (`karr board`). One distribution, one
  board.
- Canonical test run: **`prove -lr t/`** — recursive; `prove -l t/` silently skips the
  `t/native/` and `t/upstream/` subdirs. `dzil test` is the release-time equivalent.
- **Never** `dzil release`, CPAN upload, or `docker push` without the maintainer's
  explicit go-ahead. See the rules file.
