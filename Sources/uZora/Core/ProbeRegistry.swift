import Foundation

/// Holds registered probes and runs them on a schedule.
///
/// Phase 1: storage + lifecycle methods only. Scheduling/dispatch logic
/// arrives in a later phase.
public actor ProbeRegistry {
    private var probes: [String: any Probe] = [:]
    private var lastSnapshot: [Alert] = []
    private var isRunning: Bool = false

    public init() {}

    /// Register a probe. Replaces any existing probe with the same `name`.
    public func register(_ probe: any Probe) {
        probes[probe.name] = probe
    }

    /// Currently registered probe names (stable order: sorted).
    public func registeredNames() -> [String] {
        probes.keys.sorted()
    }

    /// Begin scheduled polling. Idempotent.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        // TODO Phase 1+: spin up per-probe tasks honoring `pollInterval`,
        // feed results through `Watchdog`, persist events.
        print("ProbeRegistry: started (\(probes.count) probes)")
    }

    /// Stop scheduled polling. Idempotent.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        // TODO Phase 1+: cancel running probe tasks gracefully.
        print("ProbeRegistry: stopped")
    }

    /// Snapshot of the most recent alert set across all probes.
    public func snapshot() -> [Alert] {
        lastSnapshot
    }
}
