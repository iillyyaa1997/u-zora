# uZora

Native macOS menubar agent for Apple Silicon Mac health and resource-hogs
monitoring. LLM-agnostic via MCP + JSONL + HTTP REST + SSE.

[![Build](https://img.shields.io/badge/build-passing-brightgreen)](https://github.com/iillyyaa1997/u-zora/actions)
[![Tests](https://img.shields.io/badge/tests-197%20passing-brightgreen)](#)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![macOS 26 Tahoe+](https://img.shields.io/badge/macOS-26%20Tahoe%2B-black)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/arch-Apple%20Silicon-black)](https://support.apple.com/en-us/HT211814)

uZora (from Russian "zarya" — sunrise) sits in your menu bar, polls ten built-in probes
(disk, CPU temperature, thermal pressure, battery, SMART, fans,
`kernel_task`, top CPU/memory/network processes) and surfaces problems
through native UN notifications, a popover dashboard with live charts,
and four LLM-friendly bridge channels.

> **Status — MVP.** All Phase 1–6 features land in this build: probes,
> orchestration, channels, popover UI, Settings, notifications, TOML
> config, i18n EN+RU, SQLite metrics history. See
> [CHANGELOG.md](CHANGELOG.md). Personal spare-time project; issues
> welcome, support is not guaranteed.

## Screenshots

_Screenshots will land alongside the first signed release — see
[Releases](https://github.com/iillyyaa1997/u-zora/releases)._

- Menu-bar status indicator (sunrise icon tints to severity)
- Popover dashboard: active alerts, system overview tiles with
  Swift Charts sparklines, top processes, channel status
- Settings window: per-probe thresholds, channel toggles,
  notification floor, power-profile overrides
- macOS notification banner with 1-click action buttons

## Features

- **Ten built-in probes** running on independent schedulers
    - `disk` — boot drive free space via `statfs`
    - `cpu_temp` — Apple Silicon SMC thermal keys
    - `thermal` — `ProcessInfo.thermalState` pressure
    - `battery` — `IOPS` + `AppleSmartBattery` (charge, cycles,
      wattage in/out, condition string)
    - `smart` — NVMe health log (available spare, percentage used,
      media errors, critical warning bitmask)
    - `fan` — SMC `FNum` / `F<n>Ac` keys (no-ops on fanless devices)
    - `kernel_task` — thermal-throttling indicator with sustained
      windows (>25%/30s warn, >50%/60s critical)
    - `top_cpu` — top-5 CPU consumers with sustained-window thresholds
    - `top_mem` — top-N RSS hogs vs. host total memory
    - `top_net` — per-process bytes/sec via `nettop -L 1 -J` parse
- **Four LLM-agnostic channels**, all loopback-only by design
    - **JSONL** event log at `~/Library/Application
      Support/uZora/events/events-YYYY-MM-DD.jsonl` (daily rotated,
      configurable retention)
    - **HTTP REST** at `127.0.0.1:39842/{status,alerts,probes,metrics}`
    - **SSE** stream at `GET /stream` (replays last N + live tail)
    - **MCP** JSON-RPC 2.0 at `POST /mcp` — five tools:
      `uzora_status`, `uzora_list_alerts`, `uzora_get_probe_metrics`,
      `uzora_get_probe_details`, `uzora_subscribe`
- **SQLite metrics history** (Phase 6) — every probe's numeric readings
  persisted to `metrics.sqlite` with 7-day retention; `GET /metrics`
  returns timeseries JSON
- **Popover dashboard** — SwiftUI + Swift Charts sparklines, header
  uptime + power-state pill, active alerts ranked by severity
- **TOML configuration** with hot-reload (file-watcher → debounced
  reload within ~150ms)
- **Settings window** — per-probe enables, channel toggles, banner
  severity floor, login-item registration, theme + language
- **Native notifications** with per-probe 1-click action categories
  (Snooze 1h / Open dashboard / Acknowledge)
- **Localization** — String Catalog (English + Russian)
- **Power-aware** — five power profiles (AC open/closed, battery
  open/closed, Focus) drive per-poll-cadence multipliers and an
  alert-severity floor

## Requirements

- **macOS 26 Tahoe** or newer
- **Apple Silicon** — M1, M2, M3, M4+ family (arm64 only; Intel Macs
  are unsupported because the SMC / IOReport key sets and the
  `kernel_task` thermal-throttle behaviour are AS-specific)
- ~5 MB RAM resident, single menu-bar process

## Installation

### 1. Homebrew cask _(planned)_

```sh
brew install --cask iillyyaa1997/tap/u-zora  # TBD when first tag ships
```

### 2. DMG from Releases _(planned)_

Download the latest `.dmg` from [Releases](https://github.com/iillyyaa1997/u-zora/releases),
mount, drag `uZora.app` to `/Applications`, and launch.

### 3. Build from source

```sh
git clone https://github.com/iillyyaa1997/u-zora.git
cd u-zora
swift build -c release

# bundle into uZora.app
mkdir -p uZora.app/Contents/MacOS
cp .build/release/uZora uZora.app/Contents/MacOS/
cp Sources/uZora/Support/Info.plist uZora.app/Contents/
codesign --sign - --deep --force uZora.app
open uZora.app
```

The bare binary at `.build/release/uZora` also runs — the linker embeds
`Info.plist` into the Mach-O `__TEXT,__info_plist` section so it is
treated as `LSUIElement` (menubar-only) even without a `.app` wrapper.

## Configuration

uZora reads `~/Library/Application Support/uZora/config.toml`,
auto-generated on first launch from the bundled template. See
[`Resources/sample-config.toml`](Resources/sample-config.toml) for the
full schema. Edits are picked up via file-watcher within ~150ms — no
restart needed.

Common knobs:

```toml
[general]
start_at_login = false
language = "system"      # "system" | "en" | "ru"
theme = "system"         # "system" | "light" | "dark"
log_retention_days = 30

[http]
enabled = true
port = 39842

[mcp]
enabled = true

[notifications]
banner_severity_floor = "warn"   # "info" | "warn" | "critical"
respect_focus = true             # warn banners muted during Focus

[probes.cpu_temp]
enabled = true
warn_threshold = 90
critical_threshold = 100
```

## LLM integration

All four channels speak the same payload shape (DESIGN §3 cross-channel
parity): top-level `kind` discriminator + `alert` / `previous_severity`
/ `alert_id` fields.

### Claude Code / MCP

Add this to `~/.claude/mcp.json` (or wherever your client reads MCP
servers from):

```json
{
  "mcpServers": {
    "uzora": {
      "command": "curl",
      "args": [
        "-N",
        "--http1.1",
        "-X", "POST",
        "http://127.0.0.1:39842/mcp",
        "-H", "Content-Type: application/json",
        "--data-binary", "@-"
      ]
    }
  }
}
```

Then in Claude Code ask: _"What's my Mac's current thermal state?"_ and
the model will call `uzora_status` / `uzora_list_alerts`.

### Cursor / generic JSON-RPC

```jsonc
// .cursor/mcp.json
{
  "mcpServers": {
    "uzora": {
      "url": "http://127.0.0.1:39842/mcp",
      "transport": "http"
    }
  }
}
```

### JSONL log tailing

```sh
tail -F ~/Library/Application\ Support/uZora/events/events-$(date +%F).jsonl \
  | jq -c 'select(.kind == "appeared" and .alert.severity == "critical")'
```

### HTTP REST quick test

```sh
curl -s http://127.0.0.1:39842/status   | jq
curl -s http://127.0.0.1:39842/alerts   | jq
curl -s http://127.0.0.1:39842/probes   | jq
curl -s 'http://127.0.0.1:39842/metrics?probe=cpu_temp&name=temp_c' | jq
```

### SSE live stream

```sh
curl -N http://127.0.0.1:39842/stream
# event: appeared
# data: {"alert":{"probe":"disk", ...}, "kind":"appeared"}
```

## Architecture

```
┌──── Probe layer (10 probes) ─── samplers + thresholds
│
├──── Watchdog ──── diffs current vs. previous alert set
│
├──── EventBus ──── pub/sub for WatchdogEvent
│
├──── StateStore + MetricsStore (SQLite)
│      │
│      └─── ChannelHost
│            ├── JSONLEventSink   (daily-rotated file)
│            ├── HTTPServer       (REST + /metrics + /stream)
│            └── MCPServer        (POST /mcp JSON-RPC 2.0)
│
└──── PowerProfileMonitor → drives poll cadence + alert floor
```

Three guarantees enforced by tests (`SmokeIntegration.swift`,
`ChannelHostTests.swift`):

1. **Cross-channel payload parity** — same event renders identically in
   JSONL, REST, SSE, and MCP `notifications/uzora.event`.
2. **Loopback-only HTTP** — `NWListener.acceptLocalOnly = true` is the
   kernel-level enforcement (`ADR-0002`).
3. **Watchdog idempotence** — repeating the same alert at the same
   severity produces zero events.

The full SDLC artifact tree (PRD, DESIGN, ADRs) lives in the parent
`u-pilot/architecture/u-zora/` Cypilot workspace.

## Status

Personal spare-time OSS project. Issues welcome at
[github.com/iillyyaa1997/u-zora/issues](https://github.com/iillyyaa1997/u-zora/issues);
support is not guaranteed.

## Roadmap

Confirmed for **Phase 7+**:

- SQLite downsampling (15-min / 1-h buckets for >7 day history)
- Sparkle auto-update channel
- Focus-mode detection (replace the Phase-6 `focusActive=false` stub)
- MCP notifications served via MCP transport itself rather than
  redirecting to SSE
- Push to iPhone via ntfy.sh (optional, opt-in)
- Multi-volume disk probe (currently boot drive only)
- IOReport private framework integration (per-cluster temps with
  proper entitlement)
- `powermetrics`-backed deep-diagnostics view (on-demand, sudo'd)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports and feature requests
on the [issue tracker](https://github.com/iillyyaa1997/u-zora/issues).

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

uZora stands on the shoulders of several macOS-monitoring projects that
solved hard pieces of this domain ahead of time:

- [Stats](https://github.com/exelban/stats) — comprehensive menubar
  stats app; reference for SMC key sets
- [Hammerspoon](https://www.hammerspoon.org) — proved Lua-based macOS
  automation works via the same IOKit surface uZora uses from Swift
- [macmon](https://github.com/vladkens/macmon) — Apple Silicon power +
  thermal CLI; reference for IOReport channel groups
- [MacThrottle](https://github.com/notnotrobby/MacThrottle) — surfaced
  the `kernel_task` CPU% → thermal-throttling correlation that powers
  the `kernel_task` probe
