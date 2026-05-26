# Changelog

All notable changes to uZora are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Phase 1** — Skeleton: `Probe` protocol, `Watchdog`, `Severity`,
  `Alert`, `ProbeRegistry`, menubar shell with `LSUIElement`, MIT
  license, package layout for Swift 6 + macOS 26.
- **Phase 2** — Six MVP probes (`disk`, `cpu_temp`, `thermal`,
  `battery`, `smart`, `fan`) wired to live IOKit / SMC / IOPS APIs;
  pure threshold functions factored out for unit-testability;
  fanless/no-battery devices degrade to silent no-ops.
- **Phase 3** — Four additional probes (`kernel_task`, `top_cpu`,
  `top_mem`, `top_net`), `PowerProfile` state machine (AC/battery,
  lid open/closed, Focus) driving per-probe poll-cadence multipliers
  and an alert-severity floor; `EventBus` pub/sub layer;
  `ProbeRegistry` scheduler with per-probe async loops.
- **Phase 4** — Four LLM-agnostic channels — JSONL (daily-rotated
  append-only file), HTTP REST (`/status`, `/alerts`, `/probes`,
  `/metrics`), SSE (`/stream`), MCP (`POST /mcp` JSON-RPC 2.0 with
  five tools). All loopback-only, kernel-enforced via
  `NWListener.acceptLocalOnly = true`. Cross-channel payload parity
  verified by `SmokeIntegration.swift`.
- **Phase 5** — SwiftUI popover dashboard with Swift Charts
  sparklines, Settings window covering general + per-probe +
  channels + notifications, `UserNotifications` integration with
  per-probe action categories (Snooze 1h / Open dashboard /
  Acknowledge), TOML configuration with hot-reload via
  `DispatchSource.makeFileSystemObjectSource`, i18n via String
  Catalog (English + Russian).
- **Phase 6** — SQLite metrics persistence via the native `sqlite3`
  C API; `/metrics` REST endpoint returns persisted samples;
  `MetricsStore` actor with 7-day retention purge; `Probe.currentMetrics()`
  optional protocol method (default empty) so probes opt-in to
  surfacing graph data independently of alert state; sparkline
  buffers hydrated from the store on each refresh tick so the
  popover survives session restarts. Top-level docs (README rewrite,
  CHANGELOG, CONTRIBUTING), GitHub issue/PR templates, CI + release
  GHA workflows.

### Known issues

- Focus-mode detection is stubbed (the bridge layer always passes
  `isFocusActive=false` to the notification suppressor). Real
  detection lands in Phase 7.
- `TopNetworkProcessProbe` parses `nettop` CSV output, which can shift
  between macOS releases. Treated as best-effort — on parse failure
  the probe degrades to a logged-once no-op rather than crashing.
- MCP `uzora_subscribe` returns a `sseUrl` field pointing at the
  bridge's `/stream` endpoint rather than serving notifications over
  the MCP transport itself. Spec-compliant MCP notifications-over-HTTP
  land in Phase 7+.
- Multi-volume disk probe is not yet implemented (boot drive only).
- IOReport private-framework integration (per-cluster `pcluster` /
  `ecluster` thermals) deferred until the entitlement / dyld story is
  settled. SMC heuristics ship in MVP.

## [0.1.0] — _planned first tagged release_

The Unreleased section above is the snapshot that will become 0.1.0
once tagged. See the [Roadmap section in README](README.md#roadmap) for
what is queued after that.
