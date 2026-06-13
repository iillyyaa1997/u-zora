import Foundation

/// A pure, declarative diagnosis rule.
///
/// A `Detector` inspects a `DiagnosisContext` (already-loaded history + a
/// captured `now`) and returns a `Finding` when it diagnoses a likely cause,
/// or `nil` when nothing is wrong. The contract is deliberately strict so the
/// `DiagnosisEngine` can run every detector deterministically:
///
///  - `evaluate(_:)` is **pure and synchronous** — no async, no I/O, no
///    global mutable state.
///  - Detectors **never call `Date()`** — they read `context.now` instead, so
///    a test can pin the clock and replay history reproducibly.
///
/// The engine declares how much history to load by taking the `max` of every
/// detector's `lookback`; a detector that needs more than the default should
/// override `lookback`.
public protocol Detector: Sendable {
    /// Unique detector id (e.g. `"runaway_daemon"`); becomes the
    /// `Finding.detector` field and part of the finding id.
    var id: String { get }

    /// How much history this detector needs the engine to load. The engine
    /// loads `max` across all detectors.
    var lookback: Duration { get }

    /// Probe names whose history the engine must load for this detector. The
    /// engine UNIONS this across every detector (with its base `probes` list)
    /// so a detector that needs e.g. `"disk"` history pulls it in
    /// automatically — no caller has to remember to widen `probes`.
    ///
    /// Default `[]` (added with a protocol-extension default so the Phase-2
    /// fixture detectors + their tests compile unchanged).
    var requiredProbes: Set<String> { get }

    /// Whether this detector needs the gated Tier-B `/bin/ps` attribution
    /// snapshot THIS cycle. Decided PURELY over already-loaded history (e.g.
    /// "cores have been pinned for the last N samples"), so the expensive
    /// shell-out only happens when a Tier-A trigger is hot.
    ///
    /// The engine calls `attribution()` exactly once per cycle iff ANY
    /// detector returns true, then rebuilds the context with the result.
    /// Default `false` (protocol-extension default for backward-compat).
    func wantsAttribution(_ context: DiagnosisContext) -> Bool

    /// Inspect the (pre-materialized) context and return a `Finding` if a
    /// likely cause is diagnosed, else `nil`. PURE + synchronous; no I/O and
    /// no `Date()` (use `context.now`).
    func evaluate(_ context: DiagnosisContext) -> Finding?
}

extension Detector {
    /// Default lookback: 15 minutes of history. Enough for the trend/anomaly
    /// detectors (EWMA + rolling-MAD + persistence) per plan D4 without
    /// hauling the full 7-day series into every cycle.
    public var lookback: Duration { .seconds(900) }

    /// Default: no extra probes beyond the engine's base `probes` list.
    public var requiredProbes: Set<String> { [] }

    /// Default: never needs the gated `ps` attribution snapshot.
    public func wantsAttribution(_ context: DiagnosisContext) -> Bool { false }
}
