import Foundation
import IOKit
import IOKit.ps
import os

/// Coarse-grained execution-environment state for the agent.
///
/// Used by the registry scheduler to stretch poll intervals on battery and
/// suppress low-severity alerts during Focus sessions. The five states
/// were locked in `_planing/mac-agent-concept-questions-2026-05-25.md`
/// (Q22).
public enum PowerState: String, Sendable, Equatable, CaseIterable {
    case acConnectedLidOpen       // baseline — full speed
    case acConnectedLidClosed     // headless, full speed
    case batteryLidOpen           // active use on battery — downshift
    case batteryLidClosed         // suspended/away — minimal
    case focusActive              // Focus mode is active — reduce alerts but probe normally
}

/// Computed per-state behaviour: how often probes should fire and the
/// minimum severity at which alerts surface to the EventBus.
public struct PowerProfile: Sendable, Equatable {
    public let state: PowerState
    /// Multiplier applied to each probe's `pollInterval`. 1.0 = base
    /// cadence, 2.0 = halve the rate, 6.0 = one-sixth, etc.
    public let pollMultiplier: Double
    /// Suppress alerts below this severity. Set to `.info` for "no
    /// suppression" (info is the lowest).
    public let alertSeverityFloor: Severity

    public init(state: PowerState, pollMultiplier: Double, alertSeverityFloor: Severity) {
        self.state = state
        self.pollMultiplier = pollMultiplier
        self.alertSeverityFloor = alertSeverityFloor
    }

    /// Default mapping table (see Phase 3 spec).
    public static func defaultMapping(for state: PowerState) -> PowerProfile {
        switch state {
        case .acConnectedLidOpen:
            return PowerProfile(state: state, pollMultiplier: 1.0, alertSeverityFloor: .info)
        case .acConnectedLidClosed:
            return PowerProfile(state: state, pollMultiplier: 1.0, alertSeverityFloor: .info)
        case .batteryLidOpen:
            return PowerProfile(state: state, pollMultiplier: 3.0, alertSeverityFloor: .info)
        case .batteryLidClosed:
            return PowerProfile(state: state, pollMultiplier: 6.0, alertSeverityFloor: .warn)
        case .focusActive:
            return PowerProfile(state: state, pollMultiplier: 1.0, alertSeverityFloor: .critical)
        }
    }

    /// Compute the effective poll interval for a probe.
    public func effectiveInterval(_ base: Duration) -> Duration {
        // Duration is integer-nanoseconds; multiply via Double then clamp.
        let components = base.components
        let baseNanos = components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
        let scaled = Double(baseNanos) * pollMultiplier
        let clamped = max(scaled, 100_000_000) // 100 ms floor — never busy-loop
        return .nanoseconds(Int64(clamped))
    }

    /// Returns true if an alert at `severity` should be suppressed in the
    /// current profile (i.e. severity is below the floor).
    public func suppresses(severity: Severity) -> Bool {
        severity < alertSeverityFloor
    }
}

// MARK: - Source signals (testable)

/// The three independent signals the monitor reads to compose a `PowerState`.
public struct PowerSignals: Sendable, Equatable {
    public let onAC: Bool
    public let lidOpen: Bool
    public let focusActive: Bool

    public init(onAC: Bool, lidOpen: Bool, focusActive: Bool) {
        self.onAC = onAC
        self.lidOpen = lidOpen
        self.focusActive = focusActive
    }
}

extension PowerState {
    /// Pure state-machine composition: given three boolean signals,
    /// what state are we in? Focus overrides everything else (per Q22 in
    /// the planning doc — Focus is a user-explicit "stop bothering me"
    /// signal and trumps the laptop-vs-desktop signal).
    public static func compose(from signals: PowerSignals) -> PowerState {
        if signals.focusActive {
            return .focusActive
        }
        switch (signals.onAC, signals.lidOpen) {
        case (true,  true):  return .acConnectedLidOpen
        case (true,  false): return .acConnectedLidClosed
        case (false, true):  return .batteryLidOpen
        case (false, false): return .batteryLidClosed
        }
    }
}

// MARK: - Monitor actor

/// Observes power source / clamshell / Focus state and publishes the
/// current `PowerProfile` to subscribers.
///
/// **Implementation strategy**:
///
/// - **AC vs battery**: read `IOPSCopyPowerSourcesInfo()` + iterate sources.
///   Polled every 5 seconds (cheap; no notification ring registered in
///   Phase 3 to keep the actor surface simple).
/// - **Lid state**: read `AppleClamshellState` from the `IOPMrootDomain`
///   registry entry. Treat absence as "lid open" (mini/Studio/Pro have
///   no lid; the property simply doesn't exist).
/// - **Focus active**: stubbed to `false` in Phase 3. Focus detection
///   without entitlements is surprisingly hard — the public
///   `INFocusStatusCenter` requires user-granted authorization and runs
///   only on iOS surface in macOS. Phase 5 will revisit when the
///   Settings UI lands; for now we always return `false` and document
///   the limitation in the menu bar.
///
/// All three signals can be overridden via the test-friendly initializer
/// `init(reader:)` for unit testing.
public actor PowerProfileMonitor {

    public typealias SignalReader = @Sendable () -> PowerSignals

    public typealias Observer = @Sendable (PowerProfile) -> Void

    private let reader: SignalReader
    private var observers: [(UUID, Observer)] = []
    private var pollTask: Task<Void, Never>?
    private var lastSignals: PowerSignals?
    private var lastProfile: PowerProfile?
    private let pollInterval: Duration

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "power-profile")

    /// Designated initializer.
    public init(reader: @escaping SignalReader = PowerProfileMonitor.liveReader,
                pollInterval: Duration = .seconds(5)) {
        self.reader = reader
        self.pollInterval = pollInterval
    }

    /// Snapshot the *current* profile by reading signals synchronously.
    public func current() -> PowerProfile {
        let signals = reader()
        let state = PowerState.compose(from: signals)
        let profile = PowerProfile.defaultMapping(for: state)
        lastSignals = signals
        lastProfile = profile
        return profile
    }

    /// Subscribe to profile changes. The callback is invoked once
    /// immediately with the current profile, then on every detected
    /// change. Returns an opaque token; pass it to `unobserve(_:)` to
    /// detach. Phase 3 call sites are lifetime-of-app and discard it.
    @discardableResult
    public func observe(_ callback: @escaping Observer) -> UUID {
        let token = UUID()
        observers.append((token, callback))
        // Fire once with the current profile so the subscriber has
        // initial state without needing a separate `current()` call.
        callback(current())
        return token
    }

    public func unobserve(_ token: UUID) {
        observers.removeAll { $0.0 == token }
    }

    /// Begin the polling loop. Idempotent.
    public func start() {
        guard pollTask == nil else { return }
        let interval = pollInterval
        log.info("PowerProfileMonitor started, poll interval = \(interval.components.seconds, privacy: .public)s")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Stop the polling loop. Idempotent.
    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        log.info("PowerProfileMonitor stopped")
    }

    /// One iteration of the polling loop: read signals, compose state,
    /// notify observers if it changed.
    private func tick() {
        let signals = reader()
        let state = PowerState.compose(from: signals)
        let profile = PowerProfile.defaultMapping(for: state)

        defer {
            lastSignals = signals
            lastProfile = profile
        }

        guard let previous = lastProfile else {
            // First tick after start — notify everyone with the initial
            // value so observers stay in sync even if they subscribed
            // before start().
            broadcast(profile)
            return
        }

        if previous != profile {
            log.info("PowerProfile changed \(previous.state.rawValue, privacy: .public) → \(profile.state.rawValue, privacy: .public)")
            broadcast(profile)
        }
    }

    private func broadcast(_ profile: PowerProfile) {
        for (_, callback) in observers {
            callback(profile)
        }
    }

    // MARK: - Live signal reader

    /// Default reader that talks to IOKit. Safe on every Mac.
    public static let liveReader: SignalReader = {
        let onAC = readOnAC()
        let lidOpen = readLidOpen()
        let focusActive = readFocusActive()
        return PowerSignals(onAC: onAC, lidOpen: lidOpen, focusActive: focusActive)
    }

    private static func readOnAC() -> Bool {
        // Two-step: external power adapter details + IOPS source state.
        // External adapter present → on AC (covers laptops on charger).
        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() {
            let dict = adapter as? [String: Any] ?? [:]
            // Presence of a non-empty dict means an adapter is reporting.
            if !dict.isEmpty {
                return true
            }
        }

        // Fallback: walk power sources, look for AC source state.
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            // Mac mini / Studio / Pro without battery report no power
            // sources at all — they're permanently on AC.
            return true
        }

        for src in sources {
            guard let dict = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any]
            else { continue }
            let state = dict[kIOPSPowerSourceStateKey] as? String ?? ""
            if state == kIOPSACPowerValue {
                return true
            }
        }
        return false
    }

    private static func readLidOpen() -> Bool {
        // AppleClamshellState lives on the IOPMrootDomain entry. Returns
        // a CFBoolean: true = lid closed, false = lid open. Devices
        // without a lid (mini/Studio/Pro/iMac) don't publish the property
        // — we treat absence as "lid open" so they always score as
        // active-use.
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOPowerManagement:/IOPMrootDomain")
        let entryAlt: io_registry_entry_t = {
            if entry != 0 { return entry }
            // Fallback path used by some macOS releases.
            return IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOPMrootDomain")
        }()
        guard entryAlt != 0 else { return true }
        defer { IOObjectRelease(entryAlt) }

        guard let prop = IORegistryEntryCreateCFProperty(
            entryAlt,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool else {
            return true
        }
        return !prop // property=true means closed
    }

    private static func readFocusActive() -> Bool {
        // Deliberately returns false on the free, ad-hoc-signed build.
        //
        // There is no zero-cost, reliable way to AUTO-detect the active
        // Focus mode on a non-sandboxed, ad-hoc-signed app targeting
        // macOS 26 Tahoe:
        //
        //   • INFocusStatusCenter (Intents) — needs the "Communication
        //     Notifications" capability (`com.apple.developer.usernotif-
        //     ications.communication`), which only a paid Apple Developer
        //     provisioning profile can grant. Ad-hoc `codesign --sign -`
        //     can't carry it, so requestAuthorization never succeeds.
        //   • ~/Library/DoNotDisturb/DB/Assertions.json — requires Full
        //     Disk Access AND its format/location changed on Tahoe, so the
        //     long-standing file-scrape trick is broken on our target OS.
        //   • SetFocusFilterIntent (AppIntents) — works free + non-sandbox,
        //     but it's a PUSH model: the user configures uZora as a Focus
        //     Filter in System Settings; it isn't auto-detection. A future
        //     opt-in (see ROADMAP); intentionally not wired here.
        //
        // The important part: we don't NEED app-side detection for the
        // actual product requirement (Q22 — "warn stays quiet in Focus,
        // critical pierces"). macOS already enforces that through
        // notification interruption levels: warn banners ship as `.active`
        // (the OS withholds them during Focus) and critical ships as
        // `.timeSensitive` (pierces Focus when the user has allowed Time-
        // Sensitive notifications for uZora). See UZoraNotificationCenter.
        //
        // So `focusActive` stays false → PowerProfile never enters the
        // `.focusActive` state → uZora never additionally suppresses warn
        // alerts from the EventBus/JSONL/MCP channels (which LLM clients
        // and the popover SHOULD keep seeing regardless of Focus). The
        // .focusActive PowerState + PowerSignals.focusActive field remain
        // as a hook a future SetFocusFilterIntent / paid build can feed.
        return false
    }
}
