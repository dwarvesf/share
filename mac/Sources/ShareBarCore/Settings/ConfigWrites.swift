import Foundation

/// General's "New links expire" choices; each writes `share config ttl <value>` (SPEC-010 G14).
public enum ExpiryChoice: String, CaseIterable, Sendable, Equatable {
    case oneDay = "1d"
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case never

    public var label: String {
        switch self {
        case .oneDay: return "after 1 day"
        case .sevenDays: return "after 7 days"
        case .thirtyDays: return "after 30 days"
        case .never: return "never"
        }
    }

    /// The value `share config ttl` prints; nil for a value the picker has no row for.
    public init?(configValue: String) {
        self.init(rawValue: configValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// General's "Store new links" choices (`share config storage_default`).
public enum StorageChoice: String, CaseIterable, Sendable, Equatable {
    case local, cloud

    public var label: String { self == .local ? "On this Mac" : "In the cloud" }
}

/// The argv General writes to the CLI config. A value is one of the enum cases, so no free
/// text reaches the CLI.
public enum ConfigWrites {
    public static func ttl(profile: String, _ choice: ExpiryChoice) -> [String] {
        ProfileArgs.argv(profile, ["config", "ttl", choice.rawValue])
    }

    public static func storageDefault(profile: String, _ choice: StorageChoice) -> [String] {
        ProfileArgs.argv(profile, ["config", "storage_default", choice.rawValue])
    }

    public static func readTTL(profile: String) -> [String] { ProfileArgs.argv(profile, ["config", "ttl"]) }
    public static func readStorageDefault(profile: String) -> [String] { ProfileArgs.argv(profile, ["config", "storage_default"]) }

    /// "Store new links" shows only on a tenant with cloud storage (R2 on).
    public static func offersStorage(_ entry: ProfileEntry) -> Bool {
        guard entry.error == nil, let state = entry.state else { return false }
        return state.r2 == true || state.tier == "t1" || state.tier == "t2"
    }

    /// The profile General's two CLI writes go to: the popover's current tenant when it is
    /// set up, else the first tenant that is.
    public static func target(profiles: ProfilesSnapshot?, current: String?) -> ProfileEntry? {
        let usable = (profiles?.profiles ?? []).filter { entry in
            guard entry.error == nil, let state = entry.state else { return false }
            let role = Role(raw: state.role)
            return role != .unset && role != .migrated && role != .member
        }
        return usable.first { $0.name == current } ?? usable.first
    }
}

/// General's preferences kept in the app's defaults. The recent count shares the popover's
/// own key, so the popover follows it with no change of its own.
public struct GeneralPrefs {
    public static let menuShowsKey = "MenuShows"
    public static let copyAfterKey = "AfterSharingCopy"
    public static let notifyAfterKey = "AfterSharingNotify"
    public static let notifyOfflineKey = "NotifyOffline"
    public static let notifyExpiryKey = "NotifyExpiry"
    public static let notifyMemberKey = "NotifyMember"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    public var menuShows: LinkScope {
        get { defaults.string(forKey: Self.menuShowsKey) == "team" ? .team : .mine }
        nonmutating set { defaults.set(newValue == .team ? "team" : "mine", forKey: Self.menuShowsKey) }
    }

    /// Menu shows is the scope a tenant opens with. The popover remembers one scope per
    /// tenant, so choosing here sets each tenant's remembered scope (the viewer can still
    /// switch in the menu at any time).
    public func setMenuShows(_ scope: LinkScope, profiles: [String]) {
        menuShows = scope
        let popover = PopoverPrefs(defaults: defaults)
        for name in profiles { popover.setScope(scope, for: name) }
    }

    public var recentCount: Int {
        get { PopoverPrefs(defaults: defaults).recentCount }
        nonmutating set { PopoverPrefs(defaults: defaults).recentCount = newValue }
    }

    public var copyAfterSharing: Bool {
        get { bool(Self.copyAfterKey, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Self.copyAfterKey) }
    }

    public var notifyAfterSharing: Bool {
        get { bool(Self.notifyAfterKey, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Self.notifyAfterKey) }
    }

    public var notifyOffline: Bool {
        get { bool(Self.notifyOfflineKey, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Self.notifyOfflineKey) }
    }

    public var notifyExpiry: Bool {
        get { bool(Self.notifyExpiryKey, default: false) }
        nonmutating set { defaults.set(newValue, forKey: Self.notifyExpiryKey) }
    }

    public var notifyMember: Bool {
        get { bool(Self.notifyMemberKey, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Self.notifyMemberKey) }
    }
}
