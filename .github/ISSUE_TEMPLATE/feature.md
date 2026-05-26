---
name: Feature request
about: Suggest a new feature or improvement
title: "[feat] "
labels: enhancement
---

## What problem does this solve

What you're trying to do that uZora doesn't currently support, or
what existing behaviour is friction-y. Concrete examples help.

## Proposed solution

If you have one in mind, describe it. Otherwise leave this blank — the
problem statement above is the important part.

## Alternatives considered

Workarounds you've tried, or other apps that solve a similar problem
in a way that's worth borrowing from.

## Scope check

uZora is intentionally bounded. Please confirm your request fits:

- [ ] Runs on macOS 26 Tahoe+ on Apple Silicon (Intel Macs are
      unsupported)
- [ ] Does not require a public HTTP bind (loopback only — `ADR-0002`)
- [ ] Does not require cloud sync, telemetry, or any network call to a
      service uZora itself controls
- [ ] Does not require a privileged helper / root daemon for the
      common-case feature

If any of these don't apply your idea might still be useful — open the
issue and we'll discuss.

## Environment

- **Mac model**:
- **macOS version**:
- **uZora version**:
