import Testing
import Foundation
@testable import uZora

/// B1a (plan D-C4) — read-only `GET /layout` + MCP `uzora_get_layout`.
/// Asserts the resolved effective popover layout (blocks + tiles with
/// visibility/order) is returned for: the nil-config default, a named preset,
/// and a customized layoutJSON fork. Read tier — no auth change, no mutation.
@Suite("GET /layout + uzora_get_layout (read-only)")
struct LayoutEndpointTests {

    private func json(_ resp: HTTPResponse) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
    }

    private func entry(_ arr: [[String: Any]]?, kind: String) -> [String: Any]? {
        arr?.first { $0["kind"] as? String == kind }
    }

    private func tempConfigURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-layout-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    // MARK: - nil config → default preset

    @Test func layout_nilConfig_returnsDefaultPresetWithNote() async {
        let rest = RESTHandlers(state: StateStore())   // no configLoader
        let resp = await rest.layout()
        #expect(resp.status == 200)
        let body = json(resp)
        #expect(body?["preset"] as? String == PresetName.default.rawValue)   // "minimal"
        #expect(body?["source"] as? String == "preset")
        #expect((body?["note"] as? String)?.contains("not wired") == true)

        let blocks = body?["blocks"] as? [[String: Any]]
        #expect(entry(blocks, kind: "verdict")?["visible"] as? Bool == true)
        #expect(entry(blocks, kind: "recentActions")?["visible"] as? Bool == false)

        let tiles = body?["tiles"] as? [[String: Any]]
        #expect(entry(tiles, kind: "memPressureLevel")?["visible"] as? Bool == true)
        #expect(entry(tiles, kind: "battery")?["visible"] as? Bool == false)
    }

    // MARK: - named preset via ConfigLoader

    @Test func layout_namedPreset_power() async throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        var cfg = await loader.current
        cfg.ui.popover.preset = PresetName.power.rawValue
        try await loader.write(cfg)

        let rest = RESTHandlers(state: StateStore(), configLoader: loader)
        let resp = await rest.layout()
        #expect(resp.status == 200)
        let body = json(resp)
        #expect(body?["preset"] as? String == "power")
        #expect(body?["source"] as? String == "preset")
        #expect(body?["note"] == nil)   // config wired → no degradation note

        let blocks = body?["blocks"] as? [[String: Any]]
        // `power` preset shows every original block.
        #expect(entry(blocks, kind: "topProcesses")?["visible"] as? Bool == true)
        #expect(entry(blocks, kind: "recentActions")?["visible"] as? Bool == true)
    }

    // MARK: - customized layoutJSON → source "custom"

    @Test func layout_customLayoutJSON_reportsCustomSource() async throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        var cfg = await loader.current
        // Fork the preset with a valid customized layout (the `diagnosis` shape).
        cfg.ui.popover.layoutJSON = PopoverLayout.diagnosis.toJSONString()
        try await loader.write(cfg)

        let rest = RESTHandlers(state: StateStore(), configLoader: loader)
        let resp = await rest.layout()
        let body = json(resp)
        #expect(body?["source"] as? String == "custom")
        let blocks = body?["blocks"] as? [[String: Any]]
        // diagnosis layout: topProcesses visible, recentActions hidden.
        #expect(entry(blocks, kind: "topProcesses")?["visible"] as? Bool == true)
        #expect(entry(blocks, kind: "recentActions")?["visible"] as? Bool == false)
    }

    // MARK: - dispatch route

    @Test func layout_dispatchRoute() async {
        let rest = RESTHandlers(state: StateStore())
        let req = HTTPRequest(method: "GET", path: "/layout", query: [:], headers: [:], body: Data())
        let resp = await rest.dispatch(req)
        #expect(resp.status == 200)
        #expect(json(resp)?["preset"] != nil)
    }

    // MARK: - MCP uzora_get_layout

    @Test func mcpGetLayout_wrapsEffectiveLayout() async throws {
        let rest = RESTHandlers(state: StateStore())
        let tools = MCPTools(rest: rest, httpBaseURL: "http://127.0.0.1:0")
        let result = try await tools.invoke(name: "uzora_get_layout", arguments: .object([:]))
        guard case .object(let obj) = result,
              case .object(let sc)? = obj["structuredContent"] else {
            Issue.record("structuredContent missing"); return
        }
        if case .string(let preset)? = sc["preset"] {
            #expect(preset == PresetName.default.rawValue)
        } else {
            Issue.record("preset missing")
        }
        guard case .array(let blocks)? = sc["blocks"] else {
            Issue.record("blocks missing"); return
        }
        #expect(!blocks.isEmpty)
        #expect(obj["isError"] == .bool(false))
    }

    @Test func mcpGetLayout_inSchemas() {
        let names = Set(MCPTools.readSchemas.compactMap { s -> String? in
            if case .string(let n)? = s["name"] { return n }
            return nil
        })
        #expect(names.contains("uzora_get_layout"))
    }
}
