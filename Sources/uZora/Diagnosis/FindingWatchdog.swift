import Foundation
import os

/// Events derived from diffing consecutive `Finding` sets.
///
/// A SIBLING of `WatchdogEvent` — NOT an extension of it. `WatchdogEvent` is
/// switched exhaustively across ~10 load-bearing channel/state sites
/// (EventBus / NotificationCenter / ProbeRegistry / StateStore / ActionRunner
/// / SSE / JSONL / format); adding cases there would force a refactor of that
/// code, which plan D2 forbids ("no refactor of load-bearing code"). So the
/// diagnosis layer gets its own parallel event type with its own diff actor.
public enum FindingEvent: Sendable, Equatable, Codable {
    /// Finding appeared (its id was not present previously).
    case diagnosed(Finding)
    /// Finding persisted AND worsened (severity rose OR confidence rose).
    case rediagnosed(Finding, previousSeverity: Severity, previousConfidence: Confidence)
    /// Finding is no longer present.
    case resolved(Finding.ID)

    // MARK: - Codable
    //
    // Single-tag JSON layout mirroring `WatchdogEvent` precisely:
    //
    //   {"kind":"diagnosed","finding":{...}}
    //   {"kind":"rediagnosed","finding":{...},"previous_severity":"warn","previous_confidence":"low"}
    //   {"kind":"resolved","finding_id":"runaway_daemon:ecosystemd"}
    //
    // Tag = `kind`. Payload keys are `finding`, `previous_severity`,
    // `previous_confidence`, `finding_id`.

    private enum CodingKeys: String, CodingKey {
        case kind
        case finding
        case previousSeverity = "previous_severity"
        case previousConfidence = "previous_confidence"
        case findingID = "finding_id"
    }

    private enum Kind: String, Codable {
        case diagnosed, rediagnosed, resolved
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .diagnosed(let finding):
            try c.encode(Kind.diagnosed, forKey: .kind)
            try c.encode(finding, forKey: .finding)
        case .rediagnosed(let finding, let prevSev, let prevConf):
            try c.encode(Kind.rediagnosed, forKey: .kind)
            try c.encode(finding, forKey: .finding)
            try c.encode(prevSev, forKey: .previousSeverity)
            try c.encode(prevConf, forKey: .previousConfidence)
        case .resolved(let id):
            try c.encode(Kind.resolved, forKey: .kind)
            try c.encode(id, forKey: .findingID)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .diagnosed:
            self = .diagnosed(try c.decode(Finding.self, forKey: .finding))
        case .rediagnosed:
            let finding = try c.decode(Finding.self, forKey: .finding)
            let prevSev = try c.decode(Severity.self, forKey: .previousSeverity)
            let prevConf = try c.decode(Confidence.self, forKey: .previousConfidence)
            self = .rediagnosed(finding, previousSeverity: prevSev, previousConfidence: prevConf)
        case .resolved:
            self = .resolved(try c.decode(String.self, forKey: .findingID))
        }
    }
}

/// Diffs consecutive `Finding` sets and emits `FindingEvent`s — the
/// diagnosis-layer sibling of `Watchdog`.
///
/// State is held inside the actor: each `step(currentFindings:)` is compared
/// against the previously-stored snapshot keyed by `Finding.id`, then the
/// snapshot is replaced. Unlike `Watchdog`'s per-probe API, the engine
/// produces the COMPLETE finding set every cycle, so full-snapshot semantics
/// are correct here — there is no cold-start "probe hasn't ticked yet"
/// problem to guard against.
///
/// Idempotence: a finding that re-fires at the same severity AND confidence
/// across consecutive turns produces **no** event. Only worsening transitions
/// (diagnosed / rediagnosed / resolved) are surfaced. A *de-worsening* (back
/// to a lower severity or confidence) is treated as the same finding
/// continuing (no event) — but it still changes the persisted state, so it
/// hits disk (see `sliceDiffers`).
public actor FindingWatchdog {

    private var previousByID: [Finding.ID: Finding] = [:]
    private let stateURL: URL?
    private static let log = os.Logger(subsystem: "place.unicorns.uzora", category: "finding-watchdog")

    /// Construct a watchdog. When `stateURL` is provided, the previous finding
    /// set is persisted there after every `step()` and reloaded on init —
    /// making `diagnosed`/`resolved` events **idempotent across process
    /// restarts** (a persisted finding that survives a relaunch won't re-emit
    /// `diagnosed`).
    ///
    /// Pass `nil` (the default) for tests or contexts that want a fresh,
    /// memory-only watchdog every time.
    public init(stateURL: URL? = nil) {
        self.stateURL = stateURL
        if let url = stateURL {
            Self.loadState(from: url, into: &previousByID)
        }
    }

    private static func loadState(
        from url: URL,
        into target: inout [Finding.ID: Finding]
    ) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loaded = try decoder.decode([String: Finding].self, from: data)
            target = loaded
            log.info("finding-watchdog state restored: \(loaded.count, privacy: .public) prior finding(s) from \(url.lastPathComponent, privacy: .public)")
        } catch {
            log.error("finding-watchdog state load failed: \(String(describing: error), privacy: .public); starting fresh")
        }
    }

    private func persistState() {
        guard let url = stateURL else { return }
        do {
            // Ensure parent dir exists (idempotent).
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(previousByID)
            // Atomic write: write to .tmp then rename.
            let tmpURL = url.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
        } catch {
            Self.log.error("finding-watchdog state persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Full-snapshot step: compare ALL currently-diagnosed findings against
    /// the prior full set held in the actor.
    ///
    /// Event order: diagnoses + rediagnoses are returned in the order
    /// `currentFindings` is presented; resolutions are appended at the end in
    /// stable sorted-by-id order. This keeps subscriber output deterministic.
    public func step(currentFindings: [Finding]) -> [FindingEvent] {
        var events: [FindingEvent] = []
        var currentByID: [Finding.ID: Finding] = [:]

        for finding in currentFindings {
            currentByID[finding.id] = finding
            if let prev = previousByID[finding.id] {
                // Worsened on EITHER axis → rediagnosed (carry both priors).
                if prev.severity < finding.severity || prev.confidence < finding.confidence {
                    events.append(.rediagnosed(
                        finding,
                        previousSeverity: prev.severity,
                        previousConfidence: prev.confidence
                    ))
                }
                // Same / lower on both axes: silent (idempotent).
            } else {
                events.append(.diagnosed(finding))
            }
        }

        // Resolved = was present, no longer is. Sort by id for stable order.
        let resolvedIDs = previousByID.keys
            .filter { currentByID[$0] == nil }
            .sorted()
        for id in resolvedIDs {
            events.append(.resolved(id))
        }

        // A de-worsening (e.g. critical→warn, or high→low confidence) emits no
        // event but changes the stored severity/confidence — persist on ANY
        // such change, not just on events, so a restart doesn't reload a stale
        // higher severity/confidence. (See `sliceDiffers` for why only those
        // two fields drive the persist decision.)
        let snapshotChanged = Self.sliceDiffers(old: previousByID, new: currentByID)

        previousByID = currentByID
        if snapshotChanged {
            // Persist when the snapshot's id-set OR any severity/confidence
            // changed; idempotent ticks (same findings, same severity AND
            // confidence) leave the file alone.
            persistState()
        }
        return events
    }

    /// True if the persisted finding slice differs in a way that matters for
    /// the state restored on the next launch — i.e. the id set changed
    /// (add/remove) OR an existing id's **severity** or **confidence** changed.
    ///
    /// Deliberately compares only severity + confidence, not the whole
    /// `Finding`: a detector re-emitting the same finding bumps `lastUpdated`
    /// every cycle, and rewriting the state file on every idempotent
    /// re-evaluation would be wasteful disk churn (and breaks the documented
    /// "idempotent tick doesn't rewrite" invariant). Severity + confidence are
    /// the only persisted fields the restart-seed/worsening logic keys on.
    private static func sliceDiffers(old: [Finding.ID: Finding], new: [Finding.ID: Finding]) -> Bool {
        if old.count != new.count { return true }
        for (id, finding) in new {
            guard let prev = old[id] else { return true }
            if prev.severity != finding.severity { return true }
            if prev.confidence != finding.confidence { return true }
        }
        return false
    }

    /// Reset to "no prior findings". Used by tests; the production app holds
    /// the watchdog for the lifetime of the process. Also wipes the persisted
    /// state file (if any) so the next process starts fresh.
    public func reset() {
        previousByID = [:]
        if let url = stateURL, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Snapshot of the currently-stored prior finding state. Read-only.
    public func snapshot() -> [Finding.ID: Finding] {
        previousByID
    }
}
