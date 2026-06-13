import Testing
import Foundation
@preconcurrency import UserNotifications  // cross-SDK Sendable gap (see NotificationCenter.swift)
@testable import uZora

/// Phase 4 — the two-track finding-notification policy (plan D5 / R1),
/// validated through the PURE `contentIfShouldNotify` decision fn so no real
/// UNUserNotificationCenter is needed (mirrors `NotificationFilterTests`).
@Suite("Finding notification — two-track policy")
struct FindingNotificationTests {

    private func finding(
        detector: String = "runaway_daemon",
        subject: String = "ecosystemd",
        severity: Severity,
        confidence: Confidence,
        title: String = "System daemon pinning CPU",
        explanation: String = "ecosystemd is re-hashing code signatures in a loop.",
        suggestedAction: String? = "reboot recommended"
    ) -> Finding {
        Finding(
            detector: detector,
            subject: subject,
            severity: severity,
            confidence: confidence,
            title: title,
            explanation: explanation,
            evidence: ["cores_pinned": "2"],
            suggestedAction: suggestedAction,
            firstSeen: Date(timeIntervalSince1970: 1000),
            lastUpdated: Date(timeIntervalSince1970: 1100)
        )
    }

    private let cfg = NotificationsConfig()

    // MARK: - Hard track (critical → always)

    @Test @MainActor func critical_diagnosed_firesTimeSensitive() {
        let event = FindingEvent.diagnosed(finding(severity: .critical, confidence: .low))
        let content = UZoraNotificationCenter.contentIfShouldNotify(findingEvent: event, config: cfg)
        #expect(content != nil)
        #expect(content?.interruptionLevel == .timeSensitive)
        #expect(content?.sound == .defaultCritical)
    }

    @Test @MainActor func critical_firesAtEveryConfidence() {
        for conf in Confidence.allCases {
            let event = FindingEvent.diagnosed(finding(severity: .critical, confidence: conf))
            let content = UZoraNotificationCenter.contentIfShouldNotify(findingEvent: event, config: cfg)
            #expect(content?.interruptionLevel == .timeSensitive, "conf=\(conf)")
        }
    }

    @Test @MainActor func critical_rediagnosed_alsoFires() {
        let f = finding(severity: .critical, confidence: .high)
        let event = FindingEvent.rediagnosed(f, previousSeverity: .warn, previousConfidence: .high)
        let content = UZoraNotificationCenter.contentIfShouldNotify(findingEvent: event, config: cfg)
        #expect(content?.interruptionLevel == .timeSensitive)
    }

    // MARK: - Trend track (warn → only at high confidence)

    @Test @MainActor func warn_high_firesActive() {
        let event = FindingEvent.diagnosed(finding(severity: .warn, confidence: .high))
        let content = UZoraNotificationCenter.contentIfShouldNotify(findingEvent: event, config: cfg)
        #expect(content != nil)
        #expect(content?.interruptionLevel == .active)
        #expect(content?.sound == .default)
    }

    @Test @MainActor func warn_medium_suppressed() {
        let event = FindingEvent.diagnosed(finding(severity: .warn, confidence: .medium))
        let content = UZoraNotificationCenter.contentIfShouldNotify(findingEvent: event, config: cfg)
        #expect(content == nil)
    }

    @Test @MainActor func warn_low_suppressed() {
        let event = FindingEvent.diagnosed(finding(severity: .warn, confidence: .low))
        let content = UZoraNotificationCenter.contentIfShouldNotify(findingEvent: event, config: cfg)
        #expect(content == nil)
    }

    // MARK: - Suppressed classes

    @Test @MainActor func info_neverFires() {
        for conf in Confidence.allCases {
            let event = FindingEvent.diagnosed(finding(severity: .info, confidence: conf))
            let content = UZoraNotificationCenter.contentIfShouldNotify(findingEvent: event, config: cfg)
            #expect(content == nil, "conf=\(conf)")
        }
    }

    @Test @MainActor func resolved_neverFires() {
        let event = FindingEvent.resolved("runaway_daemon:ecosystemd")
        let content = UZoraNotificationCenter.contentIfShouldNotify(findingEvent: event, config: cfg)
        #expect(content == nil)
    }

    // MARK: - Content shape

    @Test @MainActor func content_titleBodyUserInfoShape() {
        let f = finding(severity: .critical, confidence: .high, suggestedAction: "reboot recommended")
        let event = FindingEvent.diagnosed(f)
        let content = UZoraNotificationCenter.contentIfShouldNotify(findingEvent: event, config: cfg)
        #expect(content?.title == f.title)
        #expect(content?.body == f.explanation)
        #expect(content?.categoryIdentifier == "uzora.cat.diagnosis")
        #expect(content?.userInfo["detector"] as? String == "runaway_daemon")
        #expect(content?.userInfo["subject"] as? String == "ecosystemd")
        #expect(content?.userInfo["severity"] as? String == "critical")
        #expect(content?.userInfo["confidence"] as? String == "high")
        #expect(content?.userInfo["suggested_action"] as? String == "reboot recommended")
    }

    @Test @MainActor func content_nilSuggestedActionBecomesEmptyString() {
        let f = finding(severity: .critical, confidence: .high, suggestedAction: nil)
        let event = FindingEvent.diagnosed(f)
        let content = UZoraNotificationCenter.contentIfShouldNotify(findingEvent: event, config: cfg)
        #expect(content?.userInfo["suggested_action"] as? String == "")
    }

    @Test @MainActor func diagnosisCategory_targetsActivityMonitor() {
        let entry = NotificationActionMap.diagnosis
        #expect(entry.categoryID == "uzora.cat.diagnosis")
        #expect(entry.targetURL.path.contains("Activity Monitor.app"))
        // The diagnosis "probe" name is deliberately NOT an actionable probe
        // (no Q10 "Run cleanup" button on a finding).
        #expect(entry.probeName == "diagnosis")
    }
}
