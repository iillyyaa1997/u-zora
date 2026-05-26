---
name: Bug report
about: Something is broken or behaves unexpectedly
title: "[bug] "
labels: bug
---

## What happened

A clear, one-paragraph description of what went wrong.

## What did you expect

A clear, one-paragraph description of the behaviour you expected
instead.

## Reproduction steps

1. ...
2. ...
3. ...

## Environment

- **macOS version** (e.g. 26.0 build `25A123`):
- **Mac model** (e.g. MacBook Pro 14" M2 Pro 2023):
- **uZora version** (from menubar → Settings → About, or
  `defaults read place.unicorns.uzora CFBundleShortVersionString`):
- **Build source** (Homebrew cask / DMG / source `swift build -c release`):

## Logs

- Console.app → search subsystem `place.unicorns.uzora` — paste the
  last 50 lines around the failure here, between triple backticks:

```
(paste here)
```

- JSONL event log at `~/Library/Application Support/uZora/events/` —
  attach the latest day's file if the bug involves alert state.

## Additional context

Anything else: workload that triggered it, related to a specific app,
recent macOS update, OS Recovery, etc.
