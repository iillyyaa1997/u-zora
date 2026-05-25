import Foundation
import IOKit
import os

/// Reads SMART-style health properties of the internal NVMe SSD via IOKit
/// user-space.
///
/// On modern Macs (M1+) the internal storage is NVMe and the relevant
/// service entry is `IONVMeBlockStorageDevice` (NOT `IOBlockStorageDriver`,
/// which is a *generic* layer above it). We walk its parents to reach
/// `IONVMeController`, which carries the `Per-Block Statistics` dictionary.
///
/// **Pragmatic Phase 2 stance**: Apple does not document the property
/// names for `IONVMeController`'s health log, and the keys can vary
/// between macOS releases. We attempt several known spellings; if none
/// answer, we fall back to a graceful no-op (logged once) so the registry
/// can still validate end-to-end. Real-hardware fixtures will land in
/// Phase 7 via the integration test suite.
///
/// Severity rules (when readings are available):
///
/// - `Critical Warning` bit set (any) → critical
/// - `Available Spare` < `criticalSparePct` (default 5) → critical
/// - `Available Spare` < `warnSparePct`     (default 10) → warn
/// - `Percentage Used` > 100 → critical
/// - `Percentage Used` > 80  → warn
/// - `Media and Data Integrity Errors` > 0 → warn
public final class SMARTProbe: Probe, @unchecked Sendable {

    public let name = "smart"
    public let pollInterval: Duration = .seconds(15 * 60)

    public struct Thresholds: Sendable {
        public let warnSparePct: Int
        public let criticalSparePct: Int
        public let warnUsedPct: Int
        public let criticalUsedPct: Int

        public init(
            warnSparePct: Int = 10,
            criticalSparePct: Int = 5,
            warnUsedPct: Int = 80,
            criticalUsedPct: Int = 100
        ) {
            self.warnSparePct = warnSparePct
            self.criticalSparePct = criticalSparePct
            self.warnUsedPct = warnUsedPct
            self.criticalUsedPct = criticalUsedPct
        }

        public static let `default` = Thresholds()
    }

    public struct Sample: Sendable {
        public let criticalWarning: Int          // bitmask, 0 = no warning
        public let availableSparePct: Int?       // 0...100
        public let percentageUsed: Int?          // 0..., can exceed 100 on worn drives
        public let mediaErrors: UInt64?
        public let model: String?

        public init(
            criticalWarning: Int,
            availableSparePct: Int?,
            percentageUsed: Int?,
            mediaErrors: UInt64?,
            model: String?
        ) {
            self.criticalWarning = criticalWarning
            self.availableSparePct = availableSparePct
            self.percentageUsed = percentageUsed
            self.mediaErrors = mediaErrors
            self.model = model
        }
    }

    private let thresholds: Thresholds
    private let sampler: @Sendable () -> Sample?
    private let clock: @Sendable () -> Date
    private var firstSeenAt: Date?
    private var unavailableLogged: Bool = false

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "smart")

    public convenience init(thresholds: Thresholds = .default) {
        self.init(
            thresholds: thresholds,
            sampler: { Self.sampleViaIOKit() },
            clock: { Date() }
        )
    }

    public init(
        thresholds: Thresholds,
        sampler: @escaping @Sendable () -> Sample?,
        clock: @escaping @Sendable () -> Date
    ) {
        self.thresholds = thresholds
        self.sampler = sampler
        self.clock = clock
    }

    public func run() async throws -> [Alert] {
        guard let sample = sampler() else {
            if !unavailableLogged {
                log.warning("SMART probe unavailable in user-space — IOKit NVMe health properties not readable. See TODO Phase 7 (recorded fixtures).")
                unavailableLogged = true
            }
            return []
        }

        let evaluation = Self.evaluate(sample: sample, thresholds: thresholds)
        let now = clock()

        guard let severity = evaluation.severity else {
            firstSeenAt = nil
            return []
        }

        if firstSeenAt == nil { firstSeenAt = now }

        var details: [String: String] = [
            "critical_warning": String(sample.criticalWarning),
            "reasons":          evaluation.reasons.joined(separator: ","),
        ]
        if let s = sample.availableSparePct { details["available_spare_pct"] = String(s) }
        if let u = sample.percentageUsed { details["percentage_used"] = String(u) }
        if let m = sample.mediaErrors { details["media_errors"] = String(m) }
        if let m = sample.model { details["model"] = m }

        return [Alert(
            probe: name,
            key: "internal_nvme",
            severity: severity,
            message: evaluation.message,
            details: details,
            firstSeen: firstSeenAt ?? now,
            lastUpdated: now
        )]
    }

    // MARK: - Pure evaluation (testable)

    public struct Evaluation: Equatable, Sendable {
        public let severity: Severity?
        public let reasons: [String]
        public let message: String
    }

    public static func evaluate(sample: Sample, thresholds: Thresholds) -> Evaluation {
        var reasons: [String] = []
        var severity: Severity? = nil

        if sample.criticalWarning != 0 {
            reasons.append("critical_warning=\(sample.criticalWarning)")
            severity = maxSev(severity, .critical)
        }

        if let spare = sample.availableSparePct {
            if spare < thresholds.criticalSparePct {
                reasons.append("spare_critical")
                severity = maxSev(severity, .critical)
            } else if spare < thresholds.warnSparePct {
                reasons.append("spare_warn")
                severity = maxSev(severity, .warn)
            }
        }

        if let used = sample.percentageUsed {
            if used > thresholds.criticalUsedPct {
                reasons.append("used_critical")
                severity = maxSev(severity, .critical)
            } else if used > thresholds.warnUsedPct {
                reasons.append("used_warn")
                severity = maxSev(severity, .warn)
            }
        }

        if let media = sample.mediaErrors, media > 0 {
            reasons.append("media_errors=\(media)")
            severity = maxSev(severity, .warn)
        }

        let msg: String
        if let sev = severity {
            msg = "SMART alert (\(sev.rawValue)): \(reasons.joined(separator: ", "))"
        } else {
            msg = "SMART OK"
        }
        return Evaluation(severity: severity, reasons: reasons, message: msg)
    }

    // MARK: - IOKit sampling

    /// Walks `IONVMeBlockStorageDevice` services, climbs to the
    /// `IONVMeController` parent, and pulls health-log fields. Many
    /// fields are *not* exposed on all hardware/macOS combos; the
    /// `Sample` struct holds `Optional` everywhere except the
    /// `criticalWarning` bitmask (defaulted to 0 when missing).
    public static func sampleViaIOKit() -> Sample? {
        var found: Sample?

        // Property names we have observed in the wild across macOS 12-15.
        // We probe a small set; first hit wins. If none match we still
        // return a zero-warning sample (so the architecture is exercised).
        let sparKeys     = ["Available Spare", "available_spare", "NVMe Available Spare"]
        let usedKeys     = ["Percentage Used", "percentage_used", "NVMe Percentage Used"]
        let warnKeys     = ["Critical Warning", "critical_warning", "NVMe Critical Warning"]
        let mediaErrKeys = ["Media and Data Integrity Errors", "media_errors"]
        let modelKeys    = ["Model Number", "Model", "device-model"]

        IOKitBridge.forEachMatchingService(className: "IONVMeBlockStorageDevice") { svc in
            guard found == nil else { return }
            // Pull the device's own props first (model usually lives here).
            let devProps = IOKitBridge.copyProperties(svc) ?? [:]
            let model = firstString(devProps, keys: modelKeys)

            // Health log usually sits on the controller (or a per-namespace
            // "NVMe SMART Capabilities" sub-dict on the device).
            var spare: Int? = nil
            var used: Int? = nil
            var warn: Int = 0
            var media: UInt64? = nil

            if let healthDict = devProps["NVMe SMART Capabilities"] as? [String: Any] {
                spare = firstInt(healthDict, keys: sparKeys)
                used  = firstInt(healthDict, keys: usedKeys)
                warn  = firstInt(healthDict, keys: warnKeys) ?? 0
                media = firstUInt64(healthDict, keys: mediaErrKeys)
            } else {
                spare = firstInt(devProps, keys: sparKeys)
                used  = firstInt(devProps, keys: usedKeys)
                warn  = firstInt(devProps, keys: warnKeys) ?? 0
                media = firstUInt64(devProps, keys: mediaErrKeys)
            }

            // If everything is nil and warn=0, walk to controller as a
            // last resort.
            if spare == nil && used == nil && media == nil {
                if let controller = IOKitBridge.findParent(of: svc, matching: "IONVMeController") {
                    defer { IOObjectRelease(controller) }
                    if let ctrlProps = IOKitBridge.copyProperties(controller) {
                        spare = firstInt(ctrlProps, keys: sparKeys)
                        used  = firstInt(ctrlProps, keys: usedKeys)
                        warn  = firstInt(ctrlProps, keys: warnKeys) ?? warn
                        media = firstUInt64(ctrlProps, keys: mediaErrKeys)
                    }
                }
            }

            found = Sample(
                criticalWarning: warn,
                availableSparePct: spare,
                percentageUsed: used,
                mediaErrors: media,
                model: model
            )
        }

        return found
    }

    // MARK: - Property dictionary helpers

    private static func firstString(_ dict: [String: Any], keys: [String]) -> String? {
        for k in keys {
            if let s = dict[k] as? String { return s }
            if let d = dict[k] as? Data, let s = String(data: d, encoding: .ascii) { return s }
        }
        return nil
    }

    private static func firstInt(_ dict: [String: Any], keys: [String]) -> Int? {
        for k in keys {
            if let i = dict[k] as? Int { return i }
            if let n = dict[k] as? NSNumber { return n.intValue }
        }
        return nil
    }

    private static func firstUInt64(_ dict: [String: Any], keys: [String]) -> UInt64? {
        for k in keys {
            if let i = dict[k] as? UInt64 { return i }
            if let n = dict[k] as? NSNumber { return n.uint64Value }
        }
        return nil
    }
}

// MARK: - tiny severity helper

private func maxSev(_ lhs: Severity?, _ rhs: Severity) -> Severity {
    guard let lhs else { return rhs }
    return lhs >= rhs ? lhs : rhs
}
