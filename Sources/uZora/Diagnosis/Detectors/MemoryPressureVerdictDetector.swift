import Foundation

/// Verdict on the CORRECT memory signal — macOS Memory-Pressure LEVEL — not
/// swap size.
///
/// This detector exists specifically to KILL the false "memory critical"
/// misdiagnosis: a machine can carry 11 GB of swap and 156 MB free yet have
/// GREEN memory pressure (the operator runs 40 GB swap smoothly). The decisive
/// signal is the kernel's own pressure LEVEL — persisted by `SystemSignalsProbe`
/// as `mem_pressure_level` on the 0/1/2 ordinal ladder (0 normal / 1 warn /
/// 2 critical) — never the swap-usage number.
public struct MemoryPressureVerdictDetector: Detector {

    public let id = "memory_pressure"

    public let lookback: Duration
    public let requiredProbes: Set<String> = ["system_signals"]

    /// - Parameter lookback: small window — only the latest level matters,
    ///   with a little slack for a missed poll.
    public init(lookback: Duration = .seconds(120)) {
        self.lookback = lookback
    }

    public func evaluate(_ context: DiagnosisContext) -> Finding? {
        // Latest pressure level on the 0/1/2 ladder. Absent → abstain.
        guard let latest = context.latest(probe: "system_signals", name: "mem_pressure_level") else {
            return nil
        }
        // Round to the nearest integer level — the probe persists the exact
        // ordinal (0/1/2), but be tolerant of float storage.
        let level = Int(latest.value.rounded())

        switch level {
        case 1:
            return Finding(
                detector: id,
                subject: "memory",
                severity: .warn,
                confidence: .high,
                title: "Memory pressure elevated",
                explanation: "macOS reports elevated memory pressure (warn). Apps may slow as the "
                    + "system reclaims and compresses memory. This is about pressure, not swap size.",
                evidence: ["mem_pressure_level": "1"],
                suggestedAction: "Close some memory-heavy apps",
                firstSeen: context.now,
                lastUpdated: context.now
            )
        case let l where l >= 2:
            return Finding(
                detector: id,
                subject: "memory",
                severity: .critical,
                confidence: .high,
                title: "Memory pressure critical",
                explanation: "macOS reports critical memory pressure. The system is heavily "
                    + "reclaiming memory and responsiveness is at risk. This is about pressure, "
                    + "not swap size.",
                evidence: ["mem_pressure_level": "2"],
                suggestedAction: "Close some memory-heavy apps",
                firstSeen: context.now,
                lastUpdated: context.now
            )
        default:
            // level 0 (normal) or any negative/garbage → no finding.
            return nil
        }
    }
}
