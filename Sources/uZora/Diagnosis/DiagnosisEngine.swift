import Foundation
import os

/// Runs the pure `Detector`s over loaded `MetricsStore` history and produces
/// the current set of `Finding`s.
///
/// The engine is the single place that performs async I/O for diagnosis: each
/// `diagnose()` cycle captures `now`, loads every configured probe's history
/// for the widest `lookback` any detector needs, builds an immutable
/// `DiagnosisContext`, then runs every detector synchronously. The detectors
/// themselves stay pure — see `Detector`.
///
/// Determinism: findings are returned sorted by `id`, and the entire detector
/// run is also exposed as the pure `evaluate(context:)` path so the
/// detector-running logic can be unit-tested without a store or a clock.
public actor DiagnosisEngine {

    private let detectors: [Detector]
    private let store: MetricsStore?
    private let probes: [String]
    private let clock: @Sendable () -> Date
    private let attribution: @Sendable () -> [AttributedProcess]?

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "diagnosis-engine")

    /// - Parameters:
    ///   - detectors: the rules to run each cycle.
    ///   - store: history source; `nil` means "no history" (every context is
    ///     empty — useful when only `evaluate(context:)` is driven directly).
    ///   - probes: metric source names to load history for. Defaults to the
    ///     Phase-1 Tier-A signal probe (`"system_signals"`).
    ///   - clock: time source; defaults to `Date()`. Injected in tests for
    ///     deterministic windows.
    ///   - attribution: the gated Tier-B `/bin/ps` snapshot source. Called at
    ///     most ONCE per `diagnose()` cycle, and only when some detector's
    ///     `wantsAttribution(_:)` is true. Defaults to the live
    ///     `ProcessAttribution.snapshotViaPS()`; injected in tests (often a
    ///     counter closure) to assert the gating without shelling out.
    public init(
        detectors: [Detector],
        store: MetricsStore?,
        probes: [String] = ["system_signals"],
        clock: @escaping @Sendable () -> Date = { Date() },
        attribution: @escaping @Sendable () -> [AttributedProcess]? = { ProcessAttribution.snapshotViaPS() }
    ) {
        self.detectors = detectors
        self.store = store
        self.probes = probes
        self.clock = clock
        self.attribution = attribution
    }

    /// Default lookback used when there are no detectors (so the `max` over an
    /// empty sequence has a sane fallback). Matches `Detector`'s default.
    private static let defaultLookback: Duration = .seconds(900)

    /// Load history, build the context, run every detector, return findings
    /// sorted by id. The only async work in the diagnosis path lives here
    /// (the `MetricsStore.query` calls).
    public func diagnose() async -> [Finding] {
        let now = clock()
        let lookback = detectors.map(\.lookback).max() ?? Self.defaultLookback
        let from = now.addingTimeInterval(-lookback.seconds)

        // Union the base `probes` with every detector's `requiredProbes` so a
        // detector that needs e.g. `"disk"` history pulls it in automatically.
        let probesToLoad = Set(probes).union(
            detectors.reduce(into: Set<String>()) { $0.formUnion($1.requiredProbes) }
        )

        var samples: [MetricsStore.Sample] = []
        if let store {
            // Sorted for deterministic load order (purely cosmetic; the
            // context re-sorts per series by `at`).
            for probe in probesToLoad.sorted() {
                do {
                    let rows = try await store.query(probe: probe, from: from, to: now)
                    samples.append(contentsOf: rows)
                } catch {
                    // Per-probe degradation: a failed load on one source must
                    // not blank the others (mirrors the per-signal abstain
                    // policy of SystemSignalsProbe).
                    log.error("diagnosis history load failed for probe \(probe, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }

        // Build the base (no-attribution) context first; detectors decide over
        // PURE history whether the gated `ps` snapshot is warranted this cycle.
        let base = DiagnosisContext(now: now, samples: samples)

        let context: DiagnosisContext
        if detectors.contains(where: { $0.wantsAttribution(base) }) {
            // A Tier-A trigger is hot → name the culprit (incl. cross-uid
            // /System daemons libproc can't see). Called EXACTLY once;
            // `nil` (launch/parse failure) flows through so the detector emits
            // an "unnamed slowdown" rather than going silent (plan D7).
            let attributed = attribution()
            context = DiagnosisContext(
                now: now,
                samples: samples,
                attributedProcesses: attributed
            )
        } else {
            context = base
        }

        return Self.run(detectors: detectors, context: context)
    }

    /// The PURE detector-running core, callable without the actor's async
    /// machinery or a store. Runs every detector over a caller-supplied
    /// context and returns the findings sorted by id. `diagnose()` delegates
    /// here after loading history.
    public nonisolated func evaluate(context: DiagnosisContext) -> [Finding] {
        Self.run(detectors: detectors, context: context)
    }

    /// Free static core shared by `diagnose()` and `evaluate(context:)`. Takes
    /// the detector list explicitly so it has no isolation requirements at all.
    private static func run(detectors: [Detector], context: DiagnosisContext) -> [Finding] {
        var findings: [Finding] = []
        for detector in detectors {
            if let finding = detector.evaluate(context) {
                findings.append(finding)
            }
        }
        return findings.sorted { $0.id < $1.id }
    }
}
