import Foundation

/// A probe samples some aspect of the system and emits `Alert`s when
/// something is out of normal range.
///
/// `run()` returns the *current* set of firing alerts (empty if all clear).
/// The registry diffs consecutive results to derive appear/escalate/clear
/// events via `Watchdog`.
///
/// ## Phase 6 — `currentMetrics()`
///
/// Probes may *optionally* expose their latest numeric readings via
/// `currentMetrics()`, independently of whether they are firing alerts.
/// The default implementation returns an empty dictionary, so probes
/// that don't care about graph history don't need to opt in.
///
/// The returned `[String: Double]` is keyed by metric name (probe-local
/// convention — e.g. `temp_c`, `free_pct`, `charge_pct`, `cpu_pct`). The
/// scheduler hands these to `MetricsStore.recordSample(...)` so the
/// sparkline UI + `/metrics` REST endpoint can render flat-OK history,
/// not just alert-firing peaks. Per-row `key` defaults to the probe's
/// canonical scope ("/" for disk, "package" for cpu_temp, ...); probes
/// that surface multiple keys (e.g. fan_0, fan_1) should return one row
/// per key via `currentMetricRows()` instead.
public protocol Probe: Sendable {
    /// Unique name (e.g. `"disk"`, `"thermal"`, `"battery"`).
    var name: String { get }

    /// Recommended poll cadence; the registry may stretch under load.
    var pollInterval: Duration { get }

    /// Sample once and return all currently firing alerts.
    func run() async throws -> [Alert]

    /// Phase 6: latest numeric readings to persist for the
    /// `/metrics` history + popover sparklines. Keyed by metric name.
    /// Default: empty (opt-in).
    func currentMetrics() async -> [String: Double]

    /// Phase 6 multi-key variant. Each row carries its own `key`
    /// discriminator so probes with multiple subjects (fan_0, fan_1, ...)
    /// can record one row per subject. Default implementation degrades
    /// to a single row at the probe's canonical key.
    func currentMetricRows() async -> [ProbeMetricRow]
}

/// One row of metric data emitted by a probe per poll. The scheduler
/// expands this into `MetricsStore.Sample` rows by attaching probe-name
/// and timestamp on the way to the store.
public struct ProbeMetricRow: Sendable, Equatable {
    public let key: String
    public let values: [String: Double]
    public init(key: String, values: [String: Double]) {
        self.key = key
        self.values = values
    }
}

/// Default-empty implementation of the optional Phase 6 metric hooks.
extension Probe {
    public func currentMetrics() async -> [String: Double] { [:] }

    /// Default: wrap `currentMetrics()` into a single row at canonical
    /// key. Probes with multiple keys override this to emit multiple
    /// rows in one poll.
    public func currentMetricRows() async -> [ProbeMetricRow] {
        let m = await currentMetrics()
        if m.isEmpty { return [] }
        return [ProbeMetricRow(key: defaultMetricKey, values: m)]
    }

    /// The canonical "single-key" discriminator each probe uses when its
    /// alerts carry only one row. Override on the probe type if the
    /// canonical key differs from the probe name.
    public var defaultMetricKey: String { name }
}
