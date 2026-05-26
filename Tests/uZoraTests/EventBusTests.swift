import Testing
import Foundation
@testable import uZora

@Suite("EventBus subscribe/emit basics")
struct EventBusTests {

    private func alert(_ severity: Severity = .warn) -> Alert {
        Alert(
            probe: "disk",
            key: "/",
            severity: severity,
            message: "test",
            details: nil,
            firstSeen: Date(),
            lastUpdated: Date()
        )
    }

    @Test func emitsToSingleSubscriber() async {
        let bus = EventBus()
        actor Box { var n = 0; func bump() { n += 1 }; func get() -> Int { n } }
        let box = Box()
        await bus.subscribe { _ in
            Task { await box.bump() }
        }
        await bus.emit(.appeared(alert()))
        try? await Task.sleep(for: .milliseconds(50))
        let count = await box.get()
        #expect(count == 1)
    }

    @Test func emitsToMultipleSubscribers() async {
        let bus = EventBus()
        actor Box { var n = 0; func bump() { n += 1 }; func get() -> Int { n } }
        let box = Box()
        await bus.subscribe { _ in Task { await box.bump() } }
        await bus.subscribe { _ in Task { await box.bump() } }
        await bus.subscribe { _ in Task { await box.bump() } }
        await bus.emit(.appeared(alert()))
        try? await Task.sleep(for: .milliseconds(50))
        let count = await box.get()
        #expect(count == 3)
    }

    @Test func unsubscribe_stopsDelivery() async {
        let bus = EventBus()
        actor Box { var n = 0; func bump() { n += 1 }; func get() -> Int { n } }
        let box = Box()
        let token = await bus.subscribe { _ in Task { await box.bump() } }
        await bus.unsubscribe(token)
        await bus.emit(.appeared(alert()))
        try? await Task.sleep(for: .milliseconds(50))
        let count = await box.get()
        #expect(count == 0)
    }

    @Test func emitAll_deliversEachInOrder() async {
        let bus = EventBus()
        actor Recorder {
            var seen: [String] = []
            func push(_ s: String) { seen.append(s) }
            func all() -> [String] { seen }
        }
        let rec = Recorder()
        await bus.subscribe { ev in
            let label: String
            switch ev {
            case .appeared(let a): label = "appear-\(a.id)"
            case .escalated(let a, _): label = "escalate-\(a.id)"
            case .cleared(let id): label = "clear-\(id)"
            }
            Task { await rec.push(label) }
        }
        let a = alert(.warn)
        let b = alert(.critical)
        await bus.emitAll([.appeared(a), .escalated(b, previousSeverity: .warn), .cleared("disk:x")])
        try? await Task.sleep(for: .milliseconds(50))
        let seen = await rec.all()
        // Order should be preserved (serial emit).
        #expect(seen == ["appear-disk:/", "escalate-disk:/", "clear-disk:x"])
    }

    @Test func subscriberCount_reflectsSubscriptions() async {
        let bus = EventBus()
        let initial = await bus.subscriberCount
        #expect(initial == 0)
        let t1 = await bus.subscribe { _ in }
        let t2 = await bus.subscribe { _ in }
        let twoCount = await bus.subscriberCount
        #expect(twoCount == 2)
        await bus.unsubscribe(t1)
        let oneCount = await bus.subscriberCount
        #expect(oneCount == 1)
        await bus.unsubscribe(t2)
        let zeroCount = await bus.subscriberCount
        #expect(zeroCount == 0)
    }

    @Test func emittedCount_tracksTotal() async {
        let bus = EventBus()
        await bus.emit(.appeared(alert()))
        await bus.emit(.appeared(alert(.critical)))
        await bus.emit(.cleared("disk:/"))
        let n = await bus.emittedCount
        #expect(n == 3)
    }

    @Test func attachLoggerSink_doesNotCrash() async {
        let bus = EventBus()
        await bus.attachLoggerSink()
        await bus.emit(.appeared(alert()))
        await bus.emit(.escalated(alert(.critical), previousSeverity: .warn))
        await bus.emit(.cleared("disk:/"))
        let subs = await bus.subscriberCount
        #expect(subs == 1)
    }
}
