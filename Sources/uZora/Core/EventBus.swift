import Foundation
import os

/// Fan-out actor for `WatchdogEvent`s.
///
/// Phase 3 is a deliberately simple broadcaster: callers `emit(_:)` and
/// every subscriber's callback is invoked. Subscriber callbacks must be
/// `@Sendable` and non-blocking (they're called serially inside the
/// actor; a slow subscriber stalls the bus).
///
/// Phase 4 will replace this with structured channels (`AsyncStream`,
/// JSONL append, Notification Center, menu-bar bridge). The actor surface
/// here — `subscribe`, `emit`, `subscriberCount` — is intentionally minimal
/// so Phase 4 can swap the implementation without rippling through call
/// sites.
public actor EventBus {

    public typealias Subscriber = @Sendable (WatchdogEvent) -> Void

    private struct Subscription {
        let id: UUID
        let callback: Subscriber
    }

    private var subscribers: [Subscription] = []
    private var emitted: Int = 0

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "event-bus")

    public init() {}

    /// Register a callback. Returns a token that can be passed to
    /// `unsubscribe(_:)` if the caller needs detach semantics (Phase 3
    /// uses lifetime-of-app subscribers, so most call sites discard it).
    @discardableResult
    public func subscribe(_ callback: @escaping Subscriber) -> UUID {
        let token = UUID()
        subscribers.append(Subscription(id: token, callback: callback))
        return token
    }

    public func unsubscribe(_ token: UUID) {
        subscribers.removeAll { $0.id == token }
    }

    /// Broadcast a single event to every currently-registered subscriber.
    ///
    /// Subscribers are invoked serially in registration order. If a
    /// subscriber throws (it can't — `Subscriber` is non-throwing) or
    /// crashes, the bus is unaffected for later subscribers.
    public func emit(_ event: WatchdogEvent) {
        emitted += 1
        for sub in subscribers {
            sub.callback(event)
        }
    }

    /// Broadcast a batch of events in order. Convenience for callers
    /// holding the array returned by `Watchdog.step(currentAlerts:)`.
    public func emitAll(_ events: [WatchdogEvent]) {
        for event in events {
            emit(event)
        }
    }

    /// Number of currently-registered subscribers. Test-affordance.
    public var subscriberCount: Int { subscribers.count }

    /// Total count of events ever broadcast. Test-affordance.
    public var emittedCount: Int { emitted }

    // MARK: - Built-in sinks

    /// Subscribe an `os.Logger`-backed debug sink. Each event becomes a
    /// debug log line under category `event-bus`. The bus retains the
    /// subscriber for its lifetime (the returned token is discarded).
    public func attachLoggerSink() {
        let logger = Logger(subsystem: "place.unicorns.uzora", category: "watchdog-events")
        subscribe { event in
            switch event {
            case .appeared(let alert):
                logger.info("APPEARED \(alert.id, privacy: .public) severity=\(alert.severity.rawValue, privacy: .public): \(alert.message, privacy: .public)")
            case .escalated(let alert, let previousSeverity):
                logger.warning("ESCALATED \(alert.id, privacy: .public) \(previousSeverity.rawValue, privacy: .public)→\(alert.severity.rawValue, privacy: .public): \(alert.message, privacy: .public)")
            case .cleared(let id):
                logger.info("CLEARED \(id, privacy: .public)")
            }
        }
    }

    /// Subscribe a console-stdout sink for development. Each event becomes
    /// a single `print(...)` line. Phase 4 will replace this with a proper
    /// JSONL writer.
    public func attachConsoleSink() {
        subscribe { event in
            switch event {
            case .appeared(let alert):
                print("[uZora] APPEARED  \(alert.id) [\(alert.severity.rawValue)] \(alert.message)")
            case .escalated(let alert, let previousSeverity):
                print("[uZora] ESCALATED \(alert.id) [\(previousSeverity.rawValue)→\(alert.severity.rawValue)] \(alert.message)")
            case .cleared(let id):
                print("[uZora] CLEARED   \(id)")
            }
        }
    }
}
