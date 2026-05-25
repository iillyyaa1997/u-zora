import Foundation
import os

/// Holds registered probes and runs them on a schedule.
///
/// Phase 2: storage + lifecycle methods + `default()` factory wiring the
/// MVP probe set. Scheduling/dispatch logic still arrives in Phase 3
/// alongside the `PowerProfile` state machine.
public actor ProbeRegistry {
    private var probes: [String: any Probe] = [:]
    private var lastSnapshot: [Alert] = []
    private var isRunning: Bool = false

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "registry")

    public init() {}

    /// Register a probe. Replaces any existing probe with the same `name`.
    public func register(_ probe: any Probe) {
        probes[probe.name] = probe
    }

    /// Currently registered probe names (stable order: sorted).
    public func registeredNames() -> [String] {
        probes.keys.sorted()
    }

    /// Number of currently registered probes.
    public var count: Int {
        probes.count
    }

    /// Begin scheduled polling. Idempotent.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        // TODO Phase 3: spin up per-probe tasks honoring `pollInterval`,
        // feed results through `Watchdog`, persist events. Phase 2 only
        // populates the registry — actual sampling loop is still pending.
        let count = probes.count
        let names = registeredNames().joined(separator: ", ")
        log.info("ProbeRegistry started with \(count, privacy: .public) probes: \(names, privacy: .public)")
    }

    /// Stop scheduled polling. Idempotent.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        // TODO Phase 3: cancel running probe tasks gracefully.
        log.info("ProbeRegistry stopped")
    }

    /// Snapshot of the most recent alert set across all probes.
    public func snapshot() -> [Alert] {
        lastSnapshot
    }

    // MARK: - Phase 2 factory

    /// Build a registry pre-populated with the MVP probe set:
    /// disk, cpu_temp, thermal, battery, smart, fan.
    ///
    /// Probes that cannot collect data on the host (e.g. fanless device,
    /// missing SMART properties) are still registered — they just emit
    /// empty alert arrays. This keeps the registry shape stable so the
    /// Phase 3 scheduler + Phase 4 UI can iterate `registeredNames()`
    /// without conditional plumbing.
    public static func `default`() -> ProbeRegistry {
        let registry = ProbeRegistry()
        Task { await registry.installDefaultProbes() }
        return registry
    }

    /// Synchronous variant of `default()` that awaits the install. Use
    /// from `async` contexts (e.g. app launch) when you need the registry
    /// to be fully populated before the next operation.
    public static func defaultPopulated() async -> ProbeRegistry {
        let registry = ProbeRegistry()
        await registry.installDefaultProbes()
        return registry
    }

    private func installDefaultProbes() {
        register(DiskFreeProbe())
        register(CPUTempProbe())
        register(ThermalPressureProbe())
        register(BatteryProbe())
        register(SMARTProbe())
        register(FanRPMProbe())
    }
}
