import Testing
import Foundation
@testable import uZora

/// Regression coverage for the "unvalidated numeric config → trap → crash-loop"
/// bug (P0 #2). One root cause, three trap sites:
///   - `Int(double.rounded())` traps for poll_interval_sec > Int.max (1e22).
///   - `PowerProfile.effectiveInterval` Int64 overflow on huge seconds.
///   - `UInt64(double.rounded())` traps on negative / >UInt64.max thresholds.
///
/// The fix adds a sanitize/clamp layer applied BOTH at the write boundary
/// (reject → 400 / MCP isError, don't persist) AND defensively at the
/// config-read boundary (clamp + log, never trap) so a hand-edited config
/// can't crash-loop the daemon on relaunch.
@Suite("Config numeric sanitization (no trap / no crash-loop)")
struct ConfigSanitizationTests {

    private func tempConfigURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-sanitize-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.toml")
    }

    // ========================================================================
    // MARK: - Write boundary: reject (400), do NOT persist
    // ========================================================================

    /// THE crash repro: POST /config/probe with poll_interval_sec = 1e22 must
    /// return 400 — NOT trap on `Int(1e22.rounded())`. Driven through the JSON
    /// dispatch path (the raw double survives to validation).
    @Test func write_pollInterval_1e22_returns400_notCrash() async throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        let rest = RESTHandlers(state: StateStore(), configLoader: loader)

        // Simulate the JSON dispatch path: a giant number arrives as a Double.
        let body = Data(#"{"probe":"disk","poll_interval_sec":1e22}"#.utf8)
        let req = HTTPRequest(method: "POST", path: "/config/probe", query: [:], headers: [:], body: body)
        let resp = await rest.dispatch(req)
        #expect(resp.status == 400)
        // Nothing was persisted — disk override keeps its default poll (nil).
        let reloaded = try await loader.reload()
        #expect(reloaded.probes.disk.pollIntervalSec == nil)
    }

    /// poll_interval_sec = 0 (below the 1 s floor) is rejected.
    @Test func write_pollInterval_zero_returns400() async throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        let rest = RESTHandlers(state: StateStore(), configLoader: loader)
        let resp = await rest.reconfigureProbe(name: "disk", patch: .init(pollIntervalSec: 0))
        #expect(resp.status == 400)
    }

    /// poll_interval_sec beyond 24 h (86400) is rejected.
    @Test func write_pollInterval_above24h_returns400() async throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        let rest = RESTHandlers(state: StateStore(), configLoader: loader)
        let resp = await rest.reconfigureProbe(name: "disk", patch: .init(pollIntervalSec: 86_401))
        #expect(resp.status == 400)
    }

    /// THE second repro: top_mem warn_threshold = -1 (negative GiB) must be
    /// rejected at the write boundary with 400 — never reaching the trapping
    /// `UInt64((-1 …).rounded())`.
    @Test func write_topMem_negativeThreshold_returns400_notCrash() async throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        let rest = RESTHandlers(state: StateStore(), configLoader: loader)
        let resp = await rest.reconfigureProbe(name: "top_mem", patch: .init(warnThreshold: -1))
        #expect(resp.status == 400)
        // Not persisted.
        let reloaded = try await loader.reload()
        #expect(reloaded.probes.topMem.warnThreshold == nil)
    }

    /// A cpu_temp threshold beyond the 0…150 °C bound is rejected.
    @Test func write_cpuTemp_thresholdAbove150_returns400() async throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        let rest = RESTHandlers(state: StateStore(), configLoader: loader)
        let resp = await rest.reconfigureProbe(name: "cpu_temp", patch: .init(criticalThreshold: 999))
        #expect(resp.status == 400)
    }

    /// A non-finite threshold (NaN via the patch) is rejected.
    @Test func write_disk_nanThreshold_returns400() async throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        let rest = RESTHandlers(state: StateStore(), configLoader: loader)
        let resp = await rest.reconfigureProbe(name: "disk", patch: .init(warnThreshold: Double.nan))
        #expect(resp.status == 400)
    }

    /// A valid in-range value still succeeds (sanitizer doesn't over-reject).
    @Test func write_validValues_succeed() async throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        let rest = RESTHandlers(state: StateStore(), configLoader: loader)
        let resp = await rest.reconfigureProbe(name: "disk", patch: .init(warnThreshold: 20, criticalThreshold: 5, pollIntervalSec: 30))
        #expect(resp.status == 200)
        let reloaded = try await loader.reload()
        #expect(reloaded.probes.disk.warnThreshold == 20)
        #expect(reloaded.probes.disk.pollIntervalSec == 30)
    }

    /// MCP write path also rejects the absurd value as an isError result (the
    /// raw double survives the MCP arg parse to validation — no trap).
    @Test func mcp_pollInterval_1e22_isError_notCrash() async throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        let rest = RESTHandlers(state: StateStore(), configLoader: loader)
        let mcp = MCPTools(rest: rest, httpBaseURL: "http://127.0.0.1:0")
        let args = JSONValue.object([
            "probe": .string("disk"),
            "poll_interval_sec": .double(1e22),
        ])
        let result = try await mcp.invoke(name: "uzora_set_probe_config", arguments: args)
        guard case .object(let obj) = result, case .bool(let isError)? = obj["isError"] else {
            Issue.record("expected an object result with isError")
            return
        }
        #expect(isError == true) // 400 → isError, not a crash
    }

    // ========================================================================
    // MARK: - Read boundary: clamp / skip, NEVER trap (hand-edited config)
    // ========================================================================

    /// THE third repro path: a hand-edited config.toml with
    /// poll_interval_sec = 1e10 (≈317 years, overflows the Duration math)
    /// must NOT trap. `PowerProfile.effectiveInterval` is saturating and the
    /// read boundary clamps the override — the registry builds + the effective
    /// interval is a finite Duration.
    @Test func read_handEditedHugePollInterval_clampedNotTrapped() async {
        var cfg = UZoraConfig.default
        cfg.probes.disk.pollIntervalSec = 1_000_000_000_0 // 1e10
        // Building the registry from this config must not trap.
        let registry = await ProbeRegistry.defaultPopulated(config: cfg)
        // Effective interval is finite + clamped to the 24h read ceiling.
        let eff = await registry.effectiveInterval(forProbeNamed: "disk")
        let secs = eff?.components.seconds ?? -1
        #expect(secs == 86_400) // clamped to 24h ceiling
    }

    /// `effectiveInterval` directly: an absurd base Duration saturates instead
    /// of trapping `Int64(scaled)`. seconds = 1e10 with a 3× multiplier.
    @Test func effectiveInterval_absurdBase_saturatesNotTraps() {
        let p = PowerProfile.defaultMapping(for: .batteryLidOpen) // 3× multiplier
        let huge = Duration.seconds(10_000_000_000) // 1e10 s
        let interval = p.effectiveInterval(huge)
        // Must be a finite, representable Duration (no trap reaching here).
        let nanos = interval.components.seconds
        #expect(nanos > 0)
    }

    /// Even the most extreme base can't trap effectiveInterval.
    @Test func effectiveInterval_intMaxSeconds_saturatesNotTraps() {
        let p = PowerProfile.defaultMapping(for: .batteryLidClosed) // 6× multiplier
        let interval = p.effectiveInterval(.seconds(Int64.max / 2))
        #expect(interval.components.seconds > 0)
    }

    /// THE gibToBytes guard: a negative GiB returns 0 (or skips), never traps
    /// on `UInt64(negative.rounded())`.
    @Test func gibToBytes_negative_returnsZero_notTrap() {
        #expect(ProbeRegistry.gibToBytes(-1) == 0)
        #expect(ProbeRegistry.gibToBytes(-1e9) == 0)
    }

    /// gibToBytes guards NaN / ∞ → 0.
    @Test func gibToBytes_nonFinite_returnsZero() {
        #expect(ProbeRegistry.gibToBytes(.nan) == 0)
        #expect(ProbeRegistry.gibToBytes(.infinity) == 0)
    }

    /// gibToBytes saturates at UInt64.max for an enormous value (no overflow
    /// trap on the UInt64 conversion).
    @Test func gibToBytes_enormous_saturatesNotTrap() {
        #expect(ProbeRegistry.gibToBytes(1e30) == UInt64.max)
    }

    /// A normal value converts correctly.
    @Test func gibToBytes_normal() {
        #expect(ProbeRegistry.gibToBytes(4) == 4 * 1024 * 1024 * 1024)
    }

    @Test func mibToBytes_negative_returnsZero_notTrap() {
        #expect(ProbeRegistry.mibToBytes(-5) == 0)
    }

    /// A hand-edited negative top_mem threshold at the READ boundary doesn't
    /// trap the registry build (clamped to 0 → gibToBytes(0) = 0).
    @Test func read_handEditedNegativeTopMem_clampedNotTrapped() async throws {
        var cfg = UZoraConfig.default
        cfg.probes.topMem.warnThreshold = -1
        let registry = await ProbeRegistry.defaultPopulated(config: cfg)
        let probe = await registry.registeredProbe(named: "top_mem") as? TopMemoryProcessProbe
        let t = try #require(probe?.configuredThresholds)
        // -1 GiB clamped to 0 → 0 bytes (no trap).
        #expect(t.warnRssBytes == 0)
    }

    // ========================================================================
    // MARK: - ConfigSanitizer unit-level
    // ========================================================================

    @Test func sanitizer_validatedPollInterval_rejectsAbsurd() {
        if case .failure = ConfigSanitizer.validatedPollInterval(fromDouble: 1e22) {} else {
            Issue.record("1e22 must fail validation")
        }
        if case .success(let s) = ConfigSanitizer.validatedPollInterval(fromDouble: 60) {
            #expect(s == 60)
        } else {
            Issue.record("60 must pass validation")
        }
    }

    @Test func sanitizer_clampThreshold_coercesRange() {
        #expect(ConfigSanitizer.clampThreshold(-5, unit: .percent) == 0)
        #expect(ConfigSanitizer.clampThreshold(200, unit: .percent) == 100)
        #expect(ConfigSanitizer.clampThreshold(50, unit: .percent) == 50)
        // Non-finite → nil (skip, keep default).
        #expect(ConfigSanitizer.clampThreshold(.nan, unit: .percent) == nil)
    }

    @Test func sanitizer_clampPollIntervalSec_coercesRange() {
        #expect(ConfigSanitizer.clampPollIntervalSec(0) == 1)
        #expect(ConfigSanitizer.clampPollIntervalSec(99_999) == 86_400)
        #expect(ConfigSanitizer.clampPollIntervalSec(60) == 60)
    }
}
