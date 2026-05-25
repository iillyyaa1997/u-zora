import Foundation

/// A single firing alert emitted by a probe.
///
/// Identified by the `(probe, key)` tuple — `probe` is the probe name,
/// `key` is a discriminator within the probe (e.g. mountpoint for disk probe).
///
/// `details` carries probe-specific extras as flat `[String: String]`.
/// Complex/nested values should be JSON-encoded into a string by the probe
/// before being stored here. This keeps `Alert` trivially `Codable` without
/// pulling in an `AnyCodable` dependency in Phase 1. May be revisited later.
public struct Alert: Hashable, Codable, Sendable, Identifiable {
    public let probe: String
    public let key: String
    public let severity: Severity
    public let message: String
    public let details: [String: String]?
    public let firstSeen: Date
    public let lastUpdated: Date

    public var id: String { "\(probe):\(key)" }

    public init(
        probe: String,
        key: String,
        severity: Severity,
        message: String,
        details: [String: String]? = nil,
        firstSeen: Date,
        lastUpdated: Date
    ) {
        self.probe = probe
        self.key = key
        self.severity = severity
        self.message = message
        self.details = details
        self.firstSeen = firstSeen
        self.lastUpdated = lastUpdated
    }
}
