import Foundation

/// Severity levels for alerts emitted by probes.
///
/// Ordered `info < warn < critical` so callers can filter by minimum severity
/// or sort alert lists.
public enum Severity: String, Codable, Comparable, Sendable, CaseIterable {
    case info
    case warn
    case critical

    private var rank: Int {
        switch self {
        case .info: return 0
        case .warn: return 1
        case .critical: return 2
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.rank < rhs.rank
    }
}
