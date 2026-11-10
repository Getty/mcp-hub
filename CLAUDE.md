# MCP::Hub

A single HTTP MCP server that embeds any number of stdio, remote-HTTP and in-process Perl
MCP servers and hands each of them to every agent on the machine as its own endpoint —
run once per machine, started lazily. Perl / Mojolicious distribution `MCP-Hub`, released
with the `[@Author::GETTY]` Dist::Zilla bundle.

## Delegation

Delegate behavior-relevant code to the right agent instead of touching it yourself — the
principle is the shared rule `getty-agent-delegation` (skilletor bundle `getty-cpan-dist@getty`);
the full lane definition and the hazards live in `.claude/rules/mcp-hub-rules.md`.

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code | `mcp-hub-worker` (default) |
| Write/extend tests | `mcp-hub-test-writer` |
| Standalone binary (PAR::Packer), its scripts and release workflow | `mcp-hub-binary-worker` |
| Commits, `Changes`, card → done, pre-release audit | `mcp-hub-release-manager` |
| Read-only research, audit, gap analysis | `mcp-hub-worker` ("read-only, change nothing") |

Every subagent is a `mcp-hub-*` agent — never the built-in `general-purpose`/`Explore`/`Plan`.

The agents carry their skills via `briefing.skills` (see `.claude/agents/`); the main
agent delegates rather than loading them. Project skills live under `.claude/skills/`:
`mcp-hub-core` (architecture, invariants) and `mcp-hub-runtime` are this repo's own; the
shared Perl/Mojo/MCP/Docker/release skills are installed by skilletor from
`.claude/skilletor.json` and not tracked.

## Coordination & verification

- Work is tracked on this repo's **karr** board (`karr board`). One distribution, one
  board.
- Canonical test run: **`prove -lr t/`** — recursive; `prove -l t/` silently skips the
  `t/native/` and `t/upstream/` subdirs. `dzil test` is the release-time equivalent.
