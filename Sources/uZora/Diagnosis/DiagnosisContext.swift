import Foundation

/// The PURE, pre-materialized snapshot a `Detector` reads.
///
/// Detectors must be pure and synchronous (so they're trivially testable and
/// deterministic), which means they cannot perform async I/O or call `Date()`
/// themselves. The `DiagnosisEngine` therefore does ALL async work up front —
/// loading the time-windowed `MetricsStore` history and capturing the current
/// time — and hands each detector this immutable value. Every accessor below
/// is a pure in-memory filter over `samples`; no detector ever touches the
/// store or the clock directly.
///
/// `samples` is the concatenation of every series the engine was asked to
/// load (across all configured probe names), already filtered to the lookback
/// window. The convenience accessors slice it back out by `(probe, name,
/// key)`. `key` defaults to `nil` on every accessor — "match any key" — since
/// most series (like `system_signals`) use a single canonical key.
public struct DiagnosisContext: Sendable {

    /// The instant this diagnosis cycle ran (captured once by the engine).
    /// Detectors MUST use this rather than `Date()` for determinism.
    public let now: Date

    /// The full window of history the engine loaded, across all probes.
    public let samples: [MetricsStore.Sample]

    public init(now: Date, samples: [MetricsStore.Sample]) {
        self.now = now
        self.samples = samples
    }

    /// Matching samples for a `(probe, name[, key])` series, ascending by `at`.
    public func series(probe: String, name: String, key: String? = nil) -> [MetricsStore.Sample] {
        samples
            .filter { $0.probe == probe && $0.name == name && (key == nil || $0.key == key) }
            .sorted { $0.at < $1.at }
    }

    /// The most recent sample for a `(probe, name[, key])` series, or `nil`.
    public func latest(probe: String, name: String, key: String? = nil) -> MetricsStore.Sample? {
        series(probe: probe, name: name, key: key).last
    }

    /// Just the numeric values of a `(probe, name[, key])` series, ascending
    /// by `at` (parallel to `series(...)`).
    public func values(probe: String, name: String, key: String? = nil) -> [Double] {
        series(probe: probe, name: name, key: key).map(\.value)
    }

    /// Samples within `window` of `now` (i.e. `at >= now - window`), ascending
    /// by `at`. Convenience for detectors that only care about the freshest
    /// slice of an already-loaded series.
    public func recent(
        probe: String,
        name: String,
        within window: Duration,
        key: String? = nil
    ) -> [MetricsStore.Sample] {
        let cutoff = now.addingTimeInterval(-window.seconds)
        return series(probe: probe, name: name, key: key).filter { $0.at >= cutoff }
    }
}

extension Duration {
    /// This `Duration` as a fractional number of seconds, including the
    /// attoseconds component. Used to map a `Duration` lookback/window onto
    /// the `TimeInterval` arithmetic that `Date`/`MetricsStore` use.
    var seconds: TimeInterval {
        let (s, attos) = components
        return TimeInterval(s) + TimeInterval(attos) / 1_000_000_000_000_000_000
    }
}
