import Foundation
import os

/// Events derived from diffing consecutive alert sets.
public enum WatchdogEvent: Sendable, Equatable, Codable {
    /// Alert appeared (was not present previously).
    case appeared(Alert)
    /// Alert remained firing but severity rose.
    case escalated(Alert, previousSeverity: Severity)
    /// Alert is no longer firing.
    case cleared(Alert.ID)

    // MARK: - Codable
    //
    // Single-tag JSON layout shared across the four bridge channels
    // (JSONL line / REST response / SSE frame / MCP tool result):
    //
    //   {"kind":"appeared","alert":{...}}
    //   {"kind":"escalated","alert":{...},"previous_severity":"warn"}
    //   {"kind":"cleared","alert_id":"disk:/"}
    //
    // Tag = `kind`. Payload keys are `alert`, `previous_severity`,
    // `alert_id` — matching DESIGN §3 channel-schema parity language.

    private enum CodingKeys: String, CodingKey {
        case kind
        case alert
        case previousSeverity = "previous_severity"
        case alertID = "alert_id"
    }

    private enum Kind: String, Codable {
        case appeared, escalated, cleared
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .appeared(let alert):
            try c.encode(Kind.appeared, forKey: .kind)
            try c.encode(alert, forKey: .alert)
        case .escalated(let alert, let prev):
            try c.encode(Kind.escalated, forKey: .kind)
            try c.encode(alert, forKey: .alert)
            try c.encode(prev, forKey: .previousSeverity)
        case .cleared(let id):
            try c.encode(Kind.cleared, forKey: .kind)
            try c.encode(id, forKey: .alertID)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .appeared:
            self = .appeared(try c.decode(Alert.self, forKey: .alert))
        case .escalated:
            let alert = try c.decode(Alert.self, forKey: .alert)
            let prev = try c.decode(Severity.self, forKey: .previousSeverity)
            self = .escalated(alert, previousSeverity: prev)
        case .cleared:
            self = .cleared(try c.decode(String.self, forKey: .alertID))
        }
    }
}

/// Diffs consecutive `Alert` sets and emits `WatchdogEvent`s.
///
/// State is held inside the actor: each call to `step(currentAlerts:)` is
/// compared against the previously-stored snapshot keyed by `Alert.id`,
/// then the snapshot is replaced. This makes the actor the single source
/// of truth for "what was firing the previous turn" — callers only need
/// to feed the current sample.
///
/// Idempotence: an alert that fires at the same severity across consecutive
/// turns produces **no** event. Only level transitions (appear / escalate
/// / clear) are surfaced. De-escalation back to a lower severity is treated
/// as the *same* alert continuing (no event) — explicit "downgrade" events
/// are intentionally not modelled in Phase 3; revisit if Phase 4 channels
/// need them.
public actor Watchdog {

    private var previousAlertsByID: [Alert.ID: Alert] = [:]
    private let stateURL: URL?
    private static let log = os.Logger(subsystem: "place.unicorns.uzora", category: "watchdog")

    /// Construct a watchdog. When `stateURL` is provided, the previous
    /// alert set is persisted there after every `step()` and reloaded on
    /// init — making `appeared`/`cleared` events **idempotent across
    /// process restarts** (a long-lived warn that survives a relaunch
    /// won't re-emit `appeared`).
    ///
    /// Pass `nil` (the default) for tests or contexts that want a fresh,
    /// memory-only watchdog every time.
    public init(stateURL: URL? = nil) {
        self.stateURL = stateURL
        if let url = stateURL {
            Self.loadState(from: url, into: &previousAlertsByID)
        }
    }

    private static func loadState(
        from url: URL,
        into target: inout [Alert.ID: Alert]
    ) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loaded = try decoder.decode([String: Alert].self, from: data)
            target = loaded
            log.info("watchdog state restored: \(loaded.count, privacy: .public) prior alert(s) from \(url.lastPathComponent, privacy: .public)")
        } catch {
            log.error("watchdog state load failed: \(String(describing: error), privacy: .public); starting fresh")
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
            let data = try encoder.encode(previousAlertsByID)
            // Atomic write: write to .tmp then rename.
            let tmpURL = url.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
        } catch {
            Self.log.error("watchdog state persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Per-probe step: compare ONLY this probe's currently-firing alerts
    /// against this probe's slice of the previously-stored snapshot.
    ///
    /// This is the production-correct API: each probe reports independently
    /// (different `pollInterval`s, parallel `Task` loops), and the
    /// scheduler calls Watchdog per-probe rather than aggregating across
    /// all probes. The full-set `step(currentAlerts:)` below treats the
    /// input as a complete snapshot, which is wrong when some probes have
    /// not yet reported in a cold-start (it would emit false `cleared`
    /// events for alerts whose probe simply hasn't ticked yet).
    public func step(probe: String, currentAlerts: [Alert]) -> [WatchdogEvent] {
        var events: [WatchdogEvent] = []
        let currentByID: [Alert.ID: Alert] = Dictionary(
            uniqueKeysWithValues: currentAlerts.map { ($0.id, $0) }
        )
        let previousForProbe: [Alert.ID: Alert] = previousAlertsByID.filter { _, a in a.probe == probe }

        for alert in currentAlerts {
            if let prev = previousForProbe[alert.id] {
                if prev.severity < alert.severity {
                    events.append(.escalated(alert, previousSeverity: prev.severity))
                }
                // Same / lower severity: silent (idempotent).
            } else {
                events.append(.appeared(alert))
            }
        }

        let clearedIDs = previousForProbe.keys.filter { currentByID[$0] == nil }.sorted()
        for id in clearedIDs {
            events.append(.cleared(id))
        }

        // Did this probe's persisted slice actually change? A *de-escalation*
        // (critical→warn) yields NO event (the "same/lower severity is silent"
        // branch) yet the stored Alert changes (lower severity, new
        // lastUpdated). If we persisted only on `!events.isEmpty` the on-disk
        // state would keep the stale HIGHER severity and a restart would seed
        // StateStore wrong. So compute a dirty flag from the slice diff and
        // persist on ANY change, event or not.
        let sliceChanged = Self.sliceDiffers(old: previousForProbe, new: currentByID)

        // Atomically replace this probe's slice of the persisted snapshot.
        previousAlertsByID = previousAlertsByID.filter { _, a in a.probe != probe }
        for (id, alert) in currentByID {
            previousAlertsByID[id] = alert
        }

        if sliceChanged {
            persistState()
        }
        return events
    }

    /// True if the persisted alert slice differs in a way that matters for the
    /// state restored on the next launch — i.e. the id set changed (add/remove)
    /// OR an existing id's **severity** changed. Drives the persist decision so
    /// a silent *de-escalation* (critical→warn, which emits no event) still
    /// hits disk; otherwise a restart would reload the stale higher severity
    /// and seed StateStore wrong.
    ///
    /// Deliberately compares **severity only**, not the whole `Alert`: a probe
    /// re-reporting the same alert at the same severity bumps `lastUpdated`
    /// every tick, and rewriting the state file on every idempotent re-sample
    /// would be wasteful disk churn (and breaks the documented
    /// "idempotent tick doesn't rewrite" invariant). Severity is the only
    /// persisted field the restart-seed logic actually keys on.
    private static func sliceDiffers(old: [Alert.ID: Alert], new: [Alert.ID: Alert]) -> Bool {
        if old.count != new.count { return true }
        for (id, alert) in new {
            guard let prev = old[id] else { return true }
            if prev.severity != alert.severity { return true }
        }
        return false
    }

    /// Full-snapshot step: compare ALL currently-firing alerts (across
    /// every probe) against the prior full set held in the actor.
    ///
    /// Useful for unit tests and contexts where the caller already has the
    /// aggregated set. In production code prefer `step(probe:currentAlerts:)`
    /// — see that method's docs for why per-probe semantics are correct.
    ///
    /// Event order: appearances + escalations are returned in the order
    /// `currentAlerts` is presented; clearances are appended at the end
    /// in stable sorted-by-id order. This keeps EventBus subscriber output
    /// deterministic for testing.
    public func step(currentAlerts: [Alert]) -> [WatchdogEvent] {
        var events: [WatchdogEvent] = []
        var currentByID: [Alert.ID: Alert] = [:]

        for alert in currentAlerts {
            currentByID[alert.id] = alert
            if let prev = previousAlertsByID[alert.id] {
                if prev.severity < alert.severity {
                    events.append(.escalated(alert, previousSeverity: prev.severity))
                }
                // Same or lower severity: silent (idempotent).
            } else {
                events.append(.appeared(alert))
            }
        }

        // Cleared = was present, no longer is. Sort by id for stable order.
        let clearedIDs = previousAlertsByID.keys
            .filter { currentByID[$0] == nil }
            .sorted()
        for id in clearedIDs {
            events.append(.cleared(id))
        }

        // De-escalation (critical→warn) emits no event but changes the stored
        // severity — persist on any severity/id change, not just on events, so
        // a restart doesn't reload a stale higher severity. (See
        // `sliceDiffers` for why severity-only.)
        let snapshotChanged = Self.sliceDiffers(old: previousAlertsByID, new: currentByID)

        previousAlertsByID = currentByID
        if snapshotChanged {
            // Persist when the snapshot's id-set or any severity changed;
            // idempotent ticks (same alerts, same severities) leave the file
            // alone.
            persistState()
        }
        return events
    }

    /// Legacy signature kept for Phase 1+2 call-sites; computes a diff
    /// against a caller-provided previous map without touching internal
    /// state. Useful for pure unit tests of the diff algorithm itself.
    public func diff(previous: [Alert.ID: Alert], current: [Alert]) -> [WatchdogEvent] {
        var events: [WatchdogEvent] = []
        var currentByID: [Alert.ID: Alert] = [:]
        for alert in current {
            currentByID[alert.id] = alert
            if let prev = previous[alert.id] {
                if prev.severity < alert.severity {
                    events.append(.escalated(alert, previousSeverity: prev.severity))
                }
            } else {
                events.append(.appeared(alert))
            }
        }
        let clearedIDs = previous.keys.filter { currentByID[$0] == nil }.sorted()
        for id in clearedIDs {
            events.append(.cleared(id))
        }
        return events
    }

    /// Reset to "no prior alerts". Used by tests; the production app
    /// holds Watchdog for the lifetime of the process. Also wipes the
    /// persisted state file (if any) so the next process starts fresh.
    public func reset() {
        previousAlertsByID = [:]
        if let url = stateURL, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Snapshot of the currently-stored prior alert state. Read-only.
    public func snapshot() -> [Alert.ID: Alert] {
        previousAlertsByID
    }

    /// Boot-time reconciliation: drop every persisted alert whose owning probe
    /// is NOT in `registeredProbeNames`, and return the `.cleared` events for
    /// the dropped ids (so the caller can ingest them into StateStore /
    /// EventBus). The persisted slice is rewritten to disk so a relaunch can't
    /// resurrect the stale alerts.
    ///
    /// Mirrors the dropped-probe cleanup `ProbeRegistry.reconfigure(_:)` does
    /// for a hot-reload, but for the cold-start path: `loadState` applies no
    /// enabled-filter, so without this a probe the user disabled between runs
    /// would have its alert seeded into every read surface yet never tick to
    /// clear it. Returns an empty array (and touches nothing) when every
    /// persisted alert belongs to a still-registered probe.
    @discardableResult
    public func reconcileAgainstRegistered(_ registeredProbeNames: Set<String>) -> [WatchdogEvent] {
        let droppedProbes = Set(previousAlertsByID.values.map { $0.probe })
            .subtracting(registeredProbeNames)
        guard !droppedProbes.isEmpty else { return [] }
        var clears: [WatchdogEvent] = []
        for name in droppedProbes.sorted() {
            // Empty current set for this probe → `.cleared` per outstanding
            // alert + purge from the persisted slice (step persists the change).
            clears.append(contentsOf: step(probe: name, currentAlerts: []))
        }
        return clears
    }
}
