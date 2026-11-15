import Foundation

/// The four icon tabs of the Settings window, in drawing order.
public enum SettingsPane: String, CaseIterable, Sendable, Equatable {
    case general, tenants, members, advanced

    public var title: String {
        switch self {
        case .general: return "General"
        case .tenants: return "Tenants"
        case .members: return "Members"
        case .advanced: return "Advanced"
        }
    }

    /// An SF Symbol name.
    public var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .tenants: return "globe"
        case .members: return "person.2"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

public enum SettingsTabs {
    /// Members shows when any profile is a T2 tenant whose role is not `member`. The tab
    /// only decides to show; `member ls` itself proves the admin token, and its refusal
    /// reads as a sentence inside the tab.
    public static func showsMembers(_ profiles: ProfilesSnapshot?) -> Bool {
        guard let profiles else { return false }
        return profiles.profiles.contains { entry in
            guard entry.error == nil, let state = entry.state, state.tier == "t2" else { return false }
            let role = Role(raw: state.role)
            return role != .member && role != .unset && role != .unknown && role != .migrated
        }
    }

    public static func visible(profiles: ProfilesSnapshot?) -> [SettingsPane] {
        SettingsPane.allCases.filter { $0 != .members || showsMembers(profiles) }
    }

    /// Left and right arrows move the selected tab, wrapping at the ends.
    public static func moved(from pane: SettingsPane, forward: Bool, in visible: [SettingsPane]) -> SettingsPane {
        guard let index = visible.firstIndex(of: pane), !visible.isEmpty else { return visible.first ?? .general }
        let count = visible.count
        return visible[(index + (forward ? 1 : count - 1)) % count]
    }
}
