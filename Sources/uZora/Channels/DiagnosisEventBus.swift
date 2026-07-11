import Foundation
import os

/// Diagnosis-layer broadcast event for the `GET /stream` SSE fan-out
/// (plan D-L4).
///
/// A deliberate SIBLING of the `WatchdogEvent → EventBus → SSEStream` path —
/// NOT a widening of the load-bearing `WatchdogEvent` enum (plan D2 forbids
/// touching it, since it is switched exhaustively across ~10 channel/state
/// sites). This parallel type carries the proactive-diagnosis diff
/// (`FindingEvent`) plus AGGREGATE verdict-level transitions, so an LLM client
/// subscribed to `/stream` receives pushed findings + verdicts instead of
/// having to poll `/findings` and `/verdict`.
public enum DiagnosisStreamEvent: Sendable, Equatable {
    /// One finding diff event (`diagnosed` / `rediagnosed` / `resolved`).
    case finding(FindingEvent)
    /// The AGGREGATE verdict LEVEL transitioned
    /// (good ↔ watch ↔ degraded ↔ problem).
    case verdictChanged(from: VerdictLevel, to: VerdictLevel, headline: String)
}

/// Fan-out actor for `DiagnosisStreamEvent`s — the diagnosis-layer sibling of
/// `EventBus`.
///
/// Mirrors `EventBus` exactly (`subscribe` / `unsubscribe` / `emit` /
/// `emitAll` / `subscriberCount` / `emittedCount`) so `SSEStream` can subscribe
/// to it the same way it subscribes to the `WatchdogEvent` bus, without either
/// of the two paths knowing about the other. Subscriber callbacks must be
/// `@Sendable` and non-blocking (they run serially inside the actor).
public actor DiagnosisEventBus {

    public typealias Subscriber = @Sendable (DiagnosisStreamEvent) -> Void

    private struct Subscription {
        let id: UUID
        let callback: Subscriber
    }

    private var subscribers: [Subscription] = []
    private var emitted: Int = 0

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "diagnosis-event-bus")

    public init() {}

    /// Register a callback. Returns a token that can be passed to
    /// `unsubscribe(_:)` for detach semantics (`SSEStream` uses per-connection
    /// subscriptions and unsubscribes when the socket closes).
    @discardableResult
    public func subscribe(_ callback: @escaping Subscriber) -> UUID {
        let token = UUID()
        subscribers.append(Subscription(id: token, callback: callback))
        return token
    }

    public func unsubscribe(_ token: UUID) {
        subscribers.removeAll { $0.id == token }
    }

    /// Broadcast a single event to every currently-registered subscriber, in
    /// registration order.
    public func emit(_ event: DiagnosisStreamEvent) {
        emitted += 1
        for sub in subscribers {
            sub.callback(event)
        }
    }

    /// Broadcast a batch of events in order.
    public func emitAll(_ events: [DiagnosisStreamEvent]) {
        for event in events {
            emit(event)
        }
    }

    /// Number of currently-registered subscribers. Test-affordance.
    public var subscriberCount: Int { subscribers.count }

    /// Total count of events ever broadcast. Test-affordance.
    public var emittedCount: Int { emitted }
}

/// One SSE frame body for a `DiagnosisStreamEvent`, mirroring the
/// `JSONLEventSink.Line` shape: a flattened `kind` + payload keys (no nested
/// sub-object) so consumers (jq / Python / a Claude-Code channel-shim mapping
/// keys → tag attributes) don't have to walk into a document. All keys are
/// snake_case + identifier-safe.
///
/// Only the fields relevant to `kind` are emitted (`encodeIfPresent`), exactly
/// like `JSONLEventSink.Line`:
///
/// ```json
/// {"ts":"…","kind":"diagnosed","detector":"runaway_daemon","subject":"ecosystemd","severity":"warn","confidence":"high","title":"…","suggested_action":"…"}
/// {"ts":"…","kind":"rediagnosed",…,"previous_severity":"warn","previous_confidence":"low"}
/// {"ts":"…","kind":"resolved","finding_id":"runaway_daemon:ecosystemd"}
/// {"ts":"…","kind":"verdict_changed","previous_level":"good","level":"degraded","headline":"…"}
/// ```
public struct DiagnosisEventLine: Codable, Equatable, Sendable {
    public let ts: Date
    public let kind: Kind

    // Finding fields (diagnosed / rediagnosed / resolved).
    public let detector: String?
    public let subject: String?
    public let severity: Severity?
    public let confidence: Confidence?
    public let title: String?
    public let suggestedAction: String?
    public let findingID: String?
    public let previousSeverity: Severity?
    public let previousConfidence: Confidence?

    // verdict_changed fields.
    public let previousLevel: VerdictLevel?
    public let level: VerdictLevel?
    public let headline: String?

    public enum Kind: String, Codable, Sendable {
        case diagnosed
        case rediagnosed
        case resolved
        case verdictChanged = "verdict_changed"
    }

    public enum CodingKeys: String, CodingKey {
        case ts
        case kind
        case detector
        case subject
        case severity
        case confidence
        case title
        case suggestedAction = "suggested_action"
        case findingID = "finding_id"
        case previousSeverity = "previous_severity"
        case previousConfidence = "previous_confidence"
        case previousLevel = "previous_level"
        case level
        case headline
    }

    public init(timestamp: Date, event: DiagnosisStreamEvent) {
        self.ts = timestamp
        switch event {
        case .finding(.diagnosed(let f)):
            self.kind = .diagnosed
            self.detector = f.detector
            self.subject = f.subject
            self.severity = f.severity
            self.confidence = f.confidence
            self.title = f.title
            self.suggestedAction = f.suggestedAction
            self.findingID = nil
            self.previousSeverity = nil
            self.previousConfidence = nil
            self.previousLevel = nil
            self.level = nil
            self.headline = nil
        case .finding(.rediagnosed(let f, let prevSev, let prevConf)):
            self.kind = .rediagnosed
            self.detector = f.detector
            self.subject = f.subject
            self.severity = f.severity
            self.confidence = f.confidence
            self.title = f.title
            self.suggestedAction = f.suggestedAction
            self.findingID = nil
            self.previousSeverity = prevSev
            self.previousConfidence = prevConf
            self.previousLevel = nil
            self.level = nil
            self.headline = nil
        case .finding(.resolved(let id)):
            self.kind = .resolved
            self.detector = nil
            self.subject = nil
            self.severity = nil
            self.confidence = nil
            self.title = nil
            self.suggestedAction = nil
            self.findingID = id
            self.previousSeverity = nil
            self.previousConfidence = nil
            self.previousLevel = nil
            self.level = nil
            self.headline = nil
        case .verdictChanged(let from, let to, let headline):
            self.kind = .verdictChanged
            self.detector = nil
            self.subject = nil
            self.severity = nil
            self.confidence = nil
            self.title = nil
            self.suggestedAction = nil
            self.findingID = nil
            self.previousSeverity = nil
            self.previousConfidence = nil
            self.previousLevel = from
            self.level = to
            self.headline = headline
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ts, forKey: .ts)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(detector, forKey: .detector)
        try c.encodeIfPresent(subject, forKey: .subject)
        try c.encodeIfPresent(severity, forKey: .severity)
        try c.encodeIfPresent(confidence, forKey: .confidence)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(suggestedAction, forKey: .suggestedAction)
        try c.encodeIfPresent(findingID, forKey: .findingID)
        try c.encodeIfPresent(previousSeverity, forKey: .previousSeverity)
        try c.encodeIfPresent(previousConfidence, forKey: .previousConfidence)
        try c.encodeIfPresent(previousLevel, forKey: .previousLevel)
        try c.encodeIfPresent(level, forKey: .level)
        try c.encodeIfPresent(headline, forKey: .headline)
    }
}
