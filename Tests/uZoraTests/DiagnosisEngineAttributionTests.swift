import Foundation
import Testing
@testable import uZora

@Suite("DiagnosisEngine — gated attribution + probe-union")
struct DiagnosisEngineAttributionTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// A counter that records how many times the injected `attribution`
    /// closure was invoked, returning a fixed payload.
    private final class AttributionCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        let payload: [AttributedProcess]?
        init(payload: [AttributedProcess]?) { self.payload = payload }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func call() -> [AttributedProcess]? {
            lock.lock(); _count += 1; lock.unlock()
            return payload
        }
    }

    /// A detector that asks for attribution when the latest `cores_pinned`
    /// is >= 2, and records what `attributedProcesses` it saw in `evaluate`.
    private struct WantsAttrDetector: Detector {
        let id = "wants_attr"
        let requiredProbes: Set<String> = ["system_signals"]
        func wantsAttribution(_ context: DiagnosisContext) -> Bool {
            (context.latest(probe: "system_signals", name: "cores_pinned")?.value ?? 0) >= 2
        }
        func evaluate(_ context: DiagnosisContext) -> Finding? {
            // Fire only when attribution was actually delivered.
            guard let procs = context.attributedProcesses, let first = procs.first else { return nil }
            return Finding(
                detector: id, subject: first.command, severity: .warn, confidence: .high,
                title: "attr", explanation: "got \(procs.count) procs",
                firstSeen: context.now, lastUpdated: context.now
            )
        }
    }

    private func proc(_ name: String) -> AttributedProcess {
        AttributedProcess(pid: 1, uid: 0, command: name,
                          path: "/System/Library/CoreServices/\(name)",
                          cpuSeconds: 1, isSystem: true)
    }

    private func s(_ probe: String, _ name: String, _ value: Double, key: String, _ at: Date) -> MetricsStore.Sample {
        MetricsStore.Sample(probe: probe, key: key, name: name, value: value, at: at)
    }

    // MARK: - Attribution is called ONLY when a detector wants it

    @Test func attribution_calledWhenDetectorWantsIt() async throws {
        let store = try MetricsStore(inMemory: true)
        try await store.recordSamples([
            s("system_signals", "cores_pinned", 3, key: "system", now.addingTimeInterval(-10)),
        ])
        let counter = AttributionCounter(payload: [proc("ecosystemd")])
        let engine = DiagnosisEngine(
            detectors: [WantsAttrDetector()],
            store: store,
            probes: ["system_signals"],
            clock: { self.now },
            attribution: { counter.call() }
        )
        let findings = await engine.diagnose()
        #expect(counter.count == 1, "attribution must be called exactly once")
        #expect(findings.first?.subject == "ecosystemd")
        await store.close()
    }

    @Test func attribution_notCalledWhenNoDetectorWantsIt() async throws {
        let store = try MetricsStore(inMemory: true)
        // cores_pinned = 1 → WantsAttrDetector.wantsAttribution is false.
        try await store.recordSamples([
            s("system_signals", "cores_pinned", 1, key: "system", now.addingTimeInterval(-10)),
        ])
        let counter = AttributionCounter(payload: [proc("ecosystemd")])
        let engine = DiagnosisEngine(
            detectors: [WantsAttrDetector()],
            store: store,
            probes: ["system_signals"],
            clock: { self.now },
            attribution: { counter.call() }
        )
        let findings = await engine.diagnose()
        #expect(counter.count == 0, "attribution must NOT be called when no detector wants it")
        #expect(findings.isEmpty)
        await store.close()
    }

    @Test func attribution_calledOnlyOnceAcrossMultipleWanters() async throws {
        let store = try MetricsStore(inMemory: true)
        try await store.recordSamples([
            s("system_signals", "cores_pinned", 5, key: "system", now.addingTimeInterval(-10)),
        ])
        let counter = AttributionCounter(payload: [proc("ecosystemd")])
        let engine = DiagnosisEngine(
            detectors: [WantsAttrDetector(), WantsAttrDetector()],
            store: store,
            probes: ["system_signals"],
            clock: { self.now },
            attribution: { counter.call() }
        )
        _ = await engine.diagnose()
        #expect(counter.count == 1, "attribution is called once per cycle, not per wanting detector")
        await store.close()
    }

    // MARK: - requiredProbes union (disk pulled in automatically)

    @Test func diagnose_unionsRequiredProbes_diskAndMemoryFindings() async throws {
        let store = try MetricsStore(inMemory: true)
        // Seed BOTH disk (free_pct <= 10) AND system_signals (mem level 2),
        // but construct the engine with the DEFAULT base probes only — the
        // detectors' requiredProbes must pull in "disk" automatically.
        try await store.recordSamples([
            s("disk", "free_pct", 5, key: "/", now.addingTimeInterval(-10)),
            s("disk", "free_bytes", 1_000_000, key: "/", now.addingTimeInterval(-10)),
            s("disk", "total_bytes", 100_000_000, key: "/", now.addingTimeInterval(-10)),
            s("system_signals", "mem_pressure_level", 2, key: "system", now.addingTimeInterval(-10)),
        ])
        // Note: base `probes` defaults to ["system_signals"] — "disk" is NOT
        // listed; it is only reachable via DiskHardCriticalDetector.requiredProbes.
        let engine = DiagnosisEngine(
            detectors: [DiskHardCriticalDetector(), MemoryPressureVerdictDetector()],
            store: store,
            clock: { self.now }
        )
        let findings = await engine.diagnose()
        // Both fire, sorted by id: "disk_hard_critical:/" < "memory_pressure:memory".
        #expect(findings.map(\.id) == ["disk_hard_critical:/", "memory_pressure:memory"])
        #expect(findings.first?.severity == .critical)
        #expect(findings.last?.severity == .critical)
        await store.close()
    }

    @Test func diagnose_v1Detectors_runawayUnnamedWhenSustainedButNoStore() async throws {
        // Smoke that the v1Detectors() factory wires the runaway detector into
        // a real engine and the gated attribution path works end-to-end with a
        // sustained pin + an injected attribution returning a named culprit.
        let store = try MetricsStore(inMemory: true)
        var rows: [MetricsStore.Sample] = []
        for i in 0..<12 {
            rows.append(s("system_signals", "cores_pinned", 3, key: "system",
                          now.addingTimeInterval(-Double((12 - i) * 5))))
        }
        try await store.recordSamples(rows)
        let eco = AttributedProcess(
            pid: 13579, uid: 0, command: "ecosystemd",
            path: "/System/Library/PrivateFrameworks/Ecosystem.framework/Support/ecosystemd",
            cpuSeconds: 200_000, isSystem: true
        )
        let engine = DiagnosisEngine(
            detectors: DiagnosisEngine.v1Detectors(),
            store: store,
            clock: { self.now },
            attribution: { [eco] }
        )
        let findings = await engine.diagnose()
        let runaway = findings.first { $0.detector == "runaway_daemon" }
        #expect(runaway?.subject == "ecosystemd")
        #expect(runaway?.severity == .critical)
        await store.close()
    }
}
