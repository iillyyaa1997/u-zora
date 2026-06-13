import Foundation

/// The four-state proactive-diagnosis verdict surfaced at the top of the
/// popover + driving the distinct menu-bar glyph (plan D5).
///
/// This is a SEPARATE axis from both `Severity` (raw probe firing) and
/// `Confidence` (how sure a detector is). A `Verdict` is the *aggregate*
/// health state derived from the current `Finding` set — the one-line
/// "is my Mac OK?" answer.
///
/// Ordered `good < watch < degraded < problem` (rank-based, mirroring
/// `Severity` / `Confidence`) so the engine can take the `max` contribution
/// across all findings deterministically.
public enum VerdictLevel: String, Codable, Comparable, Sendable, CaseIterable {
    /// No findings — all systems healthy.
    case good
    /// Low-severity / low-confidence trend; worth watching, not acting.
    case watch
    /// A real degradation is diagnosed (warn + high confidence).
    case degraded
    /// A hard critical or confirmed serious slowdown.
    case problem

    private var rank: Int {
        switch self {
        case .good:     return 0
        case .watch:    return 1
        case .degraded: return 2
        case .problem:  return 3
        }
    }

    public static func < (lhs: VerdictLevel, rhs: VerdictLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// The aggregate diagnosis verdict shown atop the popover: a level, a
/// plain-language headline (the title of the driving finding, or the
/// all-clear text), and the full sorted finding set for the drill-down.
///
/// PURE value type — `Verdict.derive(from:)` and `Verdict.contribution(...)`
/// are deterministic and side-effect-free, so they unit-test without a store
/// or a clock (mirrors the `Detector` purity contract).
public struct Verdict: Sendable, Equatable, Codable {
    public let level: VerdictLevel
    public let headline: String
    public let findings: [Finding]

    public init(level: VerdictLevel, headline: String, findings: [Finding]) {
        self.level = level
        self.headline = headline
        self.findings = findings
    }

    /// Headline shown when there are no findings.
    public static let healthyHeadline = "All systems healthy"

    /// Map a single finding's `(severity, confidence)` to the `VerdictLevel`
    /// it contributes to the aggregate. PURE + total over the cross product.
    ///
    /// The explicit table (plan D5 — verdict reads the *right* signal, not a
    /// raw threshold):
    ///
    ///   | severity  | confidence        | contribution |
    ///   |-----------|-------------------|--------------|
    ///   | .critical | (any)             | .problem     |
    ///   | .warn     | .high             | .degraded    |
    ///   | .warn     | .low / .medium    | .watch       |
    ///   | .info     | (any)             | .watch       |
    ///
    /// Rationale: a hard critical (disk ≥90%, R1) is always a `problem`
    /// regardless of confidence. A `warn` only escalates to `degraded` once
    /// the detector is *highly* confident of the cause; an early / uncertain
    /// `warn` stays at `watch` (anti-cry-wolf). `info` findings are advisory
    /// → `watch`.
    public static func contribution(severity: Severity, confidence: Confidence) -> VerdictLevel {
        switch severity {
        case .critical:
            return .problem
        case .warn:
            switch confidence {
            case .high:
                return .degraded
            case .low, .medium:
                return .watch
            }
        case .info:
            return .watch
        }
    }

    /// Derive the aggregate verdict from the current finding set. PURE +
    /// deterministic.
    ///
    /// - Empty → `good` + the all-clear headline.
    /// - Else → `level` = the MAX contribution across all findings; the
    ///   headline is the title of the *driving* finding (the one with the
    ///   highest `(contribution, severity, confidence)`, tie-broken
    ///   deterministically by `id`). `findings` are returned sorted by `id`.
    public static func derive(from findings: [Finding]) -> Verdict {
        guard !findings.isEmpty else {
            return Verdict(level: .good, headline: healthyHeadline, findings: [])
        }

        let sorted = findings.sorted { $0.id < $1.id }

        // Aggregate level = max contribution across the set.
        var level: VerdictLevel = .good
        for f in sorted {
            let c = contribution(severity: f.severity, confidence: f.confidence)
            if c > level { level = c }
        }

        // Driving finding: highest (contribution, severity, confidence);
        // deterministic tie-break by id (the set is already id-sorted, so a
        // strict `>` comparison keeps the first/lowest-id winner on ties).
        var driver = sorted[0]
        var driverContribution = contribution(severity: driver.severity, confidence: driver.confidence)
        for f in sorted.dropFirst() {
            let c = contribution(severity: f.severity, confidence: f.confidence)
            if isMoreDriving(
                candidateContribution: c,
                candidate: f,
                bestContribution: driverContribution,
                best: driver
            ) {
                driver = f
                driverContribution = c
            }
        }

        return Verdict(level: level, headline: driver.title, findings: sorted)
    }

    /// True if `candidate` should replace `best` as the driving finding.
    /// Compares `(contribution, severity, confidence)` lexicographically;
    /// equal triples keep `best` (the id-sorted set means the lowest id wins
    /// ties — a strict `>` here never displaces an equal earlier element).
    private static func isMoreDriving(
        candidateContribution: VerdictLevel,
        candidate: Finding,
        bestContribution: VerdictLevel,
        best: Finding
    ) -> Bool {
        if candidateContribution != bestContribution {
            return candidateContribution > bestContribution
        }
        if candidate.severity != best.severity {
            return candidate.severity > best.severity
        }
        if candidate.confidence != best.confidence {
            return candidate.confidence > best.confidence
        }
        return false
    }
}
