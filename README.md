# uZora

Native macOS menubar agent for Apple Silicon Mac health & resource-hogs monitoring. LLM-agnostic via MCP + JSONL + HTTP REST + SSE.

<!-- badges: TBD (CI, release, license) -->

> **Phase 1 — work-in-progress.** This build ships only the menubar shell (status item + Quit). Probes, alerting, integrations, and UI come in later phases.

## Requirements

- macOS 26 Tahoe or newer
- Apple Silicon (M1 or later) — arm64 only, Intel is not supported

## Build from source

```sh
swift build -c release
```

The resulting executable lives at `.build/release/uZora`. A signed `.app` bundle and installer flow are part of a later phase.

## Install (planned)

Three paths once releases ship:

1. **Homebrew cask** — `brew install --cask <tap>/u-zora` *(TBD)*
2. **DMG** — download from GitHub Releases *(TBD)*
3. **Source build** — instructions above

## License

MIT — see [LICENSE](./LICENSE).

## Issues

Bug reports and feature requests: [github.com/iillyyaa1997/u-zora/issues](https://github.com/iillyyaa1997/u-zora/issues).

## Support

Personal spare-time project. Issues welcome, but support is not guaranteed.
