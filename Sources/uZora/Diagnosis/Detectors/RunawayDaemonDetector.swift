import Foundation

/// **Flagship detector — the seed-incident catcher.**
///
/// Diagnoses the seed class: a SIP-protected `/System` daemon
/// (`ecosystemd` / `ecosystemanalyticsd`, …) busy-looping and pinning
/// CPU cores for a sustained period, starving the compositor → perceived
/// jank. The cause is invisible to Activity Monitor and the unified log;
/// only the COMPOSITE symptom is observable no-sudo.
///
/// Two-tier sensing (plan D1):
///  - **Tier-A trigger (pure, in `wantsAttribution`)** — `cores_pinned`
///    (from `system_signals`) has been at/above `pinnedCoresThreshold` for
///    the last `sustainSamples` samples. This is the cheap always-on gate.
///  - **Tier-B attribution (the gated `/bin/ps` snapshot)** — only when the
///    trigger is hot does the engine populate `context.attributedProcesses`,
///    letting `evaluate` NAME the offending daemon (the only no-sudo route to
///    cross-uid `/System` daemons; see the feasibility analysis §0).
///
/// Graceful degradation (plan D7): if the trigger is hot but attribution is
/// `nil` (ps failed) or names no non-suppressed system offender, the detector
/// still emits a LOW-confidence "unnamed slowdown" finding — never silence.
public struct RunawayDaemonDetector: Detector {

    public let id = "runaway_daemon"

    /// Per-cycle `cores_pinned` value at/above which the trigger counts a
    /// sample as "pinned". `cores_pinned` is already a COUNT of pinned cores
    /// (see `SystemSignalsProbe`), so `2` means "≥2 cores pinned" — the seed
    /// incident pinned ~2 of 6 P-cores.
    public let pinnedCoresThreshold: Double

    /// How many consecutive most-recent samples must ALL be at/above the
    /// threshold to count as "sustained". 12 samples ≈ 60 s at the default
    /// 5 s `system_signals` poll — the ≥~60 s trigger from the feasibility
    /// analysis that distinguishes a developing problem from a transient burst.
    public let sustainSamples: Int

    /// Minimum cumulative CPU seconds an attributed system process must have
    /// accrued to be named as the culprit. The seed daemons accrue *tens of
    /// hours*; 600 s (10 min) is a conservative floor that excludes briefly
    /// busy daemons while comfortably admitting a real busy-loop.
    public let minOffenderCPUSeconds: Double

    public let lookback: Duration
    public let requiredProbes: Set<String> = ["system_signals"]

    /// - Parameters:
    ///   - pinnedCoresThreshold: pinned-core count gate (default 2).
    ///   - sustainSamples: consecutive samples required (default 12 ≈ 60 s).
    ///   - minOffenderCPUSeconds: cumulative-CPU floor to name a culprit
    ///     (default 600 s).
    ///   - lookback: history window; defaults wide enough for `sustainSamples`
    ///     at the 5 s poll, with generous slack (300 s ≈ 60 samples) so a few
    ///     dropped polls don't starve the window.
    public init(
        pinnedCoresThreshold: Double = 2,
        sustainSamples: Int = 12,
        minOffenderCPUSeconds: Double = 600,
        lookback: Duration = .seconds(300)
    ) {
        self.pinnedCoresThreshold = pinnedCoresThreshold
        self.sustainSamples = sustainSamples
        self.minOffenderCPUSeconds = minOffenderCPUSeconds
        self.lookback = lookback
    }

    /// True iff the last `sustainSamples` `cores_pinned` values are ALL at/
    /// above the threshold (a sustained pin). PURE — drives the gated `ps`
    /// snapshot. Returns false when there aren't yet `sustainSamples` samples
    /// (insufficient evidence → don't pay for `ps`).
    public func wantsAttribution(_ context: DiagnosisContext) -> Bool {
        sustainedPin(context)
    }

    public func evaluate(_ context: DiagnosisContext) -> Finding? {
        guard sustainedPin(context) else { return nil }

        let pinnedValues = lastPinnedWindow(context)
        // The minimum pinned-core count across the sustained window; used to
        // pick severity (a window that's *only just* at the threshold is less
        // alarming than one solidly above it).
        let minPinned = pinnedValues.min() ?? pinnedCoresThreshold

        // Try to NAME the culprit from the gated attribution snapshot.
        if let procs = context.attributedProcesses,
           let offender = ProcessAttribution.topSystemOffender(
               procs, minCPUSeconds: minOffenderCPUSeconds
           ) {
            // Severity judgment: `.critical` when the window is solidly above
            // the threshold (≥ threshold+1 pinned cores for the whole window),
            // `.warn` when it's only just AT the threshold. Rationale: a
            // genuine multi-core runaway is a `problem`; a single sustained
            // core is a `watch`-grade degradation. Documented design call.
            let severity: Severity = (minPinned >= pinnedCoresThreshold + 1) ? .critical : .warn

            var evidence: [String: String] = [
                "pid": String(offender.pid),
                "cpu_seconds": String(format: "%.1f", offender.cpuSeconds),
                "path": offender.path,
                "cores_pinned": String(format: "%.0f", minPinned),
            ]
            evidence["command"] = offender.command

            return Finding(
                detector: id,
                subject: offender.command,
                severity: severity,
                confidence: .high,
                title: "System process pinning CPU",
                explanation: "A macOS system process (\(offender.command)) has been using "
                    + "about \(Int(minPinned.rounded())) CPU core(s) for a sustained period. "
                    + "It is protected by the system (SIP), so it can't be stopped directly.",
                evidence: evidence,
                suggestedAction: "Reboot recommended",
                firstSeen: context.now,
                lastUpdated: context.now
            )
        }

        // Sustained pin but no nameable, non-suppressed system offender
        // (attribution nil, or ps named only user/suppressed procs). Degrade
        // to a LOW-confidence "unnamed slowdown" — never silence (D7).
        return Finding(
            detector: id,
            subject: "system",
            severity: .warn,
            confidence: .low,
            title: "System slowdown",
            explanation: "Sustained CPU load is degrading responsiveness, but the responsible "
                + "process couldn't be named.",
            evidence: ["cores_pinned": String(format: "%.0f", minPinned)],
            suggestedAction: "Show in Activity Monitor",
            firstSeen: context.now,
            lastUpdated: context.now
        )
    }

    // MARK: - Pure trigger helpers

    /// The `cores_pinned` values of the last `sustainSamples` samples, in
    /// chronological order. Fewer than `sustainSamples` available → returns
    /// what exists (caller treats "too few" as not-sustained).
    private func lastPinnedWindow(_ context: DiagnosisContext) -> [Double] {
        let values = context.values(probe: "system_signals", name: "cores_pinned")
        return Array(values.suffix(sustainSamples))
    }

    /// True iff there are at least `sustainSamples` samples AND every one of
    /// the last `sustainSamples` is at/above the threshold.
    private func sustainedPin(_ context: DiagnosisContext) -> Bool {
        guard sustainSamples > 0 else { return false }
        let window = lastPinnedWindow(context)
        guard window.count >= sustainSamples else { return false }
        return window.allSatisfy { $0 >= pinnedCoresThreshold }
    }
}
