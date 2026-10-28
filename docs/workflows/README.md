# Repeatable workflows

These are the canonical procedures for humans and agents. Run shell commands
from the repository root. An agent can follow a linked file directly; no
slash-command system, editor integration, or local hook is required.
[AGENTS.md](../../AGENTS.md) owns project policy. Client-specific entry files
may point there, and local shortcuts may point here, but neither should
duplicate these instructions.

| Task | Procedure |
|---|---|
| Group failures and propose fixes without implementing | [Triage](triage.md) |
| Find and fix allocation-pressure GC failures | [GC stress](gc-stress.md) |
| Refresh conformance results | [Score](score.md) |
| Update the test262 corpus and measure the change | [Bump test262](bump-test262.md) |
| Measure a performance change | [Performance](perf.md) |
| Find hot functions with `samply` | [Profile](profile.md) |
| Review verification, results, and docs at session end | [Checkpoint](checkpoint.md) |

Use bounded runs as described in [AGENTS.md](../../AGENTS.md). A configured
[remote runner](../../tools/bench/README.md) is optional; never assume a
particular agent hook or developer machine. Do not commit or push result
updates unless the user requests it. Preserve unrelated working-tree changes.

## Spec lookup

[ECMA-262](https://tc39.es/ecma262/) and [ECMA-402](https://tc39.es/ecma402/)
remain the normative sources. The optional `tc39` entry in
[.mcp.json](../../.mcp.json) connects to the maintained, independent
[xyzzylabs/tc39-mcp](https://github.com/xyzzylabs/tc39-mcp) through local stdio:
`npx --yes tc39-mcp@0.6.5`. This pins the server package version, not the spec
snapshots. It is a lookup aid, not an official Ecma/TC39 publication.

### Local default

Requires Node.js 20 or newer and npm/npx on PATH. `--yes` avoids an interactive
installation prompt. The first launch may download the package; install or
cache it before working without network access. Update the version in
`.mcp.json` and this command together after verifying a new release.

Local does not mean network-disabled: snapshots are cached locally and
refreshed from the hosted service when missing or stale. Bundled snapshots
provide offline fallback, but may lag the working draft. Check the returned
snapshot metadata instead of assuming offline data is current. See the
[upstream setup and cache behavior](https://github.com/xyzzylabs/tc39-mcp#install--first-call).

Use `spec.about` to inspect snapshot metadata, `spec.search` to locate a clause,
and `clause.get` to read it. Specify `spec: "262"` or `"402"` and
`edition: "main"` when following the current working draft: `latest` selects
the stable edition, not the draft. Retain clause links and snapshot SHAs when
citing results. `test262.search` and `proposal.list` cover related fixtures and
proposals.

### Optional HTTP fallback

For clients without local subprocess support or Node/npm, replace the `tc39`
entry in their local configuration with:

```json
{
  "mcpServers": {
    "tc39": {
      "type": "http",
      "url": "https://mcp.xyzzylabs.ai/tc39/mcp"
    }
  }
}
```

This is an optional transport alternative, not automatic failover. Configure
one transport at a time. Clients that do not read `.mcp.json` can use the same
command or endpoint in their own configuration. Without MCP, follow the spec
links directly. A connectivity failure is not evidence that a service is
abandoned; report the error and use the direct sources without silently
deleting the shared configuration.
