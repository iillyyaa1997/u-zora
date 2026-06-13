import Foundation
import Testing
@testable import uZora

@Suite("RunawayDaemonDetector — trigger + attribution")
struct RunawayDaemonDetectorTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Build a `system_signals` `cores_pinned` series from oldest→newest, one
    /// sample every 5 s ending just before `now`.
    private func pinnedSamples(_ values: [Double]) -> [MetricsStore.Sample] {
        let n = values.count
        return values.enumerated().map { (i, v) in
            let secsAgo = Double((n - i) * 5)
            return MetricsStore.Sample(
                probe: "system_signals", key: "system", name: "cores_pinned",
                value: v, at: now.addingTimeInterval(-secsAgo)
            )
        }
    }

    private func context(
        pinned: [Double],
        attributed: [AttributedProcess]? = nil
    ) -> DiagnosisContext {
        DiagnosisContext(now: now, samples: pinnedSamples(pinned), attributedProcesses: attributed)
    }

    private func systemProc(
        _ command: String,
        path: String,
        cpuSeconds: Double,
        uid: UInt32 = 0,
        pid: Int32 = 100
    ) -> AttributedProcess {
        AttributedProcess(
            pid: pid, uid: uid, command: command, path: path,
            cpuSeconds: cpuSeconds, isSystem: ProcessAttribution.isSystemPath(path)
        )
    }

    // MARK: - wantsAttribution gate

    @Test func wantsAttribution_trueOnlyWhenLastNAllAtOrAboveThreshold() {
        let det = RunawayDaemonDetector(pinnedCoresThreshold: 2, sustainSamples: 12)

        // 12 samples all == 2 → sustained.
        #expect(det.wantsAttribution(context(pinned: Array(repeating: 2, count: 12))))
        // 12 samples all == 3 (> threshold) → sustained.
        #expect(det.wantsAttribution(context(pinned: Array(repeating: 3, count: 12))))
        // Last sample dips to 1 → NOT sustained.
        var dipped = Array(repeating: 2.0, count: 12)
        dipped[11] = 1
        #expect(!det.wantsAttribution(context(pinned: dipped)))
        // Only 11 samples → insufficient evidence → false.
        #expect(!det.wantsAttribution(context(pinned: Array(repeating: 2, count: 11))))
        // A long history that ends sustained still triggers (only the last 12
        // matter); earlier low values are ignored.
        let longSeries = Array(repeating: 0.0, count: 30) + Array(repeating: 2.0, count: 12)
        #expect(det.wantsAttribution(context(pinned: longSeries)))
        // A long history that DIPS within the last 12 does not.
        let longDip = Array(repeating: 2.0, count: 30) + [1.0] + Array(repeating: 2.0, count: 11)
        #expect(!det.wantsAttribution(context(pinned: longDip)))
    }

    // MARK: - evaluate: not sustained

    @Test func evaluate_nilWhenNotSustained() {
        let det = RunawayDaemonDetector(sustainSamples: 12)
        // Not enough samples.
        #expect(det.evaluate(context(pinned: [2, 2, 2])) == nil)
        // Enough samples but one dips below threshold.
        var dipped = Array(repeating: 2.0, count: 12)
        dipped[5] = 0
        #expect(det.evaluate(context(pinned: dipped)) == nil)
    }

    // MARK: - evaluate: names the culprit

    @Test func evaluate_namesCulpritWhenQualifyingSystemOffenderPresent() {
        let det = RunawayDaemonDetector(
            pinnedCoresThreshold: 2, sustainSamples: 12, minOffenderCPUSeconds: 600
        )
        let eco = systemProc(
            "ecosystemd",
            path: "/System/Library/PrivateFrameworks/Ecosystem.framework/Support/ecosystemd",
            cpuSeconds: 200_000, pid: 13579
        )
        // Window solidly above threshold (all == 3 ≥ 2+1) → critical.
        let ctx = context(pinned: Array(repeating: 3, count: 12), attributed: [eco])
        let f = det.evaluate(ctx)
        let finding = try? #require(f)
        #expect(finding?.detector == "runaway_daemon")
        #expect(finding?.subject == "ecosystemd")
        #expect(finding?.severity == .critical)
        #expect(finding?.confidence == .high)
        #expect(finding?.evidence?["pid"] == "13579")
        #expect(finding?.evidence?["path"]?.contains("ecosystemd") == true)
        #expect(finding?.suggestedAction == "Reboot recommended")
    }

    @Test func evaluate_warnSeverityWhenJustAtThreshold() {
        let det = RunawayDaemonDetector(
            pinnedCoresThreshold: 2, sustainSamples: 12, minOffenderCPUSeconds: 600
        )
        let eco = systemProc(
            "ecosystemd",
            path: "/System/Library/PrivateFrameworks/Ecosystem.framework/Support/ecosystemd",
            cpuSeconds: 200_000
        )
        // Window only just AT threshold (all == 2, min < threshold+1) → warn.
        let ctx = context(pinned: Array(repeating: 2, count: 12), attributed: [eco])
        let f = det.evaluate(ctx)
        #expect(f?.severity == .warn)
        #expect(f?.confidence == .high)
        #expect(f?.subject == "ecosystemd")
    }

    // MARK: - evaluate: unnamed slowdown (graceful degradation)

    @Test func evaluate_unnamedLowConfidenceWhenAttributionNil() {
        let det = RunawayDaemonDetector(sustainSamples: 12)
        // Sustained pin but attribution is nil (ps failed).
        let ctx = context(pinned: Array(repeating: 3, count: 12), attributed: nil)
        let f = det.evaluate(ctx)
        let finding = try? #require(f)
        #expect(finding?.subject == "system")
        #expect(finding?.severity == .warn)
        #expect(finding?.confidence == .low)
        #expect(finding?.suggestedAction == "Show in Activity Monitor")
        #expect(finding?.title == "System slowdown")
    }

    @Test func evaluate_unnamedWhenOnlySuppressedOrUserProcsPresent() {
        let det = RunawayDaemonDetector(
            sustainSamples: 12, minOffenderCPUSeconds: 600
        )
        let mds = systemProc("mds_stores", path: "/usr/libexec/mds_stores", cpuSeconds: 999_999)
        let userProc = AttributedProcess(
            pid: 501, uid: 501, command: "node", path: "/opt/homebrew/bin/node",
            cpuSeconds: 999_999, isSystem: false
        )
        let subThreshold = systemProc("tinyd", path: "/System/Library/CoreServices/tinyd", cpuSeconds: 5)
        let ctx = context(
            pinned: Array(repeating: 3, count: 12),
            attributed: [mds, userProc, subThreshold]
        )
        let f = det.evaluate(ctx)
        // No NAMEABLE non-suppressed system offender → unnamed low-confidence.
        #expect(f?.subject == "system")
        #expect(f?.confidence == .low)
    }

    @Test func evaluate_ignoresSuppressedEvenWhenLargest_andPicksRealCulprit() {
        let det = RunawayDaemonDetector(
            pinnedCoresThreshold: 2, sustainSamples: 12, minOffenderCPUSeconds: 600
        )
        let mds = systemProc("mds_stores", path: "/usr/libexec/mds_stores", cpuSeconds: 9_999_999)
        let eco = systemProc(
            "ecosystemd",
            path: "/System/Library/PrivateFrameworks/Ecosystem.framework/Support/ecosystemd",
            cpuSeconds: 12_345, pid: 42
        )
        let ctx = context(pinned: Array(repeating: 3, count: 12), attributed: [mds, eco])
        let f = det.evaluate(ctx)
        // mds_stores has more CPU but is suppressed → ecosystemd is named.
        #expect(f?.subject == "ecosystemd")
        #expect(f?.evidence?["pid"] == "42")
        #expect(f?.severity == .critical)
    }
}
