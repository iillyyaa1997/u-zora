import Testing
import Foundation
@testable import uZora

/// A mock local-exec backend that RECORDS the argv it receives (instead of
/// spawning `claude`) and returns a configurable outcome. Lets the producer's
/// argv-building + circuit-breaker be tested without a real process.
private actor MockExecRunner: PushExecRunning {
    private(set) var calls: [[String]] = []
    private let outcome: ActionShell.ProcessOutcome

    init(exitCode: Int32 = 0, launched: Bool = true) {
        self.outcome = ActionShell.ProcessOutcome(
            exitCode: exitCode, stdout: "", stderr: "", launched: launched
        )
    }

    func run(argv: [String], timeoutSeconds: Double) async -> ActionShell.ProcessOutcome {
        calls.append(argv)
        return outcome
    }

    func recordedCalls() -> [[String]] { calls }
    func callCount() -> Int { calls.count }
}

@Suite("ProactivePush — filter, coalesce, rate-limit, circuit-breaker, backends")
struct ProactivePushTests {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-push-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func alert(_ probe: String, _ key: String, severity: Severity, message: String = "m") -> Alert {
        Alert(probe: probe, key: key, severity: severity, message: message,
              details: nil, firstSeen: base, lastUpdated: base)
    }

    /// Read + decode the outbox lines from `dir`'s today-file for `base`.
    private func outboxLines(_ outbox: PushOutbox, dir: URL) async throws -> [PushOutbox.Line] {
        try await outbox.flush()
        let url = await outbox.todayFileURL(at: base)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").filter { !$0.isEmpty }.compactMap {
            try? dec.decode(PushOutbox.Line.self, from: Data($0.utf8))
        }
    }

    // MARK: - Filter

    @Test func filter_belowFloorDropped() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try PushAuditLog(baseDir: dir); let outbox = try PushOutbox(baseDir: dir)
        let cfg = PushConfig(enabled: true, severityFloor: .critical, kinds: ["alert"],
                             outboxEnabled: true)
        let p = ProactivePush(eventBus: EventBus(), diagnosisBus: DiagnosisEventBus(),
                              config: cfg, audit: audit, outbox: outbox, clock: { self.base })
        await p.handleWatchdog(.appeared(alert("disk", "/", severity: .warn)))

        #expect(try await outboxLines(outbox, dir: dir).isEmpty)
        let recent = await audit.recent(10)
        #expect(recent.count == 1)
        #expect(recent[0].outcome == "dropped")
        #expect(recent[0].reason == "below_floor")
        #expect(await p.rateWindowCount() == 0)  // below-floor never consumes budget
    }

    @Test func filter_wrongKindDropped() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try PushAuditLog(baseDir: dir); let outbox = try PushOutbox(baseDir: dir)
        let cfg = PushConfig(enabled: true, severityFloor: .info, kinds: ["verdict"],
                             outboxEnabled: true)
        let p = ProactivePush(eventBus: EventBus(), diagnosisBus: DiagnosisEventBus(),
                              config: cfg, audit: audit, outbox: outbox, clock: { self.base })
        await p.handleWatchdog(.appeared(alert("disk", "/", severity: .critical)))

        #expect(try await outboxLines(outbox, dir: dir).isEmpty)
        let recent = await audit.recent(10)
        #expect(recent.last?.outcome == "dropped")
        #expect(recent.last?.reason == "kind_off")
    }

    @Test func filter_clearedGatedByPushCleared() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // push_cleared OFF ⇒ cleared dropped.
        let auditOff = try PushAuditLog(baseDir: dir); let outboxOff = try PushOutbox(baseDir: dir)
        let cfgOff = PushConfig(enabled: true, severityFloor: .info, kinds: ["alert"],
                                pushCleared: false, outboxEnabled: true)
        let pOff = ProactivePush(eventBus: EventBus(), diagnosisBus: DiagnosisEventBus(),
                                 config: cfgOff, audit: auditOff, outbox: outboxOff, clock: { self.base })
        await pOff.handleWatchdog(.cleared("disk:/"))
        #expect(try await outboxLines(outboxOff, dir: dir).isEmpty)
        #expect(await auditOff.recent(5).last?.reason == "cleared_off")

        // push_cleared ON ⇒ cleared dispatched (skips the floor).
        let dir2 = tempDir(); defer { try? FileManager.default.removeItem(at: dir2) }
        let auditOn = try PushAuditLog(baseDir: dir2); let outboxOn = try PushOutbox(baseDir: dir2)
        let cfgOn = PushConfig(enabled: true, severityFloor: .critical, kinds: ["alert"],
                               pushCleared: true, outboxEnabled: true)
        let pOn = ProactivePush(eventBus: EventBus(), diagnosisBus: DiagnosisEventBus(),
                                config: cfgOn, audit: auditOn, outbox: outboxOn, clock: { self.base })
        await pOn.handleWatchdog(.cleared("disk:/"))
        let lines = try await outboxLines(outboxOn, dir: dir2)
        #expect(lines.count == 1)
        #expect(lines[0].cleared == true)
        #expect(lines[0].subject == "disk:/")
    }

    // MARK: - Coalesce

    @Test func coalesce_sameSubjectWithinCooldown_onePush() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try PushAuditLog(baseDir: dir); let outbox = try PushOutbox(baseDir: dir)
        let cfg = PushConfig(enabled: true, severityFloor: .critical, kinds: ["alert"],
                             coolDownSeconds: 60, outboxEnabled: true)
        let p = ProactivePush(eventBus: EventBus(), diagnosisBus: DiagnosisEventBus(),
                              config: cfg, audit: audit, outbox: outbox, clock: { self.base })
        // Two events, SAME subject, within the (fixed-clock) cool-down window.
        await p.handleWatchdog(.appeared(alert("disk", "/", severity: .critical)))
        await p.handleWatchdog(.escalated(alert("disk", "/", severity: .critical), previousSeverity: .warn))

        #expect(try await outboxLines(outbox, dir: dir).count == 1)  // only the first
        let recent = await audit.recent(10)
        #expect(recent.contains { $0.outcome == "coalesced" })
        #expect(recent.filter { $0.outcome == "sent" }.count == 1)
    }

    // MARK: - Rate-limit

    @Test func rateLimit_overCap_droppedAndAudited() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try PushAuditLog(baseDir: dir); let outbox = try PushOutbox(baseDir: dir)
        let cfg = PushConfig(enabled: true, severityFloor: .critical, kinds: ["alert"],
                             rateLimitPerHour: 2, outboxEnabled: true)
        let p = ProactivePush(eventBus: EventBus(), diagnosisBus: DiagnosisEventBus(),
                              config: cfg, audit: audit, outbox: outbox, clock: { self.base })
        // Three DISTINCT subjects (no coalescing) at a fixed instant.
        await p.handleWatchdog(.appeared(alert("disk", "/", severity: .critical)))
        await p.handleWatchdog(.appeared(alert("cpu_temp", "package", severity: .critical)))
        await p.handleWatchdog(.appeared(alert("smart", "disk0", severity: .critical)))

        #expect(try await outboxLines(outbox, dir: dir).count == 2)  // cap = 2
        let recent = await audit.recent(10)
        #expect(recent.last?.outcome == "dropped")
        #expect(recent.last?.reason == "rate_limit")
        #expect(await p.rateWindowCount() == 2)  // over-cap NOT queued
    }

    // MARK: - Circuit breaker

    @Test func circuitBreaker_tripsAfterConsecutiveFailures() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try PushAuditLog(baseDir: dir)
        let mock = MockExecRunner(exitCode: 1, launched: true)  // always fails
        let cfg = PushConfig(enabled: true, severityFloor: .critical, kinds: ["alert"],
                             rateLimitPerHour: 100, circuitBreakerThreshold: 2,
                             execEnabled: true, execArgv: ["claude", "-p"])
        let p = ProactivePush(eventBus: EventBus(), diagnosisBus: DiagnosisEventBus(),
                              config: cfg, audit: audit, outbox: nil,
                              execRunner: mock, clock: { self.base })

        // Two DISTINCT failing dispatches reach the threshold → circuit opens.
        await p.handleWatchdog(.appeared(alert("disk", "/", severity: .critical)))
        await p.handleWatchdog(.appeared(alert("cpu_temp", "package", severity: .critical)))
        #expect(await p.isCircuitOpen == true)
        #expect(await mock.callCount() == 2)

        // A third event is now DENIED without touching the backend.
        await p.handleWatchdog(.appeared(alert("smart", "disk0", severity: .critical)))
        #expect(await mock.callCount() == 2)  // backend NOT called again
        let recent = await audit.recent(20)
        #expect(recent.last?.outcome == "denied")
        #expect(recent.last?.reason == "circuit_open")
    }

    // MARK: - Backends

    @Test func outbox_writesJSONLineForPassingEvent() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try PushAuditLog(baseDir: dir); let outbox = try PushOutbox(baseDir: dir)
        let cfg = PushConfig(enabled: true, severityFloor: .critical, kinds: ["alert"],
                             outboxEnabled: true)
        let p = ProactivePush(eventBus: EventBus(), diagnosisBus: DiagnosisEventBus(),
                              config: cfg, audit: audit, outbox: outbox, clock: { self.base })
        await p.handleWatchdog(.appeared(alert("disk", "/", severity: .critical, message: "3% free")))

        // Raw file check for the schema tag.
        try await outbox.flush()
        let url = await outbox.todayFileURL(at: base)
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains("\"schema\":\"uzora.push.v1\""))

        let lines = try await outboxLines(outbox, dir: dir)
        #expect(lines.count == 1)
        #expect(lines[0].kind == "alert")
        #expect(lines[0].severity == "critical")
        #expect(lines[0].subject == "disk:/")
        #expect(lines[0].summary.contains("3% free"))
        #expect(await audit.recent(5).last?.outcome == "sent")
        #expect(await audit.recent(5).last?.backend == "outbox")
    }

    @Test func localExec_buildsFixedArgv_summaryIsSingleToken() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try PushAuditLog(baseDir: dir)
        let mock = MockExecRunner(exitCode: 0, launched: true)
        let cfg = PushConfig(enabled: true, severityFloor: .critical, kinds: ["alert"],
                             execEnabled: true, execArgv: ["claude", "-p"])
        let p = ProactivePush(eventBus: EventBus(), diagnosisBus: DiagnosisEventBus(),
                              config: cfg, audit: audit, outbox: nil,
                              execRunner: mock, clock: { self.base })
        // A message with shell metacharacters proves NO shell splitting: the
        // whole summary stays a SINGLE argv token.
        await p.handleWatchdog(.appeared(alert("disk", "/", severity: .critical, message: "full; rm -rf /")))

        let calls = await mock.recordedCalls()
        #expect(calls.count == 1)
        let expectedSummary = "[critical] disk:/ — full; rm -rf /"
        // argv == exec_argv + [summary], exactly.
        #expect(calls[0] == ["claude", "-p", expectedSummary])
        // The summary is ONE token (exec_argv.count + 1), not split on spaces/`;`.
        #expect(calls[0].count == cfg.execArgv.count + 1)
        #expect(calls[0].last == expectedSummary)
        #expect(await audit.recent(5).last?.backend == "exec")
    }

    // MARK: - Verdict mapping through the floor

    @Test func verdict_problemPushes_degradedBelowCriticalFloor() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try PushAuditLog(baseDir: dir); let outbox = try PushOutbox(baseDir: dir)
        let cfg = PushConfig(enabled: true, severityFloor: .critical, kinds: ["verdict"],
                             outboxEnabled: true)
        let p = ProactivePush(eventBus: EventBus(), diagnosisBus: DiagnosisEventBus(),
                              config: cfg, audit: audit, outbox: outbox, clock: { self.base })
        // problem → critical ⇒ passes the critical floor.
        await p.handleDiagnosis(.verdictChanged(from: .good, to: .problem, headline: "trouble"))
        // degraded → warn ⇒ below the critical floor, dropped.
        await p.handleDiagnosis(.verdictChanged(from: .problem, to: .degraded, headline: "better"))

        let lines = try await outboxLines(outbox, dir: dir)
        #expect(lines.count == 1)
        #expect(lines[0].kind == "verdict")
        #expect(lines[0].severity == "critical")
        #expect(await audit.recent(10).contains { $0.outcome == "dropped" && $0.reason == "below_floor" })
    }

    // MARK: - OFF by default + subscription lifecycle

    @Test func off_noSubscriptionsNoDispatch() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try PushAuditLog(baseDir: dir); let outbox = try PushOutbox(baseDir: dir)
        let eventBus = EventBus(); let diagBus = DiagnosisEventBus()
        let cfg = PushConfig(enabled: false, outboxEnabled: true)  // disabled
        let p = ProactivePush(eventBus: eventBus, diagnosisBus: diagBus,
                              config: cfg, audit: audit, outbox: outbox, clock: { self.base })
        // start() is a no-op while disabled — nothing subscribes.
        await p.start()
        #expect(await p.isStarted == false)
        #expect(await eventBus.subscriberCount == 0)
        #expect(await diagBus.subscriberCount == 0)

        // Even a directly-driven event dispatches nothing (process guards enabled).
        await p.handleWatchdog(.appeared(alert("disk", "/", severity: .critical)))
        #expect(try await outboxLines(outbox, dir: dir).isEmpty)
        #expect(await audit.recordedCount == 0)
    }

    @Test func start_subscribesToBothBuses_stopUnsubscribes() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try PushAuditLog(baseDir: dir)
        let eventBus = EventBus(); let diagBus = DiagnosisEventBus()
        let cfg = PushConfig(enabled: true, outboxEnabled: false, outboxPath: "")
        let p = ProactivePush(eventBus: eventBus, diagnosisBus: diagBus,
                              config: cfg, audit: audit, outbox: nil, clock: { self.base })
        await p.start()
        #expect(await p.isStarted == true)
        #expect(await eventBus.subscriberCount == 1)
        #expect(await diagBus.subscriberCount == 1)

        await p.stop()
        #expect(await p.isStarted == false)
        #expect(await eventBus.subscriberCount == 0)
        #expect(await diagBus.subscriberCount == 0)
    }

    @Test func reconfigure_enableStarts_disableStops() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try PushAuditLog(baseDir: dir)
        let eventBus = EventBus(); let diagBus = DiagnosisEventBus()
        let p = ProactivePush(eventBus: eventBus, diagnosisBus: diagBus,
                              config: PushConfig(enabled: false), audit: audit,
                              outbox: nil, clock: { self.base })
        #expect(await eventBus.subscriberCount == 0)

        await p.reconfigure(PushConfig(enabled: true))
        #expect(await p.isStarted == true)
        #expect(await eventBus.subscriberCount == 1)
        #expect(await diagBus.subscriberCount == 1)

        await p.reconfigure(PushConfig(enabled: false))
        #expect(await p.isStarted == false)
        #expect(await eventBus.subscriberCount == 0)
    }
}
