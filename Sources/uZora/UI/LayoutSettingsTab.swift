import SwiftUI

/// Settings → "Layout" tab (Phase A3b, plan D1/D2/D3/D7/D-C1): customize the
/// menu-bar popover — pick a preset, reorder + show/hide content blocks,
/// show/hide the System-overview tiles — with a **live preview** beside the
/// controls.
///
/// Every edit persists IMMEDIATELY through `ConfigBindings.update`, writing
/// `ui.popover.preset` / `ui.popover.layoutJSON`; A3a's `PopoverGate` observes
/// that config and hot-reloads the real popover, so there is no "Save" button.
/// Picking a preset sets the base and clears any fork; a reorder/toggle forks
/// the active preset by writing the customized JSON.
///
/// The tab is a thin container that composes small `private struct` sub-views
/// (`PresetPickerView` / `BlockListView` / `TileChecklistView` /
/// `LayoutPreviewView`) — each `body` is intentionally tiny to stay inside the
/// cross-SDK SwiftUI view type-checker budget (the reorder `List` + the
/// embedded `PopoverView` preview are the biggest timeout risk in this build).
struct LayoutTab: View {
    @ObservedObject var bindings: ConfigBindings
    @ObservedObject var state: UIState

    /// The working (effective) layout being edited. Seeded from the persisted
    /// effective layout on appear; every mutation is written straight back to
    /// config, so this stays in lock-step with what the real popover renders.
    @State private var working: PopoverLayout = .minimal

    /// Preview data source: `false` = live `UIState` (D1 default), `true` = the
    /// motion `DemoDataSource` (animates the widgets through every state so the
    /// operator can evaluate the layout on an otherwise-healthy Mac).
    @State private var previewUsesDemo: Bool = false

    /// Tab-owned motion demo for the "Demo" preview mode. `@StateObject` so its
    /// ~5s timer persists across re-renders; observed by the preview only when
    /// `previewUsesDemo` is on.
    @StateObject private var demo = DemoDataSource()

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            controls
            Divider()
            previewPane
        }
        .padding()
        .onAppear(perform: seedWorking)
    }

    /// Left: editing controls (preset + block reorder/visibility + tiles +
    /// reset).
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Preset", defaultValue: "Preset"))
                .font(.headline)
            PresetPickerView(bindings: bindings, onSelect: selectPreset)
            Text(String(
                localized: "Blocks — drag to reorder, toggle to show",
                defaultValue: "Blocks — drag to reorder, toggle to show"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            BlockListView(working: working, onChange: persist)
                .frame(height: 170)
            Text(String(localized: "System overview tiles", defaultValue: "System overview tiles"))
                .font(.subheadline)
                .fontWeight(.semibold)
            TileChecklistView(working: working, onChange: persist)
            Button(role: .destructive, action: resetToDefault) {
                Text(String(localized: "Reset to default", defaultValue: "Reset to default"))
            }
            .padding(.top, 2)
            Spacer()
        }
        .frame(width: 300)
    }

    /// Right: the live preview + a Live/Demo data-source toggle above it.
    private var previewPane: some View {
        VStack(spacing: 8) {
            Picker("", selection: $previewUsesDemo) {
                Text(String(localized: "Live", defaultValue: "Live")).tag(false)
                Text(String(localized: "Demo", defaultValue: "Demo")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            LayoutPreviewView(
                state: state,
                demo: demo,
                usesDemo: previewUsesDemo,
                layout: working
            )
            Spacer()
        }
    }

    // MARK: - Mutations (persist EVERY edit through ConfigBindings)

    /// Seed the working buffer from the persisted effective layout.
    private func seedWorking() {
        working = effectiveLayout(
            preset: bindings.current.ui.popover.preset,
            layoutJSON: bindings.current.ui.popover.layoutJSON
        )
    }

    /// Pick a preset = the new base (D7): store the name, CLEAR any fork, and
    /// reset the working layout to that preset.
    private func selectPreset(_ name: PresetName) {
        bindings.update {
            $0.ui.popover.preset = name.rawValue
            $0.ui.popover.layoutJSON = ""
        }
        working = PopoverLayout.presetsByName[name.rawValue] ?? .minimal
    }

    /// Persist a working-layout edit (reorder / block toggle / tile toggle):
    /// FORK the active preset by writing the customized JSON. The A3a resolver
    /// then renders this exact layout.
    private func persist(_ updated: PopoverLayout) {
        working = updated
        bindings.update { $0.ui.popover.layoutJSON = updated.toJSONString() }
    }

    /// Reset to the out-of-the-box default (D7, mandatory): default preset,
    /// no fork, working layout back to `.minimal`.
    private func resetToDefault() {
        bindings.update {
            $0.ui.popover.preset = PresetName.default.rawValue
            $0.ui.popover.layoutJSON = ""
        }
        working = .minimal
    }
}

// MARK: - Preset picker

/// Segmented picker over the four `PresetName`s. Reflects the persisted active
/// preset; selecting one calls back into the tab (which clears the fork + resets
/// the working layout). Small body — the whole view is one `Picker`.
private struct PresetPickerView: View {
    @ObservedObject var bindings: ConfigBindings
    let onSelect: (PresetName) -> Void

    var body: some View {
        Picker("", selection: Binding(
            get: { PresetName(rawValue: bindings.current.ui.popover.preset) ?? .default },
            set: { onSelect($0) }
        )) {
            ForEach(PresetName.allCases, id: \.self) { name in
                Text(presetLabel(name)).tag(name)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

// MARK: - Block reorder + show/hide

/// The content-block editor (D3): a `List` of the working layout's blocks with
/// per-row visibility `Toggle`s and drag reorder via `ForEach.onMove` (macOS
/// reorders in place without an explicit `EditMode`, per the plan's converged
/// decision). Each edit routes through the pure `PopoverLayout` helpers then
/// `onChange` (persist). Small body — one `List`.
private struct BlockListView: View {
    let working: PopoverLayout
    let onChange: (PopoverLayout) -> Void

    var body: some View {
        List {
            ForEach(working.blocks, id: \.kind) { cfg in
                Toggle(isOn: Binding(
                    get: { cfg.visible },
                    set: { onChange(working.settingBlock(cfg.kind, visible: $0)) }
                )) {
                    Text(blockLabel(cfg.kind))
                }
            }
            .onMove { indices, newOffset in
                onChange(working.movingBlock(from: indices, to: newOffset))
            }
        }
    }
}

// MARK: - Tile checklist

/// The System-overview tile editor (D3): a plain checklist of visibility
/// `Toggle`s in the canonical tile order (no per-tile drag). Each toggle routes
/// through the pure `settingTile` helper then `onChange` (persist). Small body.
private struct TileChecklistView: View {
    let working: PopoverLayout
    let onChange: (PopoverLayout) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(working.tiles, id: \.kind) { cfg in
                Toggle(isOn: Binding(
                    get: { cfg.visible },
                    set: { onChange(working.settingTile(cfg.kind, visible: $0)) }
                )) {
                    Text(tileLabel(cfg.kind))
                }
            }
        }
    }
}

// MARK: - Live preview

/// Embeds the REAL `PopoverView` rendering the WORKING layout, scaled down to
/// fit the Settings pane (D1/D2). `usesDemo` swaps the data source between the
/// live `UIState` and the motion `DemoDataSource`. Hit-testing is disabled so
/// the preview is look-only (its footer's Quit / Open-Settings buttons can't be
/// triggered by accident). Small body — a scaled, framed `PopoverView`.
private struct LayoutPreviewView: View {
    @ObservedObject var state: UIState
    @ObservedObject var demo: DemoDataSource
    let usesDemo: Bool
    let layout: PopoverLayout

    var body: some View {
        preview
            .scaleEffect(Self.previewScale)
            .frame(width: Self.previewWidth, height: Self.previewHeight)
            .allowsHitTesting(false)
    }

    /// The conditional keeps two DISTINCT `PopoverView` generic instantiations
    /// (`<DemoDataSource>` / `<UIState>`) — no `AnyView`, cross-SDK-safe.
    @ViewBuilder
    private var preview: some View {
        if usesDemo {
            PopoverView(state: demo, layout: layout)
        } else {
            PopoverView(state: state, layout: layout)
        }
    }

    // PopoverView's fixed footprint is 400×500; 0.62 fits the Settings pane.
    private static let previewScale: CGFloat = 0.62
    private static let previewWidth: CGFloat = 248
    private static let previewHeight: CGFloat = 310
}

// MARK: - Plain human labels (endonym-free, D3)

/// Plain block name for the Layout tab rows.
private func blockLabel(_ kind: WidgetKind) -> String {
    switch kind {
    case .verdict:
        return String(localized: "Verdict", defaultValue: "Verdict")
    case .attention:
        return String(localized: "Attention", defaultValue: "Attention")
    case .systemOverview:
        return String(localized: "System overview", defaultValue: "System overview")
    case .topProcesses:
        return String(localized: "Top processes", defaultValue: "Top processes")
    case .recentActions:
        return String(localized: "Recent actions", defaultValue: "Recent actions")
    }
}

/// Plain tile name for the Layout tab checklist.
private func tileLabel(_ kind: TileKind) -> String {
    switch kind {
    case .memPressureLevel:
        return String(localized: "Memory pressure", defaultValue: "Memory pressure")
    case .cpuTemp:
        return String(localized: "CPU temp", defaultValue: "CPU temp")
    case .diskFree:
        return String(localized: "Disk free", defaultValue: "Disk free")
    case .battery:
        return String(localized: "Battery", defaultValue: "Battery")
    }
}

/// Plain preset name for the Layout tab picker.
private func presetLabel(_ name: PresetName) -> String {
    switch name {
    case .minimal:
        return String(localized: "Minimal", defaultValue: "Minimal")
    case .balanced:
        return String(localized: "Balanced", defaultValue: "Balanced")
    case .diagnosis:
        return String(localized: "Diagnosis", defaultValue: "Diagnosis")
    case .power:
        return String(localized: "Power", defaultValue: "Power")
    }
}
