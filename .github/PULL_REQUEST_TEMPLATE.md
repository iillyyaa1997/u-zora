## Description

A short paragraph describing the change. What does it do? Why?

## Kind of change

- [ ] `feat` — new feature
- [ ] `fix` — bug fix
- [ ] `docs` — documentation only
- [ ] `refactor` — code change that neither adds a feature nor fixes a bug
- [ ] `test` — adding or correcting tests
- [ ] `chore` — build / CI / dependency hygiene

## Related issue

Fixes #<issue-number>  
_(or "n/a" if this is unscoped — e.g. a typo fix)_

## Checklist

- [ ] `swift test --parallel` passes locally on macOS 26 Tahoe + Apple
      Silicon
- [ ] `swift build -c release` succeeds
- [ ] Added/updated tests covering the change
- [ ] Updated `CHANGELOG.md` under `## [Unreleased]`
- [ ] No new SPM dependencies (uZora is dependency-free by design)
- [ ] No new public HTTP binds (loopback only — `ADR-0002`)

## Notes for the reviewer

Anything that needs a second pair of eyes — tricky concurrency
boundaries, IOKit subtleties, parser fragility, etc.
