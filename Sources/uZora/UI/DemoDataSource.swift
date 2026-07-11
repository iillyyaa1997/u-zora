import Foundation
import Combine

/// A self-contained motion demo that drives EVERY popover block — no probe
/// pipeline, no `AppDelegate`, no channels. It conforms to `PopoverDataSource`
/// so `PopoverView(state: DemoDataSource())` renders the exact same layout as
/// production, only with synthetic, animated data (D2):
///
/// - sparkline buffers oscillate (sine) so the mini-charts move;
/// - the verdict cycles good → watch → degraded → problem with matching
///   headline, findings, and tint (tint derives from `verdict` via the
///   `PopoverDataSource` extension — no duplicated mapping);
/// - sample active alerts + findings appear then clear as the verdict cycles;
/// - the top-CPU / top-memory lists rotate;
/// - the channel dots toggle.
///
/// Advance is driven by its own ~5s `Timer` (the proven cross-SDK pattern: a
/// plain `Timer` whose tick spawns `Task { @MainActor in … }`). Construct with
/// `autostart: false` to get a fully-populated static snapshot with no live
/// timer (used by tests).
///
/// Opt-in only: `PopoverGate` swaps this in for the live `UIState` when
/// `UZORA_DEMO_POPOVER` is truthy (default off ⇒ zero behavior change).
@MainActor
final class DemoDataSource: ObservableObject, PopoverDataSource {

    // Header chrome. `startedAt` an hour ago so the uptime label reads "1h".
    @Published var powerStateLabel: String = "battery"
    @Published var overallSeverity: Severity? = nil
    @Published var startedAt: Date = Date().addingTimeInterval(-3720)

    // Verdict card.
    @Published var verdict: VerdictLevel = .good
    @Published var verdictHeadline: String = Verdict.healthyHeadline
    @Published var findings: [Finding] = []

    // Attention zone.
    @Published var activeAlerts: [Alert] = []

    // A4c inline quick-actions: a plausible pre-resolved map so the Layout-tab
    // demo preview shows the finding-card "Fix" button (the demo's `degraded`
    // phase emits a disk finding, whose derived probe is `disk`). The demo
    // handlers stay no-ops — the preview never runs a real action.
    @Published var availableActionsByProbe: [String: [ActionDescriptor]] = [
        "disk": ActionRegistry.Descriptors.all,
    ]

    // System overview tiles.
    @Published var cpuTempLabel: String = "—"
    @Published var diskFreeLabel: String = "—"
    @Published var batteryLabel: String = "—"
    @Published var memoryLabel: String = "—"
    @Published var cpuTempHistory: [Double] = []
    @Published var diskFreeHistory: [Double] = []
    @Published var batteryHistory: [Double] = []
    @Published var memoryHistory: [Double] = []

    // A4a expanded-catalog tiles (opt-in, default-OFF) — animated so the
    // Layout-tab demo preview shows them moving once enabled. cores-pinned is
    // an integer count that steps with the verdict cycle below.
    @Published var gpuLabel: String = "—"
    @Published var coresPinnedLabel: String = "—"
    @Published var swapInLabel: String = "—"
    @Published var kernelTaskLabel: String = "—"
    @Published var gpuHistory: [Double] = []
    @Published var coresPinnedHistory: [Double] = []
    @Published var swapInHistory: [Double] = []
    @Published var kernelTaskHistory: [Double] = []

    // Memory-pressure LEVEL (D6) for the default Memory tile — cycled with the
    // verdict below so the tile visibly changes color in demo mode.
    @Published var memPressureLevel: Int? = nil

    // Top processes.
    @Published var topCPUProcesses: [UIState.ProcessSnap] = []
    @Published var topMemProcesses: [UIState.ProcessSnap] = []

    // A4b expanded catalog (opt-in, default-OFF) — populated so the Layout-tab
    // demo preview shows both new blocks once enabled: a wavy 7-day series and a
    // couple of fake network talkers.
    @Published var sevenDayHistory: [Double] = []
    @Published var topNetProcesses: [UIState.NetSnap] = []

    // Recent actions.
    @Published var recentActions: [AuditLog.Entry] = []

    // Channel status.
    @Published var httpAlive: Bool = true
    @Published var mcpAlive: Bool = true
    @Published var jsonlAlive: Bool = true

    // B5: synthetic connected-LLM-client count for the footer "LLM" pill.
    // Cycled 0 → 1 → 2 with the tick (paired with `mcpAlive`) so the pill
    // visibly steps through off / configured / connected(N) in demo mode.
    @Published var llmClientsConnected: Int = 0

    // MARK: - Motion driver state

    /// Monotonic step counter — drives the sine phase, list rotation, dots.
    private var tick: Int = 0
    /// Cursor into the verdict cycle. Starts at `.degraded` so the very first
    /// (pre-timer) snapshot already populates findings + alerts.
    private let verdictCycle: [VerdictLevel] = [.good, .watch, .degraded, .problem]
    private var phaseIndex: Int = 2
    private var timer: Timer?

    /// Demo cores-pinned count — stepped with the verdict cycle (calm → 1,
    /// problem → many) so the A4a count tile visibly changes as the demo runs.
    private var coresPinnedValue: Double = 1

    // MARK: - Env gate

    /// True when `UZORA_DEMO_POPOVER` is set to a truthy value. Mirrors
    /// `SyntheticAlertProbe.fromEnvironment()`. Any non-empty value except
    /// `0` / `false` / `no` counts as on.
    nonisolated static var isEnabledInEnvironment: Bool {
        guard let raw = ProcessInfo.processInfo.environment["UZORA_DEMO_POPOVER"],
              !raw.isEmpty else {
            return false
        }
        let v = raw.lowercased()
        return v != "0" && v != "false" && v != "no"
    }

    // MARK: - Lifecycle

    init(autostart: Bool = true) {
        seedHistories()
        refresh(advancePhase: false)  // populate every block once, no live timer needed
        if autostart { start() }
    }

    /// Begin the ~5s motion loop (idempotent).
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Advance one motion step (also callable directly from tests).
    func step() {
        refresh(advancePhase: true)
    }

    // MARK: - Refresh

    private func refresh(advancePhase: Bool) {
        if advancePhase {
            tick &+= 1
            phaseIndex = (phaseIndex + 1) % verdictCycle.count
        }
        applyVerdict(verdictCycle[phaseIndex])
        rollHistories()
        refreshLabels()
        rotateProcesses()
        toggleChannels()
        refreshRecentActions()
    }

    // MARK: - Verdict / alerts / findings

    private func applyVerdict(_ level: VerdictLevel) {
        verdict = level
        switch level {
        case .good:
            verdictHeadline = Verdict.healthyHeadline
            findings = []
            activeAlerts = []
            overallSeverity = nil
            memPressureLevel = 0  // normal → green
            coresPinnedValue = 1
        case .watch:
            verdictHeadline = "Memory usage is creeping up"
            findings = [
                demoFinding(
                    detector: "memory_pressure", subject: "memory",
                    severity: .warn, confidence: .low,
                    title: "Memory usage is creeping up",
                    explanation: "Resident memory has trended upward over the last few minutes.",
                    action: nil
                ),
            ]
            activeAlerts = [
                demoAlert(probe: "memory", key: "pressure", severity: .info,
                          message: "Memory pressure elevated (demo)"),
            ]
            overallSeverity = .info
            memPressureLevel = 1  // warn → amber
            coresPinnedValue = 2
        case .degraded:
            verdictHeadline = "Disk is filling up fast"
            findings = [
                demoFinding(
                    detector: "disk_hard", subject: "/",
                    severity: .warn, confidence: .high,
                    title: "Disk is filling up fast",
                    explanation: "Free space on the startup disk dropped sharply.",
                    action: "Review large caches and downloads"
                ),
                demoFinding(
                    detector: "thermal", subject: "cpu",
                    severity: .info, confidence: .medium,
                    title: "CPU is running warm",
                    explanation: "Sustained temperature above the comfortable range.",
                    action: nil
                ),
            ]
            activeAlerts = [
                demoAlert(probe: "disk", key: "/", severity: .warn,
                          message: "Startup disk free space low (demo)"),
            ]
            overallSeverity = .warn
            memPressureLevel = 1  // warn → amber
            coresPinnedValue = 4
        case .problem:
            verdictHeadline = "A system daemon is pinning the CPU"
            findings = [
                demoFinding(
                    detector: "runaway_daemon", subject: "mdworker_shared",
                    severity: .critical, confidence: .high,
                    title: "A system daemon is pinning the CPU",
                    explanation: "mdworker_shared has held a full core for several minutes.",
                    action: "A reboot usually clears this"
                ),
            ]
            activeAlerts = [
                demoAlert(probe: "cpu", key: "runaway", severity: .critical,
                          message: "Runaway process detected (demo)"),
                demoAlert(probe: "disk", key: "/", severity: .warn,
                          message: "Startup disk free space low (demo)"),
            ]
            overallSeverity = .critical
            memPressureLevel = 2  // critical → red
            coresPinnedValue = 8
        }
    }

    private func demoFinding(
        detector: String, subject: String,
        severity: Severity, confidence: Confidence,
        title: String, explanation: String, action: String?
    ) -> Finding {
        let now = Date()
        return Finding(
            detector: detector, subject: subject,
            severity: severity, confidence: confidence,
            title: title, explanation: explanation,
            evidence: nil, suggestedAction: action,
            firstSeen: now.addingTimeInterval(-180), lastUpdated: now
        )
    }

    private func demoAlert(
        probe: String, key: String, severity: Severity, message: String
    ) -> Alert {
        let now = Date()
        return Alert(
            probe: probe, key: key, severity: severity, message: message,
            details: ["demo": "true"],
            firstSeen: now.addingTimeInterval(-120), lastUpdated: now
        )
    }

    // MARK: - Sparklines

    /// One oscillating sample. Kept to two arithmetic ops with a precomputed
    /// `sin` (cross-SDK type-checker guard — no multi-term literal chains).
    private func wave(base: Double, amp: Double, phase: Double, at index: Int) -> Double {
        let angle = Double(index) * 0.35 + phase
        let s = sin(angle)
        let delta = amp * s
        return base + delta
    }

    private func seedHistories() {
        var cpu: [Double] = []
        var disk: [Double] = []
        var batt: [Double] = []
        var mem: [Double] = []
        var gpu: [Double] = []
        var swap: [Double] = []
        var kern: [Double] = []
        var cores: [Double] = []
        for i in 0..<60 {
            cpu.append(wave(base: 52, amp: 9, phase: 0.0, at: i))
            disk.append(wave(base: 40, amp: 6, phase: 1.6, at: i))
            batt.append(wave(base: 70, amp: 18, phase: 3.1, at: i))
            mem.append(wave(base: 62, amp: 15, phase: 0.8, at: i))
            gpu.append(wave(base: 35, amp: 22, phase: 2.2, at: i))
            swap.append(wave(base: 90, amp: 70, phase: 0.5, at: i))
            kern.append(wave(base: 12, amp: 7, phase: 1.1, at: i))
            cores.append(Double((i % 3) + 1))
        }
        cpuTempHistory = cpu
        diskFreeHistory = disk
        batteryHistory = batt
        memoryHistory = mem
        gpuHistory = gpu
        swapInHistory = swap
        kernelTaskHistory = kern
        coresPinnedHistory = cores

        // A4b: a static wavy 7-day series (~168 hourly points, like the real
        // bucketed CPU-temp series) so the `sevenDayChart` block draws a chart.
        var week: [Double] = []
        for i in 0..<168 {
            week.append(wave(base: 48, amp: 11, phase: 0.4, at: i))
        }
        sevenDayHistory = week

        // A4b: a couple of fake network talkers so the `topNet` block populates.
        topNetProcesses = [
            UIState.NetSnap(pid: 501, command: "Google Chrome",
                            bytesInPerSec: 1_310_720, bytesOutPerSec: 348_160),
            UIState.NetSnap(pid: 733, command: "com.apple.WebKit.Networking",
                            bytesInPerSec: 262_144, bytesOutPerSec: 51_200),
            UIState.NetSnap(pid: 902, command: "Dropbox",
                            bytesInPerSec: 4096, bytesOutPerSec: 786_432),
        ]
    }

    private func rollHistories() {
        cpuTempHistory = rolled(cpuTempHistory, wave(base: 52, amp: 9, phase: 0.0, at: tick + 60))
        diskFreeHistory = rolled(diskFreeHistory, wave(base: 40, amp: 6, phase: 1.6, at: tick + 60))
        batteryHistory = rolled(batteryHistory, wave(base: 70, amp: 18, phase: 3.1, at: tick + 60))
        memoryHistory = rolled(memoryHistory, wave(base: 62, amp: 15, phase: 0.8, at: tick + 60))
        gpuHistory = rolled(gpuHistory, wave(base: 35, amp: 22, phase: 2.2, at: tick + 60))
        swapInHistory = rolled(swapInHistory, wave(base: 90, amp: 70, phase: 0.5, at: tick + 60))
        kernelTaskHistory = rolled(kernelTaskHistory, wave(base: 12, amp: 7, phase: 1.1, at: tick + 60))
        coresPinnedHistory = rolled(coresPinnedHistory, coresPinnedValue)
    }

    private func rolled(_ buffer: [Double], _ next: Double) -> [Double] {
        var out = buffer
        out.append(next)
        if out.count > 60 { out.removeFirst(out.count - 60) }
        return out
    }

    private func refreshLabels() {
        if let t = cpuTempHistory.last { cpuTempLabel = String(format: "%.0f°C", t) }
        if let d = diskFreeHistory.last { diskFreeLabel = String(format: "%.0f%%", d) }
        if let b = batteryHistory.last { batteryLabel = String(format: "%.0f%%", b) }
        if let m = memoryHistory.last { memoryLabel = String(format: "%.0f%%", m) }
        if let g = gpuHistory.last { gpuLabel = String(format: "%.0f%%", g) }
        if let s = swapInHistory.last { swapInLabel = String(format: "%.0f/s", s) }
        if let k = kernelTaskHistory.last { kernelTaskLabel = String(format: "%.0f%%", k) }
        coresPinnedLabel = String(format: "%.0f", coresPinnedValue)
        powerStateLabel = (tick % 2 == 0) ? "battery" : "ac"
    }

    // MARK: - Processes

    private let cpuNames = ["mdworker_shared", "WindowServer", "kernel_task", "Safari", "Xcode", "Music"]
    private let memNames = ["Xcode", "Safari", "Google Chrome", "Docker", "Photos"]

    private func rotateProcesses() {
        var cpu: [UIState.ProcessSnap] = []
        let cpuRot = tick % cpuNames.count
        for rank in 0..<5 {
            let name = cpuNames[(cpuRot + rank) % cpuNames.count]
            cpu.append(UIState.ProcessSnap(
                pid: Int32(1000 + cpuRot + rank),
                name: name,
                cpuPct: demoCPUPercent(rank: rank),
                rssBytes: 0
            ))
        }
        topCPUProcesses = cpu

        var mem: [UIState.ProcessSnap] = []
        let memRot = tick % memNames.count
        for rank in 0..<3 {
            let name = memNames[(memRot + rank) % memNames.count]
            mem.append(UIState.ProcessSnap(
                pid: Int32(2000 + memRot + rank),
                name: name,
                cpuPct: 0,
                rssBytes: demoRSSBytes(rank: rank)
            ))
        }
        topMemProcesses = mem
    }

    private func demoCPUPercent(rank: Int) -> Double {
        let ceiling = 80.0 - Double(rank) * 12.0
        let jitter = 4.0 * sin(Double(tick) * 0.5)
        let value = ceiling + jitter
        return max(0.1, value)
    }

    private func demoRSSBytes(rank: Int) -> UInt64 {
        let mb = 1800.0 - Double(rank) * 350.0
        let bytes = mb * 1_048_576.0
        return UInt64(max(0.0, bytes))
    }

    // MARK: - Channels

    private func toggleChannels() {
        httpAlive = true
        mcpAlive = (tick % 2 == 0)
        jsonlAlive = (tick % 3 != 0)
        // 0, 1, 2 cycling — with mcpAlive above this walks the pill through
        // off (mcp down) / configured (mcp up, 0) / connected(N) states.
        llmClientsConnected = tick % 3
    }

    // MARK: - Recent actions

    private let actionIDs = ["prune_apfs_snapshots", "clear_derived_data", "empty_trash", "flush_dns_cache"]

    private func refreshRecentActions() {
        let now = Date()
        var out: [AuditLog.Entry] = []
        for i in 0..<3 {
            let id = actionIDs[(tick + i) % actionIDs.count]
            let freed = UInt64((i + 1) * 256) * 1_048_576
            out.append(AuditLog.Entry(
                ts: now.addingTimeInterval(Double(-i) * 45.0),
                actionID: id,
                trigger: .auto,
                policyDecision: "allow",
                freedBytes: freed,
                beforeFreeBytes: 0,
                afterFreeBytes: freed,
                skipped: false,
                error: nil
            ))
        }
        recentActions = out
    }
}
