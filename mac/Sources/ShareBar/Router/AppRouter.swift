import AppKit
import ShareBarCore
import os

private let routerLogger = Logger(subsystem: "com.dwarves.sharebar", category: "router")

/// Where the popover's buttons land. The Settings window and its add sheet are real; the All
/// links window belongs to a later sub-goal, which replaces that body and nothing else.
enum SettingsTab: String {
    case general, tenants, members, advanced

    var pane: SettingsPane { SettingsPane(rawValue: rawValue) ?? .general }
}

enum AddSheetKind: String {
    /// Join a team with a code.
    case join
    /// Set up a hostname.
    case setup
}

final class AppRouter {
    static let shared = AppRouter()

    private init() {
        #if DEBUG
        MainActor.assumeIsolated { ShotsHooks.installIfRequested() }
        #endif
    }

    /// The header gear, "Manage tenants…", "Open" and "Open log" of a needs-a-look line.
    /// `member` selects a row of Settings > Members.
    func openSettings(tab: SettingsTab, member: String? = nil) {
        routerLogger.log("openSettings tab=\(tab.rawValue, privacy: .public) member=\(member ?? "-", privacy: .public)")
        MainActor.assumeIsolated { SettingsWindowController.shared.show(pane: tab.pane, member: member) }
    }

    /// "Show all N links…".
    func openAllLinks() {
        routerLogger.log("openAllLinks")
    }

    /// The two first-run buttons.
    func openAddSheet(kind: AddSheetKind) {
        routerLogger.log("openAddSheet kind=\(kind.rawValue, privacy: .public)")
        MainActor.assumeIsolated { SettingsWindowController.shared.showAdd(kind) }
    }
}
