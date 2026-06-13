import Foundation

/// Hard-threshold critical: boot drive ≥ `criticalUsedFraction` full.
///
/// This is the operator's **R1** requirement — a known hard critical that must
/// fire IMMEDIATELY on the latest value, with NO dwell / no anti-cry-wolf
/// gating (those apply only to trend/anomaly diagnoses). At ≥90% used (≤10%
/// free) the boot volume is one runaway log/cache away from breaking the OS,
/// so the diagnosis is high-confidence and actionable on a single sample.
///
/// No attribution, no sustain window: just the freshest `disk` `free_pct`.
public struct DiskHardCriticalDetector: Detector {

    public let id = "disk_hard_critical"

    /// Used-fraction at/above which the disk is critical. R1: ≥90% used ⇒
    /// `free_pct ≤ 10`. Stored as a USED fraction (0…1) for readability; the
    /// equivalent free-percent threshold is `(1 - criticalUsedFraction) * 100`.
    public let criticalUsedFraction: Double

    public let lookback: Duration
    public let requiredProbes: Set<String> = ["disk"]

    /// - Parameters:
    ///   - criticalUsedFraction: used-fraction critical threshold (default
    ///     0.90 per R1).
    ///   - lookback: small window — only the latest sample matters, but a few
    ///     minutes of slack ensures a fresh value survives a missed poll.
    public init(
        criticalUsedFraction: Double = 0.90,
        lookback: Duration = .seconds(300)
    ) {
        self.criticalUsedFraction = criticalUsedFraction
        self.lookback = lookback
    }

    /// The free-percent threshold derived from `criticalUsedFraction`
    /// (e.g. 0.90 used → fire when free_pct ≤ 10). Rounded to 6 decimal places
    /// so binary-float representation noise (e.g. `0.10 * 100 = 9.999…998`)
    /// can't make an exact-boundary value like 10.0% silently miss the gate.
    public var criticalFreePercent: Double {
        ((100 - criticalUsedFraction * 100) * 1_000_000).rounded() / 1_000_000
    }

    public func evaluate(_ context: DiagnosisContext) -> Finding? {
        // Latest `disk` free_pct on the boot volume ("/" is DiskFreeProbe's
        // canonical key, but match any key for robustness).
        guard let latest = context.latest(probe: "disk", name: "free_pct") else {
            return nil
        }
        let freePct = latest.value
        guard freePct <= criticalFreePercent else { return nil }

        let usedPct = 100 - freePct

        var evidence: [String: String] = [
            "free_pct": String(format: "%.1f", freePct),
        ]
        // free_bytes / total_bytes are sibling metrics on the same probe;
        // include them when present (they share the disk probe's "/" key).
        if let freeBytes = context.latest(probe: "disk", name: "free_bytes")?.value {
            evidence["free_bytes"] = String(format: "%.0f", freeBytes)
        }
        if let totalBytes = context.latest(probe: "disk", name: "total_bytes")?.value {
            evidence["total_bytes"] = String(format: "%.0f", totalBytes)
        }

        return Finding(
            detector: id,
            subject: "/",
            severity: .critical,
            confidence: .high,
            title: "Disk almost full",
            explanation: "Boot drive is \(Int(usedPct.rounded()))% full.",
            evidence: evidence,
            suggestedAction: "Free up disk space",
            firstSeen: context.now,
            lastUpdated: context.now
        )
    }
}
