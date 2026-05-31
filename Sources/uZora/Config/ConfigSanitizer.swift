import Foundation
import os

/// Single source of truth for validating + clamping the numeric knobs a
/// caller (or a hand-edited `config.toml`) can set on a probe override.
///
/// Two boundaries consume this:
///
///  - **Write boundary** (`POST /config/probe`, MCP `uzora_set_probe_config`):
///    `validate(patch:for:)` rejects an out-of-range value with a clear
///    message → the handler returns 400 / MCP isError and does NOT persist.
///    This stops a bad value from ever reaching disk.
///
///  - **Read boundary** (`UZoraConfig(toml:)` parse + `ProbeRegistry`
///    threshold conversion): a config.toml hand-edited past the write path
///    (the file-watcher reloads it with no `allow_writes` gate) could still
///    carry a poison value. The `clamp*` helpers coerce it into a safe range
///    and log an `os_log` warning rather than trapping — so a single bad edit
///    can't crash-loop the daemon on every relaunch.
///
/// Root cause this guards against (one bug, three trap sites):
///   - `Int(double.rounded())` traps for `poll_interval_sec > Int.max`.
///   - `PowerProfile.effectiveInterval` Int64 overflow on huge seconds.
///   - `UInt64(double.rounded())` traps on negative / NaN / `> UInt64.max`
///     thresholds (e.g. `top_mem warn_threshold = -1`).
public enum ConfigSanitizer {

    private static let log = Logger(subsystem: "place.unicorns.uzora", category: "config-sanitize")

    // MARK: - Ranges (single source of truth)

    /// poll_interval_sec: 1 s .. 24 h. Below 1 s would hammer the CPU; above
    /// 24 h is meaningless for a health monitor (and a giant value overflows
    /// the Duration math downstream).
    public static let pollIntervalRange: ClosedRange<Int> = 1...86_400

    /// Per-unit sane upper bounds for a probe's warn/critical threshold. The
    /// lower bound is always 0 (negative thresholds are nonsensical for every
    /// probe unit here and underflow the UInt64 conversions).
    public enum ThresholdUnit {
        /// disk free %, cpu_temp °C, kernel_task/top_cpu CPU%.
        case percent          // 0..100
        case celsius          // 0..150
        /// top_mem RSS in GiB.
        case gibibytes        // 0..1024
        /// top_net throughput in MiB/s.
        case mibPerSec        // 0..100000

        var upperBound: Double {
            switch self {
            case .percent:   return 100
            case .celsius:   return 150
            case .gibibytes: return 1024
            case .mibPerSec: return 100_000
            }
        }
    }

    /// The threshold unit for each config-known probe name. Probes that ignore
    /// thresholds (fan/battery/smart/thermal) have no entry — a threshold for
    /// them is dropped upstream with a warning, so it never reaches validation.
    public static func thresholdUnit(for probe: String) -> ThresholdUnit? {
        switch probe {
        case "disk":        return .percent
        case "cpu_temp":    return .celsius
        case "kernel_task": return .percent
        case "top_cpu":     return .percent
        case "top_mem":     return .gibibytes
        case "top_net":     return .mibPerSec
        default:            return nil // thermal/battery/smart/fan: no thresholds
        }
    }

    // MARK: - Write boundary (reject invalid)

    /// A human-readable validation failure. The REST/MCP layer surfaces
    /// `message` in the 400 / isError body.
    public struct ValidationError: Swift.Error, Sendable, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// Validate the numeric fields of a single-probe patch BEFORE persisting.
    /// Returns `.success` if every supplied value is finite and in range,
    /// else `.failure` with the first problem found. Booleans and absent
    /// fields are always fine.
    ///
    /// `thresholdUnit` is the unit for `probe`; pass nil for a
    /// threshold-ignoring probe (then thresholds, if any, are not validated
    /// here — the caller has already decided to drop them).
    public static func validate(
        pollIntervalSec: Int?,
        warnThreshold: Double?,
        criticalThreshold: Double?,
        thresholdUnit: ThresholdUnit?
    ) -> Result<Void, ValidationError> {
        if let sec = pollIntervalSec {
            guard pollIntervalRange.contains(sec) else {
                return .failure(ValidationError(
                    "poll_interval_sec must be an integer in \(pollIntervalRange.lowerBound)…\(pollIntervalRange.upperBound) (got \(sec))"
                ))
            }
        }
        if let unit = thresholdUnit {
            for (label, value) in [("warn_threshold", warnThreshold), ("critical_threshold", criticalThreshold)] {
                guard let v = value else { continue }
                guard v.isFinite else {
                    return .failure(ValidationError("\(label) must be a finite number (got \(v))"))
                }
                guard v >= 0, v <= unit.upperBound else {
                    return .failure(ValidationError(
                        "\(label) must be in 0…\(formatted(unit.upperBound)) for this probe (got \(formatted(v)))"
                    ))
                }
            }
        }
        return .success(())
    }

    /// Validate a raw `poll_interval_sec` supplied as a Double (the JSON codec
    /// hands numbers through as Double). Rejects non-finite / non-integral /
    /// out-of-range BEFORE the `Int(_:)` conversion that would otherwise trap
    /// (e.g. 1e22). On success returns the integer value.
    public static func validatedPollInterval(fromDouble raw: Double) -> Result<Int, ValidationError> {
        guard raw.isFinite else {
            return .failure(ValidationError("poll_interval_sec must be a finite number (got \(raw))"))
        }
        // Reject anything outside the representable + sane range before Int().
        guard raw >= Double(pollIntervalRange.lowerBound),
              raw <= Double(pollIntervalRange.upperBound) else {
            return .failure(ValidationError(
                "poll_interval_sec must be in \(pollIntervalRange.lowerBound)…\(pollIntervalRange.upperBound) (got \(formatted(raw)))"
            ))
        }
        // In range → safe to round to Int.
        return .success(Int(raw.rounded()))
    }

    // MARK: - Read boundary (clamp, never trap)

    /// Clamp a `poll_interval_sec` read from disk into the safe range. A value
    /// outside the range is coerced to the nearest bound + logged. Used by
    /// `ProbeRegistry.applyPollOverride`.
    public static func clampPollIntervalSec(_ sec: Int) -> Int {
        if sec < pollIntervalRange.lowerBound {
            log.warning("config: poll_interval_sec=\(sec, privacy: .public) below floor; clamping to \(pollIntervalRange.lowerBound, privacy: .public)")
            return pollIntervalRange.lowerBound
        }
        if sec > pollIntervalRange.upperBound {
            log.warning("config: poll_interval_sec=\(sec, privacy: .public) above ceiling; clamping to \(pollIntervalRange.upperBound, privacy: .public)")
            return pollIntervalRange.upperBound
        }
        return sec
    }

    /// Clamp a threshold read from disk into `0…unit.upperBound`. A
    /// non-finite or out-of-range value is coerced + logged. Returns nil to
    /// mean "skip this override, keep the probe default" only when the value
    /// is non-finite (NaN/∞) — a finite out-of-range value is clamped so the
    /// user's intent (very high / very low) is preserved as far as is sane.
    public static func clampThreshold(_ value: Double, unit: ThresholdUnit, label: String = "threshold") -> Double? {
        guard value.isFinite else {
            log.warning("config: \(label, privacy: .public)=\(value, privacy: .public) is non-finite; ignoring override (keeping default)")
            return nil
        }
        if value < 0 {
            log.warning("config: \(label, privacy: .public)=\(value, privacy: .public) is negative; clamping to 0")
            return 0
        }
        if value > unit.upperBound {
            log.warning("config: \(label, privacy: .public)=\(value, privacy: .public) above \(unit.upperBound, privacy: .public); clamping")
            return unit.upperBound
        }
        return value
    }

    // MARK: - Helpers

    /// Compact number formatting for error messages (drops a trailing `.0`).
    private static func formatted(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 {
            return String(Int64(v))
        }
        return String(v)
    }
}
