import AppKit
import os

private let routerLogger = Logger(subsystem: "com.dwarves.sharebar", category: "router")

/// Where the popover's buttons land. The bodies are stubs that log: the Settings window and
/// the All links window belong to later sub-goals, which replace these bodies and nothing else.
enum SettingsTab: String {
    case general, tenants, members, advanced
}

enum AddSheetKind: String {
    /// Join a team with a code.
    case join
    /// Set up a hostname.
    case setup
}

final class AppRouter {
    static let shared = AppRouter()

    /// The header gear, "Manage tenants…", "Open" and "Open log" of a needs-a-look line.
    /// `member` selects a row of Settings > Members.
    func openSettings(tab: SettingsTab, member: String? = nil) {
        routerLogger.log("openSettings tab=\(tab.rawValue, privacy: .public) member=\(member ?? "-", privacy: .public)")
    }

    /// "Show all N links…".
    func openAllLinks() {
        routerLogger.log("openAllLinks")
    }

    /// The two first-run buttons.
    func openAddSheet(kind: AddSheetKind) {
        routerLogger.log("openAddSheet kind=\(kind.rawValue, privacy: .public)")
    }
}
