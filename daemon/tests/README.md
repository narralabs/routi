# Core tests

`pnpm test` runs the top-level `*.test.ts` files. These tests use temporary data
and fake provider/surface behavior. The HTTP MCP tests connect a real MCP client
to a temporary local server, but do not call Claude, Codex, or Grok, use account
credentials, or launch a browser. They run in CI.

## Optional live Claude check

`live/claude-memory.test.ts` tests the real Claude SDK/CLI integration: saving a
note through HTTP MCP, resuming a session, and falling back from a missing session.

Run explicitly with:

```sh
pnpm --filter routid test:live:claude-memory
```

This command opts into real account usage with `ROUTI_LIVE_TESTS=1`. It uses the
current Claude login and consumes usage. It uses a temporary Routi database and
HTTP server, but Claude may keep test sessions in its local history. It is not run
by `pnpm test` or CI. Do not run it as part of routine checks without requesting
live account usage explicitly.

Prefer synthetic fixtures for routine regression coverage. Never commit raw
provider recordings or local Claude session files: they can contain credentials,
conversation text, local paths, and tool output. Fake tests exercise our behavior;
the optional live check verifies compatibility with the actual vendor runtime.
