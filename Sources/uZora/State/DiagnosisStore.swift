import Foundation

/// In-memory snapshot store for the *proactive-diagnosis* layer — the
/// `Finding`/`Verdict` analog of `StateStore` (which holds raw `Alert`s).
///
/// Holds the LATEST diagnosis snapshot so the channel layer (REST `/findings`
/// + `/verdict`, MCP `uzora_list_findings` + `uzora_get_verdict`) can read it
/// without touching the `DiagnosisEngine` / `FindingWatchdog` directly.
///
/// `DiagnosisStore` is **read-only from the channel side** — the only writer
/// is the `AppDelegate` diagnosis loop (`runDiagnosisCycle()` + the boot
/// seed), which calls `update(findings:verdict:)` once per cycle. Channels
/// query through `findings()` / `findings(minSeverity:)` / `verdict()` and
/// never mutate state. Mirrors the `StateStore` actor idiom so the channel
/// layer stays testable in isolation (instantiate a store, push a snapshot,
/// assert handler output) and decoupled from the engine's cycle timing.
public actor DiagnosisStore {

    /// Latest finding set (unsorted as received; reads sort by `id`).
    private var currentFindings: [Finding] = []
    /// Latest derived verdict. Seeded to the all-clear `good` verdict so a
    /// store that has never been updated answers `/verdict` healthily rather
    /// than crashing or returning a placeholder.
    private var currentVerdict: Verdict = Verdict(
        level: .good,
        headline: Verdict.healthyHeadline,
        findings: []
    )

    public init() {}

    /// Replace the snapshot atomically. Called by the AppDelegate diagnosis
    /// loop with the freshly-diagnosed findings + the verdict derived from
    /// them (the loop derives the verdict ONCE and passes it here AND to the
    /// UI, so the two surfaces never disagree).
    public func update(findings: [Finding], verdict: Verdict) {
        currentFindings = findings
        currentVerdict = verdict
    }

    /// Snapshot the current finding set sorted by `id` for stable output
    /// (mirrors `StateStore.activeAlerts()` sorting by id).
    public func findings() -> [Finding] {
        currentFindings.sorted { $0.id < $1.id }
    }

    /// Filtered view: findings at or above the supplied severity floor.
    /// Sorted by `id` (inherits the ordering from `findings()`).
    public func findings(minSeverity floor: Severity) -> [Finding] {
        findings().filter { $0.severity >= floor }
    }

    /// The latest derived verdict (defaults to the all-clear `good` verdict
    /// until the first `update(...)`).
    public func verdict() -> Verdict {
        currentVerdict
    }
}
