import Foundation
import os

/// Samples CPU (SoC) die temperature on Apple Silicon.
///
/// **Approach**: read the on-die temperature sensors exposed by the private
/// `IOHIDEventSystemClient` API (`AppleARMPMUTempSensor` family) via
/// `IOHIDThermal`, select the CPU/SoC die sensors, and report their
/// **average**. This is the only reliable source on Apple Silicon:
///   - the legacy SMC `Tp*` keys return denormal / crosstalk garbage
///     (observed 20–99 °C swings on an idle, cool machine), and
///   - `powermetrics` no longer ships an `smc` sampler or any die temp.
///
/// Read-only, no entitlement, works under ad-hoc signing (verified on
/// macOS 26 / Apple Silicon). Where the sensors are absent (VMs, future
/// revisions) the probe abstains (graceful no-op + one-shot warning) — it
/// never falls back to the unreliable SMC path.
public final class CPUTempProbe: Probe, @unchecked Sendable {

    public let name = "cpu_temp"
    public let pollInterval: Duration = .seconds(10)

    public struct Thresholds: Sendable {
        public let warnC: Double
        public let criticalC: Double

        public init(warnC: Double = 90, criticalC: Double = 100) {
            self.warnC = warnC
            self.criticalC = criticalC
        }

        public static let `default` = Thresholds()
    }

    public struct Sample: Sendable {
        public let tempC: Double
        public let sourceKey: String

        public init(tempC: Double, sourceKey: String) {
            self.tempC = tempC
            self.sourceKey = sourceKey
        }
    }

    private let thresholds: Thresholds
    private let sampler: @Sendable () -> Sample?
    private let clock: @Sendable () -> Date
    private var firstSeenAt: Date?
    private var unavailableLogged: Bool = false

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "cpu_temp")

    public convenience init(thresholds: Thresholds = .default) {
        self.init(
            thresholds: thresholds,
            sampler: { Self.sampleViaIOHID() },
            clock: { Date() }
        )
    }

    public init(
        thresholds: Thresholds,
        sampler: @escaping @Sendable () -> Sample?,
        clock: @escaping @Sendable () -> Date
    ) {
        self.thresholds = thresholds
        self.sampler = sampler
        self.clock = clock
    }

    public var defaultMetricKey: String { "package" }

    /// Test affordance: the thresholds this instance was constructed with,
    /// so config-wiring tests can assert the °C mapping. Internal —
    /// `@testable import`.
    var configuredThresholds: Thresholds { thresholds }

    /// Latest CPU package temperature, for sparkline history.
    public func currentMetrics() async -> [String: Double] {
        guard let s = sampler() else { return [:] }
        return ["temp_c": s.tempC]
    }

    public func run() async throws -> [Alert] {
        guard let sample = sampler() else {
            if !unavailableLogged {
                log.warning("CPU temperature unavailable — no IOHID temperature sensors responded (VM / unsupported hardware).")
                unavailableLogged = true
            }
            return []
        }

        guard let severity = Self.severity(for: sample.tempC, thresholds: thresholds) else {
            firstSeenAt = nil
            return []
        }

        let now = clock()
        if firstSeenAt == nil { firstSeenAt = now }

        return [Alert(
            probe: name,
            key: "package",
            severity: severity,
            message: String(format: "CPU package %.1f°C (source: %@)", sample.tempC, sample.sourceKey),
            details: [
                "temp_c":     String(format: "%.2f", sample.tempC),
                "source_key": sample.sourceKey,
            ],
            firstSeen: firstSeenAt ?? now,
            lastUpdated: now
        )]
    }

    // MARK: - Pure threshold (testable)

    public static func severity(for tempC: Double, thresholds: Thresholds) -> Severity? {
        if tempC >= thresholds.criticalC { return .critical }
        if tempC >= thresholds.warnC { return .warn }
        return nil
    }

    // MARK: - IOHID die-sensor selection

    /// Lower plausibility bound (°C). IOHID readings are clean, but a parked
    /// sensor can report ~0; drop anything below this before averaging.
    static let plausibilityFloorC: Double = 5

    /// Upper plausibility bound (°C). Must sit ABOVE the default critical
    /// threshold (100 °C) so a genuine critical reading still averages in and
    /// a critical alert can fire; 120 covers Apple-Silicon Tjmax while
    /// rejecting obviously broken values.
    static let plausibilityCeilingC: Double = 120

    /// Whether a HID sensor name denotes a CPU / SoC *die* temperature.
    ///
    /// Apple's sensor naming varies by generation; this matches the on-die
    /// families we know — `tdie*` (M3/M4 PMU die temps), `pACC`/`eACC`
    /// (performance / efficiency clusters) and any explicitly `cpu`-named
    /// sensor — while excluding battery / NAND / GPU / charger sensors. It is
    /// conservative on purpose: an unrecognised layout matches nothing
    /// (→ abstain) rather than averaging in the wrong sensors.
    static func isCPUDieSensor(_ rawName: String) -> Bool {
        let n = rawName.lowercased()
        for bad in ["battery", "gas gauge", "nand", "ssd", "charger", "gpu", "wifi", "airport"] {
            if n.contains(bad) { return false }
        }
        return n.contains("tdie")
            || n.contains("pacc")
            || n.contains("eacc")
            || n.contains("cpu")
    }

    /// Pure, testable selection: from named sensor readings, keep the CPU die
    /// sensors within the plausibility window and return their average as a
    /// `Sample` (or nil to abstain when none qualify).
    static func selectCPUTemp(from readings: [(name: String, tempC: Double)]) -> Sample? {
        let cpu = readings.filter {
            isCPUDieSensor($0.name)
                && $0.tempC.isFinite
                && $0.tempC >= plausibilityFloorC
                && $0.tempC < plausibilityCeilingC
        }
        guard !cpu.isEmpty else { return nil }
        let avg = cpu.reduce(0.0) { $0 + $1.tempC } / Double(cpu.count)
        return Sample(tempC: avg, sourceKey: "IOHID die avg (\(cpu.count) sensors)")
    }

    /// Live sampler: read IOHID temperature sensors and select the CPU die
    /// average. Returns nil (abstain) when no sensors are available.
    public static func sampleViaIOHID() -> Sample? {
        let readings = IOHIDThermal.readSensors().map { (name: $0.name, tempC: $0.tempC) }
        return selectCPUTemp(from: readings)
    }
}
