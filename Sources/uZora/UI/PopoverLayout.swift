import Foundation

/// The System-overview tiles that exist today (A3a). A4 will add more opt-in
/// tiles; the enum is intentionally extensible and the JSON codec below
/// tolerates an unknown tile name so a config written by a newer app doesn't
/// crash an older one — the unknown entry is simply dropped on decode.
///
/// `cpuTemp` / `diskFree` / `battery` are sparkline `MetricTile`s;
/// `memPressureLevel` is the mem-pressure LEVEL indicator (D6) — the CORRECT
/// default memory signal (not used%).
enum TileKind: String, CaseIterable, Codable, Hashable, Sendable {
    case cpuTemp
    case diskFree
    case battery
    case memPressureLevel
}

/// One top-level content block + its visibility. `kind` is always a KNOWN
/// `WidgetKind` — an unrecognized block name is dropped during
/// `PopoverLayout` decode (see `init(from:)`), so render never has to guard an
/// unknown case.
struct BlockConfig: Codable, Equatable, Sendable {
    var kind: WidgetKind
    var visible: Bool

    init(kind: WidgetKind, visible: Bool) {
        self.kind = kind
        self.visible = visible
    }
}

/// One System-overview tile + its visibility/order. Same known-only contract
/// as `BlockConfig` — an unrecognized tile name is dropped on decode.
struct TileConfig: Codable, Equatable, Sendable {
    var kind: TileKind
    var visible: Bool

    init(kind: TileKind, visible: Bool) {
        self.kind = kind
        self.visible = visible
    }
}

/// The persisted, preset-based popover layout (plan D3, D7, D-C1, D-C3.ii).
///
/// `blocks` is the ordered top-level content set (reorderable + show/hide);
/// `tiles` is the ordered System-overview tile set (individually show/hide).
/// Because the hand-rolled `TOMLParser` cannot represent arrays-of-tables,
/// the customized layout is stored in config as a single compact JSON STRING
/// (`toJSONString()` / `init?(jsonString:)`, D-C3.ii).
///
/// **Forward-compat (D-C3.ii):** decoding tolerates an unknown `WidgetKind` /
/// `TileKind` raw string — the unrecognized entry is DROPPED (known entries
/// are preserved in order), so a layout authored by a newer build never
/// crashes an older one.
struct PopoverLayout: Codable, Equatable, Sendable {
    var blocks: [BlockConfig]
    var tiles: [TileConfig]

    init(blocks: [BlockConfig], tiles: [TileConfig]) {
        self.blocks = blocks
        self.tiles = tiles
    }

    enum CodingKeys: String, CodingKey {
        case blocks
        case tiles
    }

    /// A minimal `{kind, visible}` shape used only to decode leniently: each
    /// entry's `kind` is read as a raw String and mapped to the typed enum,
    /// dropping (not throwing on) an unrecognized value.
    private struct RawEntry: Decodable {
        var kind: String
        var visible: Bool
    }

    /// Lenient decode: unknown block/tile kinds are dropped, known entries
    /// preserved in their JSON order. Never throws on an unknown kind.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawBlocks = (try? c.decode([RawEntry].self, forKey: .blocks)) ?? []
        let rawTiles = (try? c.decode([RawEntry].self, forKey: .tiles)) ?? []
        self.blocks = rawBlocks.compactMap { r in
            WidgetKind(rawValue: r.kind).map { BlockConfig(kind: $0, visible: r.visible) }
        }
        self.tiles = rawTiles.compactMap { r in
            TileKind(rawValue: r.kind).map { TileConfig(kind: $0, visible: r.visible) }
        }
    }

    // `encode(to:)` is synthesized from `CodingKeys` (blocks + tiles), each
    // element encoded via `BlockConfig` / `TileConfig`'s own synthesized
    // Codable → `{"kind":"…","visible":…}`.

    /// Compact JSON with a stable (sorted) key order. Never realistically
    /// fails for these value types; degrades to `"{}"` on the impossible
    /// encode error so callers always get a string.
    func toJSONString() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(self),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    /// Parse a `PopoverLayout` from a JSON string. Returns nil for malformed
    /// JSON (the caller falls back to a preset). A well-formed layout with
    /// only-unknown kinds decodes to an empty layout rather than nil.
    init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(PopoverLayout.self, from: data) else {
            return nil
        }
        self = decoded
    }
}

// MARK: - Presets (plan D7 + D-C1)

extension PopoverLayout {
    /// Canonical System-overview tile order shared by every preset: the
    /// mem-pressure LEVEL leads (D6 — the correct default memory signal),
    /// then CPU temp, disk free, battery. Presets differ only in which of
    /// these are visible.
    private static func tiles(
        memPressure: Bool, cpuTemp: Bool, diskFree: Bool, battery: Bool
    ) -> [TileConfig] {
        [
            TileConfig(kind: .memPressureLevel, visible: memPressure),
            TileConfig(kind: .cpuTemp, visible: cpuTemp),
            TileConfig(kind: .diskFree, visible: diskFree),
            TileConfig(kind: .battery, visible: battery),
        ]
    }

    private static func blocks(
        verdict: Bool, attention: Bool, systemOverview: Bool,
        topProcesses: Bool, recentActions: Bool
    ) -> [BlockConfig] {
        [
            BlockConfig(kind: .verdict, visible: verdict),
            BlockConfig(kind: .attention, visible: attention),
            BlockConfig(kind: .systemOverview, visible: systemOverview),
            BlockConfig(kind: .topProcesses, visible: topProcesses),
            BlockConfig(kind: .recentActions, visible: recentActions),
        ]
    }

    /// The out-of-the-box default (D-C1): verdict + attention + a lean
    /// system-overview (mem-pressure / CPU / disk; battery hidden). Top
    /// processes and recent actions are hidden until the user opts in.
    static let minimal = PopoverLayout(
        blocks: blocks(
            verdict: true, attention: true, systemOverview: true,
            topProcesses: false, recentActions: false
        ),
        tiles: tiles(memPressure: true, cpuTemp: true, diskFree: true, battery: false)
    )

    /// ≈ today (minus the A2 double-findings redundancy): every block and
    /// every tile visible.
    static let balanced = PopoverLayout(
        blocks: blocks(
            verdict: true, attention: true, systemOverview: true,
            topProcesses: true, recentActions: true
        ),
        tiles: tiles(memPressure: true, cpuTemp: true, diskFree: true, battery: true)
    )

    /// Findings-forward: verdict + attention + system-overview
    /// (mem-pressure + CPU only) + top processes; recent actions hidden.
    static let diagnosis = PopoverLayout(
        blocks: blocks(
            verdict: true, attention: true, systemOverview: true,
            topProcesses: true, recentActions: false
        ),
        tiles: tiles(memPressure: true, cpuTemp: true, diskFree: false, battery: false)
    )

    /// Everything on.
    static let power = PopoverLayout(
        blocks: blocks(
            verdict: true, attention: true, systemOverview: true,
            topProcesses: true, recentActions: true
        ),
        tiles: tiles(memPressure: true, cpuTemp: true, diskFree: true, battery: true)
    )

    /// Name → preset lookup used by the config resolver. `minimal` is the
    /// default (`PresetName.default`).
    static let presetsByName: [String: PopoverLayout] = [
        PresetName.minimal.rawValue: .minimal,
        PresetName.balanced.rawValue: .balanced,
        PresetName.diagnosis.rawValue: .diagnosis,
        PresetName.power.rawValue: .power,
    ]
}

/// The four named presets. `minimal` is the OOB default (D-C1). Public so the
/// config layer can spell the default preset name once (single source of
/// truth) and the A3b Settings tab can enumerate the choices.
public enum PresetName: String, CaseIterable, Codable, Sendable {
    case minimal
    case balanced
    case diagnosis
    case power

    /// The out-of-the-box default preset.
    public static let `default`: PresetName = .minimal
}

// MARK: - Resolution

/// Resolve the effective popover layout from the persisted config values.
///
/// - A non-empty `layoutJSON` that parses to a valid `PopoverLayout` wins
///   (the user has customized/forked a preset).
/// - Otherwise the named `preset` is used as-is.
/// - Unknown preset name / malformed layoutJSON both fail SAFE to
///   `.minimal`.
///
/// Pure + testable; reads no global state.
func effectiveLayout(preset: String, layoutJSON: String) -> PopoverLayout {
    let trimmed = layoutJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty, let custom = PopoverLayout(jsonString: trimmed) {
        return custom
    }
    return PopoverLayout.presetsByName[preset] ?? .minimal
}
