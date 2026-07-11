# uZora → Claude-Code channel shim

A tiny **stdio MCP server** that Claude Code spawns as a subprocess. It subscribes
to uZora's `GET /stream` (loopback SSE) and re-emits each event as a
`notifications/claude/channel` notification — the proprietary Claude-Code
**channel** capability that lets uZora **push** system-health events into an open
Claude session so Claude can act on them *while you're away*.

The shim is a **pure external consumer** of uZora's already-shipped HTTP surface —
it modifies **no uZora Swift code**. Every non-Claude client keeps pulling
`/status`, `/findings`, `/verdict`, etc.; only Claude Code gets the push path.

> One-way for v1: the channel pushes notifications only (no reply tool).

---

## Requirements

- **Claude Code v2.1.80+** — custom channels are a research preview and require
  the development flag (`--dangerously-load-development-channels`) to load.
- **Node v20+** (uses the built-in `fetch`; the bundle targets `node20`).
- uZora running locally with its HTTP channel enabled (default
  `http://127.0.0.1:39842`). The shim tolerates uZora being down — it retries
  with backoff and never crashes the MCP transport.

## Build (already committed)

The self-contained bundle at `dist/uzora-channel.js` is committed, so you can run
it **without an `npm install`**. To rebuild:

```sh
cd channel
npm install
npm run typecheck   # tsc --noEmit
npm run build       # esbuild --bundle → dist/uzora-channel.js (+ dist/package.json)
npm run smoke       # build + end-to-end stdio-MCP smoke test
```

`npm run build` bundles the shim and all its dependencies
(`@modelcontextprotocol/sdk`, `eventsource`) into a single ESM file
`dist/uzora-channel.js` plus a one-line `dist/package.json` (`{"type":"module"}`)
so the `.js` is interpreted as ESM wherever `dist/` is copied. No runtime
`node_modules` is needed.

## Setup in Claude Code

1. Add an `.mcp.json` (project- or user-scoped) that points at the built bundle
   with an **absolute path**:

   ```json
   {
     "mcpServers": {
       "uzora": {
         "command": "node",
         "args": ["/absolute/path/to/uzora/channel/dist/uzora-channel.js"],
         "env": {
           "UZORA_STREAM_URL": "http://127.0.0.1:39842/stream",
           "UZORA_MIN_SEVERITY": "warn"
         }
       }
     }
   }
   ```

   If you run the copy shipped inside the app bundle, the path is
   `/Applications/uZora.app/Contents/Resources/channel/dist/uzora-channel.js`.

2. Launch Claude Code with the development-channels flag, registering `uzora` as a
   channel (not a normal tool server):

   ```sh
   claude --dangerously-load-development-channels server:uzora
   ```

   You'll be asked to **approve the server once**. After that, uZora events arrive
   in-session as `<uzora …>` tags.

## Configuration (env vars)

| Env var              | Default                          | Meaning |
| -------------------- | -------------------------------- | ------- |
| `UZORA_STREAM_URL`   | `http://127.0.0.1:39842/stream`  | uZora SSE endpoint to subscribe to. |
| `UZORA_MIN_SEVERITY` | `warn`                           | Noise filter: `info` \| `warn` \| `critical` (see below). |
| `UZORA_TOKEN`        | *(unset)*                        | Optional bearer token sent as `Authorization: Bearer …` on the SSE connect. Harmless today (`/stream` is an ungated read) — future-proofs a gated stream. |

### Severity filter (`UZORA_MIN_SEVERITY`)

Controls how much raw-alert chatter is forwarded. The **diagnosis-layer** events
(`diagnosed` / `rediagnosed` / `resolved` / `verdict_changed`) are **always
forwarded** — they are the high-value, low-volume proactive-diagnosis signals.
Raw watchdog transitions are severity-gated:

| Event                 | Forwarded when… |
| --------------------- | --------------- |
| `appeared`            | `alert.severity >= UZORA_MIN_SEVERITY` |
| `escalated`           | `alert.severity >= UZORA_MIN_SEVERITY` |
| `cleared`             | only when `UZORA_MIN_SEVERITY = info` (no severity on the event → treated as info-level) |
| `diagnosed` / `rediagnosed` / `resolved` / `verdict_changed` | **always** |

At the default **`warn`**: `warn`+`critical` `appeared`/`escalated` and every
diagnosis/verdict event pass; `info`-level alerts and raw `cleared` are suppressed
as chatter. Set `critical` to forward only critical alert transitions, or `info`
to forward everything.

## Event → notification mapping

Each surviving event becomes a fire-and-forget JSON-RPC notification:

```jsonc
{ "method": "notifications/claude/channel",
  "params": { "content": "<one-line summary>", "meta": { /* tag attributes */ } } }
```

`content` becomes the `<uzora>` tag body; each `meta` key/value becomes a tag
attribute. **`meta` keys are always identifier-safe** (letters/digits/underscore);
hyphenated keys would be silently dropped by Claude Code, so the shim only emits
snake_case keys and defensively filters anything else. `source` is added
automatically by Claude from the server name (`uzora`).

| SSE event          | `content` (example)                                                                                              | `meta` keys |
| ------------------ | --------------------------------------------------------------------------------------------------------------- | ----------- |
| `appeared`         | `uZora alert appeared: Disk 98% full [severity=critical, id=disk:/]`                                             | `kind`, `alert_id`, `severity` |
| `escalated`        | `uZora alert escalated: CPU 99C [warn -> critical, id=cpu_temp:cpu]`                                             | `kind`, `alert_id`, `severity`, `previous_severity` |
| `cleared`          | `uZora alert cleared: disk:/`                                                                                    | `kind`, `alert_id` |
| `diagnosed`        | `uZora diagnosed: ecosystemd is spinning the CPU — suggested: restart ecosystemd [severity=warn, confidence=high, subject=ecosystemd]` | `kind`, `finding_id`, `severity`, `subject` |
| `rediagnosed`      | `uZora re-diagnosed: … [warn -> critical, confidence=high, subject=ecosystemd]`                                  | `kind`, `finding_id`, `severity`, `subject`, `previous_severity` |
| `resolved`         | `uZora finding resolved: runaway_daemon:ecosystemd`                                                              | `kind`, `finding_id` |
| `verdict_changed`  | `uZora system verdict good -> degraded: CPU sustained high`                                                      | `kind`, `level`, `previous_level` |

Notes:
- `alert_id` = `<probe>:<key>` — uZora's `Alert.id` is a computed property and is
  **not** encoded in the SSE JSON, so the shim reconstructs it from `alert.probe`
  and `alert.key`.
- `finding_id` = `<detector>:<subject>`, matching the id uZora emits directly in
  the `resolved` event so `diagnosed`↔`resolved` correlate.

## Lifecycle

- **uZora down at spawn** → the shim keeps the MCP transport alive and retries the
  SSE connection with exponential backoff (500 ms → 15 s cap). A dead stdio server
  would show as *"Failed to connect"* in Claude Code, so the shim never crashes on
  an unreachable stream.
- **SSE drop mid-session** → the connection is closed and reconnected with the same
  backoff; the backoff resets on a healthy reconnect. Handler errors are logged to
  **stderr** (stdout is the MCP JSON-RPC channel) and never thrown.

## Files

| File                     | Purpose |
| ------------------------ | ------- |
| `uzora-channel.ts`       | The shim: stdio MCP `Server` + SSE client + `mapEvent`/`passesSeverity`. |
| `dist/uzora-channel.js`  | Committed self-contained ESM bundle (run with `node`). |
| `dist/package.json`      | `{"type":"module"}` marker so the bundle is ESM anywhere it's copied. |
| `package.json`           | Deps + `build` / `typecheck` / `smoke` scripts. |
| `tsconfig.json`          | Strict TS config (NodeNext ESM) for `typecheck`. |
| `smoke-test.mjs`         | End-to-end stdio-MCP smoke test + pure `mapEvent` unit assertions. |
