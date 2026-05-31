import Foundation

/// Holds the four MVP reversible actions and resolves which apply to a given
/// alert (Q6 hybrid: built-in default mapping + config override).
///
/// `actor` for the same reason `ProbeRegistry` is — it's shared state read
/// from the event pipeline, the notification handler, and the channel layer.
/// The action *instances* are `Sendable` value/struct types so handing them
/// out is safe.
///
/// Descriptor strings (name/detail) are localized via `String(localized:)`
/// at construction so Settings / notifications / MCP all read the same
/// localized metadata.
public actor ActionRegistry {

    private let actions: [String: any Action]
    /// Stable id order (matches `ActionsConfig.descriptors`).
    private let order: [String]

    public init(actions: [any Action]) {
        var map: [String: any Action] = [:]
        var ord: [String] = []
        for a in actions {
            map[a.descriptor.id] = a
            ord.append(a.descriptor.id)
        }
        self.actions = map
        self.order = ord
    }

    /// All registered actions in canonical id order.
    public func all() -> [any Action] {
        order.compactMap { actions[$0] }
    }

    /// All descriptors in canonical id order (cheap — for Settings / MCP /
    /// REST listings that don't need the action instance).
    public func allDescriptors() -> [ActionDescriptor] {
        order.compactMap { actions[$0]?.descriptor }
    }

    /// Look up one action by id.
    public func action(id: String) -> (any Action)? {
        actions[id]
    }

    /// Descriptor for an id.
    public func descriptor(id: String) -> ActionDescriptor? {
        actions[id]?.descriptor
    }

    /// Resolve the actions eligible for an alert from `probe` at `severity`,
    /// applying the Q6 hybrid mapping:
    ///
    ///  - **built-in default**: each action's `descriptor.relatedProbe` +
    ///    `descriptor.relatedSeverityFloor` (all four → `disk`, floor `warn`).
    ///  - **config override**: if `config[id].probe` / `.severityFloor` are
    ///    set, they REPLACE the descriptor defaults for the match test.
    ///
    /// An action matches when the (effective) probe equals `probe` AND
    /// `severity >= (effective) floor`. Returned in canonical id order.
    public func actionsFor(probe: String, severity: Severity, config: ActionsConfig) -> [any Action] {
        order.compactMap { id -> (any Action)? in
            guard let action = actions[id] else { return nil }
            let d = action.descriptor
            let override = config[id: id]
            let effectiveProbe = override?.probe ?? d.relatedProbe
            let effectiveFloor = override?.severityFloor ?? d.relatedSeverityFloor
            guard effectiveProbe == probe, severity >= effectiveFloor else { return nil }
            return action
        }
    }

    /// Descriptor-only variant of `actionsFor` (no instances needed).
    public func descriptorsFor(probe: String, severity: Severity, config: ActionsConfig) -> [ActionDescriptor] {
        actionsFor(probe: probe, severity: severity, config: config).map(\.descriptor)
    }

    // MARK: - Default population

    /// Build the registry with the four MVP actions, descriptors localized.
    /// All bound to the `disk` probe at the `warn` floor (Q5/Q6 default).
    public static func defaultPopulated() -> ActionRegistry {
        ActionRegistry(actions: [
            ShellCommandAction(descriptor: Descriptors.pruneApfsSnapshots, kind: .pruneSnapshots),
            ClearDirectoryAction.derivedData(descriptor: Descriptors.clearDerivedData),
            ShellCommandAction(descriptor: Descriptors.brewCleanup, kind: .brewCleanup),
            ClearDirectoryAction.userCaches(descriptor: Descriptors.clearUserCaches),
        ])
    }

    /// The four canonical descriptors with localized name/detail. Static so
    /// tests + the notification layer reference the same metadata.
    public enum Descriptors {
        public static let pruneApfsSnapshots = ActionDescriptor(
            id: "prune_apfs_snapshots",
            name: String(localized: "Prune local APFS snapshots", defaultValue: "Prune local APFS snapshots"),
            detail: String(
                localized: "Delete local Time Machine snapshots (tmutil deletelocalsnapshots). Reversible: macOS recreates snapshots automatically.",
                defaultValue: "Delete local Time Machine snapshots (tmutil deletelocalsnapshots). Reversible: macOS recreates snapshots automatically."
            ),
            reversible: true,
            requiresSudo: false,
            relatedProbe: "disk",
            relatedSeverityFloor: .warn
        )

        public static let clearDerivedData = ActionDescriptor(
            id: "clear_derived_data",
            name: String(localized: "Clear Xcode DerivedData", defaultValue: "Clear Xcode DerivedData"),
            detail: String(
                localized: "Remove ~/Library/Developer/Xcode/DerivedData. Reversible: Xcode rebuilds it on the next build.",
                defaultValue: "Remove ~/Library/Developer/Xcode/DerivedData. Reversible: Xcode rebuilds it on the next build."
            ),
            reversible: true,
            requiresSudo: false,
            relatedProbe: "disk",
            relatedSeverityFloor: .warn
        )

        public static let brewCleanup = ActionDescriptor(
            id: "brew_cleanup",
            name: String(localized: "Run brew cleanup", defaultValue: "Run brew cleanup"),
            detail: String(
                localized: "Run 'brew cleanup' to remove stale Homebrew downloads and old versions. Skipped if Homebrew is not installed.",
                defaultValue: "Run 'brew cleanup' to remove stale Homebrew downloads and old versions. Skipped if Homebrew is not installed."
            ),
            reversible: true,
            requiresSudo: false,
            relatedProbe: "disk",
            relatedSeverityFloor: .warn
        )

        public static let clearUserCaches = ActionDescriptor(
            id: "clear_user_caches",
            name: String(localized: "Clear user caches", defaultValue: "Clear user caches"),
            detail: String(
                localized: "Remove ~/Library/Caches contents. Caution: some apps store login/session state under Caches and may need to re-authenticate or rebuild settings.",
                defaultValue: "Remove ~/Library/Caches contents. Caution: some apps store login/session state under Caches and may need to re-authenticate or rebuild settings."
            ),
            reversible: true,
            requiresSudo: false,
            caution: true,
            relatedProbe: "disk",
            relatedSeverityFloor: .warn
        )

        /// All four in canonical order.
        public static let all: [ActionDescriptor] = [
            pruneApfsSnapshots, clearDerivedData, brewCleanup, clearUserCaches,
        ]
    }
}
