import Foundation

/// Confidence axis for diagnosis `Finding`s.
///
/// This is a SEPARATE axis from `Severity` (plan D2: "no new severity tier;
/// add a Confidence axis"). `Severity` answers "how bad is the symptom?";
/// `Confidence` answers "how sure are we about the diagnosed cause?". A
/// detector emits both — e.g. a hard disk-critical is `severity: .critical`
/// + `confidence: .high`, while an early trend-anomaly may be
/// `severity: .warn` + `confidence: .low` until it dwells.
///
/// Ordered `low < medium < high` (rank-based, mirroring `Severity`) so the
/// `FindingWatchdog` diff can detect a confidence *rise* the same way the
/// `Watchdog` detects a severity escalation.
public enum Confidence: String, Codable, Comparable, Sendable, CaseIterable {
    case low
    case medium
    case high

    private var rank: Int {
        switch self {
        case .low:    return 0
        case .medium: return 1
        case .high:   return 2
        }
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.rank < rhs.rank
    }
}
