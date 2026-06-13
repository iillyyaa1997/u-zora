import Foundation

/// A single diagnosis emitted by a `Detector` — the proactive-diagnosis-layer
/// analog of `Alert`. Where an `Alert` reports a raw firing threshold from a
/// probe, a `Finding` reports a *diagnosed likely cause* in plain language,
/// carrying both a `severity` (how bad the symptom is) and a `confidence`
/// (how sure the detector is of the cause).
///
/// Identified by the `(detector, subject)` tuple — `detector` is the emitting
/// detector's id (e.g. `"runaway_daemon"`), `subject` is a discriminator
/// within that detector (e.g. the daemon name, `"/"`, or `"memory"`; the
/// analog of `Alert.key`).
///
/// `evidence` carries detector-specific extras as flat `[String: String]`,
/// exactly like `Alert.details`. Complex/nested values should be JSON-encoded
/// into a string by the detector before being stored here. This keeps
/// `Finding` trivially `Codable` without pulling in an `AnyCodable`
/// dependency. May be revisited later.
public struct Finding: Hashable, Codable, Sendable, Identifiable {
    /// The emitting detector's id (e.g. `"runaway_daemon"`).
    public let detector: String
    /// Discriminator within the detector (daemon name / `"/"` / `"memory"`).
    public let subject: String
    /// How bad the symptom is. Reuses the existing `Severity` enum.
    public let severity: Severity
    /// How sure the detector is of the diagnosed cause.
    public let confidence: Confidence
    /// Short headline (e.g. "System daemon pinning CPU").
    public let title: String
    /// Plain-language likely cause.
    public let explanation: String
    /// Flat detector-specific extras; nested values JSON-encoded into strings.
    public let evidence: [String: String]?
    /// Suggested remediation (e.g. "reboot recommended"); nil if none.
    public let suggestedAction: String?
    /// First time this finding's id was observed.
    public let firstSeen: Date
    /// Most recent time this finding was re-evaluated.
    public let lastUpdated: Date

    public var id: String { "\(detector):\(subject)" }

    public init(
        detector: String,
        subject: String,
        severity: Severity,
        confidence: Confidence,
        title: String,
        explanation: String,
        evidence: [String: String]? = nil,
        suggestedAction: String? = nil,
        firstSeen: Date,
        lastUpdated: Date
    ) {
        self.detector = detector
        self.subject = subject
        self.severity = severity
        self.confidence = confidence
        self.title = title
        self.explanation = explanation
        self.evidence = evidence
        self.suggestedAction = suggestedAction
        self.firstSeen = firstSeen
        self.lastUpdated = lastUpdated
    }
}
