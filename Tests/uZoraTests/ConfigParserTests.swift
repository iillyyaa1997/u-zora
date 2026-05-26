import Testing
import Foundation
@testable import uZora

@Suite("TOML parser + UZoraConfig round-trip")
struct ConfigParserTests {

    @Test func parse_topLevelScalars() throws {
        let toml = """
        # comment
        name = "uZora"
        port = 39842
        enabled = true
        threshold = 0.85
        """
        let p = TOMLParser()
        let root = try p.parse(toml)
        #expect(root.value(forKey: "name")?.asString == "uZora")
        #expect(root.value(forKey: "port")?.asInt == 39842)
        #expect(root.value(forKey: "enabled")?.asBool == true)
        #expect(root.value(forKey: "threshold")?.asDouble == 0.85)
    }

    @Test func parse_nestedTables() throws {
        let toml = """
        [general]
        language = "en"
        [http]
        port = 8080
        enabled = false
        """
        let p = TOMLParser()
        let root = try p.parse(toml)
        let general = root.value(forKey: "general")
        let http = root.value(forKey: "http")
        #expect(general?.value(forKey: "language")?.asString == "en")
        #expect(http?.value(forKey: "port")?.asInt == 8080)
        #expect(http?.value(forKey: "enabled")?.asBool == false)
    }

    @Test func parse_dottedTableHeader() throws {
        let toml = """
        [probes.disk]
        enabled = true
        warn_threshold = 15.0
        """
        let p = TOMLParser()
        let root = try p.parse(toml)
        let disk = root.value(forKey: "probes")?.value(forKey: "disk")
        #expect(disk?.value(forKey: "enabled")?.asBool == true)
        #expect(disk?.value(forKey: "warn_threshold")?.asDouble == 15.0)
    }

    @Test func parse_arrayOfStrings() throws {
        let toml = """
        languages = ["en", "ru", "ja"]
        """
        let p = TOMLParser()
        let root = try p.parse(toml)
        let arr = root.value(forKey: "languages")?.asArray
        #expect(arr?.count == 3)
        #expect(arr?[0].asString == "en")
        #expect(arr?[1].asString == "ru")
        #expect(arr?[2].asString == "ja")
    }

    @Test func parse_arrayOfMixedTypes() throws {
        let toml = """
        mixed = [1, 2.5, "three", true]
        """
        let p = TOMLParser()
        let root = try p.parse(toml)
        let arr = root.value(forKey: "mixed")?.asArray
        #expect(arr?.count == 4)
        #expect(arr?[0].asInt == 1)
        #expect(arr?[1].asDouble == 2.5)
        #expect(arr?[2].asString == "three")
        #expect(arr?[3].asBool == true)
    }

    @Test func parse_multilineArray() throws {
        let toml = """
        items = [
            "a",
            "b",
            "c"
        ]
        port = 9999
        """
        let p = TOMLParser()
        let root = try p.parse(toml)
        let arr = root.value(forKey: "items")?.asArray
        #expect(arr?.count == 3)
        #expect(arr?[0].asString == "a")
        #expect(arr?[2].asString == "c")
        #expect(root.value(forKey: "port")?.asInt == 9999)
    }

    @Test func parse_stringEscapes() throws {
        let toml = """
        path = "C:\\\\Users\\\\me"
        line = "a\\nb"
        quoted = "say \\"hi\\""
        """
        let p = TOMLParser()
        let root = try p.parse(toml)
        #expect(root.value(forKey: "path")?.asString == "C:\\Users\\me")
        #expect(root.value(forKey: "line")?.asString == "a\nb")
        #expect(root.value(forKey: "quoted")?.asString == "say \"hi\"")
    }

    @Test func parse_inlineComments() throws {
        let toml = """
        port = 39842   # default
        # whole line
        name = "uZora" # inline
        """
        let p = TOMLParser()
        let root = try p.parse(toml)
        #expect(root.value(forKey: "port")?.asInt == 39842)
        #expect(root.value(forKey: "name")?.asString == "uZora")
    }

    @Test func parse_rejectsMalformed() {
        let p = TOMLParser()
        // Missing '='
        #expect(throws: TOMLParseError.self) {
            try p.parse("port 8080")
        }
        // Unterminated string
        #expect(throws: TOMLParseError.self) {
            try p.parse("name = \"oops")
        }
        // Empty value
        #expect(throws: TOMLParseError.self) {
            try p.parse("k =")
        }
    }

    @Test func roundTrip_uZoraConfig_defaults() throws {
        let cfg = UZoraConfig.default
        let toml = cfg.toTOML()
        let decoded = try UZoraConfig.fromTOML(toml)
        #expect(decoded == cfg)
    }

    @Test func roundTrip_uZoraConfig_customized() throws {
        var cfg = UZoraConfig.default
        cfg.general.startAtLogin = true
        cfg.general.language = "ru"
        cfg.general.theme = "dark"
        cfg.http.port = 51234
        cfg.mcp.enabled = false
        cfg.notifications.bannerSeverityFloor = .critical
        cfg.notifications.respectFocus = false
        cfg.probes.disk.enabled = false
        cfg.probes.disk.warnThreshold = 25.0
        cfg.probes.disk.criticalThreshold = 10.0
        cfg.probes.disk.pollIntervalSec = 120
        let toml = cfg.toTOML()
        let decoded = try UZoraConfig.fromTOML(toml)
        #expect(decoded == cfg)
    }

    @Test func decodeIgnoresUnknownKeys() throws {
        let toml = """
        [general]
        start_at_login = true
        unknown_field = "ignored"
        another_unknown = 42

        [http]
        port = 8080

        [made_up_section]
        weird = true
        """
        let cfg = try UZoraConfig.fromTOML(toml)
        #expect(cfg.general.startAtLogin == true)
        #expect(cfg.http.port == 8080)
        // Unknown keys silently dropped; defaults preserved for declared fields.
        #expect(cfg.mcp.enabled == true)
    }

    @Test func decodeRejectsMalformed_butFallsBackOnIndividualFields() throws {
        // A field of the wrong type silently falls back to default rather
        // than throwing — keeps the agent alive on minor corruption.
        let toml = """
        [http]
        port = "not-a-number"
        enabled = "not-a-bool"
        """
        let cfg = try UZoraConfig.fromTOML(toml)
        // Field types didn't match — defaults kept.
        #expect(cfg.http.port == 39842)
        #expect(cfg.http.enabled == true)
    }

    @Test func emit_sampleResource_validates() throws {
        // Sample config in /Resources is parseable into the default struct.
        let sampleURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Tests/uZoraTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // <repo>
            .appendingPathComponent("Resources/sample-config.toml")
        let text = try String(contentsOf: sampleURL, encoding: .utf8)
        let cfg = try UZoraConfig.fromTOML(text)
        #expect(cfg.general.startAtLogin == false)
        #expect(cfg.http.port == 39842)
        #expect(cfg.mcp.enabled == true)
        #expect(cfg.notifications.bannerSeverityFloor == .warn)
        #expect(cfg.probes.disk.enabled == true)
    }
}
