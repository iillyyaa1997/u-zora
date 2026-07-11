import Foundation

/// Read-only live connection metrics for the bridge (plan D-L7 / Phase B5).
///
/// Two tiny actors surfaced in the "MCP & API" Settings tab + the popover
/// footer. They are DIAGNOSTICS ONLY — they never gate or slow the request
/// path: a single actor `await` at the top of a handler (and one in its
/// disconnect `defer`) is the whole cost, and neither ever blocks.

/// Count of currently-open `/stream` SSE connections.
///
/// `EventBus.subscriberCount` is polluted by internal subscribers (JSONL sink,
/// StateStore, diagnosis fan-out, …), so the *client* stream count is tracked
/// here explicitly: `enter()` at the top of `SSEStream.handle`, `leave()` in
/// its disconnect `defer`. `value()` is read on the 5s UI tick.
public actor StreamClientCounter {
    private var n = 0
    public init() {}
    public func enter() { n += 1 }
    /// Never underflows past zero (a stray double-leave is a no-op).
    public func leave() { if n > 0 { n -= 1 } }
    public func value() -> Int { n }
}

/// Timestamp of the most recent `/mcp` request — any verb (a JSON-RPC POST call
/// OR the streamable-HTTP GET-405 probe). Stamped at the top of
/// `MCPServer.handle`; read on the 5s UI tick to render "last MCP request Ns
/// ago". `nil` until the first request lands.
public actor LastRequestClock {
    private var at: Date?
    public init() {}
    public func stamp(_ date: Date = Date()) { at = date }
    public func value() -> Date? { at }
}
