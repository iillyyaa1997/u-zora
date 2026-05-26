# Contributing to uZora

Thanks for the interest. uZora is a personal spare-time project, so
contributions are welcome but slow to be merged. The bar for accepting
a PR is "I would have written this myself, eventually" rather than
"this fits a formal roadmap" — small, surgical changes are easiest to
review.

## Communication

- **GitHub Issues** is the only channel. No Discord, Slack, or chat.
- File bugs against [github.com/iillyyaa1997/u-zora/issues](https://github.com/iillyyaa1997/u-zora/issues)
  using the `bug.md` template.
- File feature ideas using `feature.md` — they may sit a long time;
  not every idea fits the menubar / single-process / Apple-Silicon-only
  shape uZora is intentionally bounded by.

## Development setup

- macOS 26 Tahoe or newer on Apple Silicon. Build is **not** Intel
  compatible — several probes (`cpu_temp` SMC key set, `kernel_task`
  thermal-throttle correlation) only behave usefully on AS hardware.
- Swift 6 toolchain via Xcode 26.0 or the standalone `swift-tools-version`
  matching `Package.swift`.

```sh
git clone https://github.com/iillyyaa1997/u-zora.git
cd u-zora
swift build               # debug
swift test --parallel     # full suite
swift build -c release    # release binary at .build/release/uZora
```

The repo has no third-party SPM dependencies — SQLite ships with macOS
and is linked through Darwin's `SQLite3` module.

## Code style

- Standard Swift conventions; 4-space indent. The repo includes an
  `.editorconfig`.
- `swift format` (Apple) is the canonical formatter. The project does
  not yet have a `.swift-format` config — if you add one, use the
  Apple defaults.
- Prefer pure functions for threshold logic — factor decisions out of
  `Probe.run()` so they can be unit-tested without IOKit. Every
  existing probe follows this pattern (see `BatteryProbe.evaluate(...)`
  or `KernelTaskProbe.evaluate(...)`).
- All async types should be `actor` or `Sendable struct`; `class` is
  reserved for IOKit-handle wrappers that genuinely need reference
  semantics and are `@unchecked Sendable`.
- Logging via `os.Logger`. Subsystem is `place.unicorns.uzora`;
  category per file (`Logger(subsystem: ..., category: "disk")`).

## Tests

- Add tests for every new threshold ladder, every parsed format
  (`nettop`, SMC key payloads, etc.), and every channel handler.
- Run with `swift test --parallel`. All 197+ tests should pass on a
  clean checkout.
- "Live" tests that touch real hardware (under `SmokeIntegration.swift`,
  `HardwareProbeFixturesPlaceholder.swift`) must degrade gracefully
  when the hardware fixture is absent (return early with a logged
  skip rather than failing CI).

## Adding a new probe

1. Implement the `Probe` protocol in `Sources/uZora/Probes/`.
2. Factor the decision logic into a `static func severity(...)` (or
   `evaluate(...)`) so it can be tested without IOKit.
3. Register it in `ProbeRegistry.installDefaultProbes()`.
4. _(Optional but encouraged)_ Implement `currentMetrics()` so the
   probe's numeric readings flow into SQLite + the popover sparkline.
5. Add a `XxxThresholdTests.swift` (pure unit tests of the decision
   function) and a smoke test in `SmokeIntegration.swift` that
   exercises the live sampler.
6. Add a per-probe section to `Resources/sample-config.toml` if it
   has user-tunable thresholds.

## Pull-request process

1. Branch from `master`. (Note: `master`, not `main` — historical.)
2. Make the change. Run `swift test --parallel` and confirm green.
3. Update `CHANGELOG.md` under `[Unreleased]`. Use the existing
   "Phase N" framing if your change closes a planned slice; otherwise
   group it under `### Added` / `### Changed` / `### Fixed`.
4. Open the PR using `.github/PULL_REQUEST_TEMPLATE.md`. Link any
   related issue with `Fixes #N`. Confirm the "swift test --parallel
   passes locally" checkbox.
5. Be patient. This is a spare-time project; reviews can be slow.

## What is _out of scope_

- Intel Mac support
- iOS / iPadOS app (a future "push to iPhone" feature uses ntfy.sh; no
  native iOS UI is planned)
- Cloud sync / multi-machine federation — uZora is per-host
- Telemetry / opt-in analytics — won't ship under any flag
- Public HTTP bind — loopback-only is a hard architectural invariant
  (`ADR-0002`); see also `NWListener.acceptLocalOnly = true` in
  `HTTPServer.start()`

## License

By submitting a PR you agree your contribution is licensed under
the MIT license that covers the rest of the project. See
[LICENSE](LICENSE).
