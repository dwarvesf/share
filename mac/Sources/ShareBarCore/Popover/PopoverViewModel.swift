import Foundation

/// What the popover shows for one profile list, in the order of its regions
/// (SPEC-009 `### Layout & structure`): header, search, scope, list, show all, footer.
/// Pure: every text and every decision comes from the CLI's keys; the view only draws it.

/// The one word a tenant's role reads as in the tenant menu.
public enum RoleLabel {
    public static func of(_ role: Role) -> String {
        switch role {
        case .origin: return "Owner"
        case .tenantOrigin: return "Admin"
        case .member: return "Member"
        case .r2Profile: return "Cloud"
        case .quick: return "Quick link"
        case .migrated: return "Moved"
        case .unset, .unknown: return "Not set up"
        }
    }
}

public struct TenantEntry: Sendable, Equatable, Identifiable {
    public var id: String { profile }
    public let profile: String
    public let host: String
    public let roleLabel: String
    public let isCurrent: Bool
}

public struct HeaderModel: Sendable, Equatable {
    /// The current tenant's host, or `Share Bar` before any tenant is set up.
    public let title: String
    public let tenants: [TenantEntry]
    public let manageTitle = "Manage tenants…"
    /// A chevron only when there is another tenant to pick.
    public var hasChevron: Bool { tenants.count > 1 }
}

public struct SearchModel: Sendable, Equatable {
    public let placeholder = "Search links"
    public let hint = "⌃⌥S"
    public let query: String
}

public struct ScopeModel: Sendable, Equatable {
    public let selected: LinkScope
    public let mineTitle = "Mine"
    public let teamTitle = "Team"
}

/// The footer status line: gray when every link answers, orange with a count otherwise.
public enum FooterModel: Sendable, Equatable {
    case allAnswer
    case needLook(Int)

    public init(count: Int) { self = count > 0 ? .needLook(count) : .allAnswer }

    public var text: String {
        switch self {
        case .allAnswer: return "All links answer"
        case .needLook(let count): return "\(count) need a look"
        }
    }

    public var count: Int {
        if case .needLook(let count) = self { return count }
        return 0
    }
}

/// One link row.
public struct RowModel: Sendable, Equatable, Identifiable {
    public let id: String
    public let profile: String
    public let title: String
    public let meta: String
    /// SF Symbol name for the type glyph.
    public let glyph: String
    public let state: LinkState
    public let url: String
    /// True when the viewer added this link (decision D2).
    public let own: Bool
    /// The machine the link lives on, for the offline sentence and the revoke sentence.
    public let machine: String
    public let storage: String?
    /// A row of a member's machine (`origin` set): the only kind an admin revokes.
    public let isMemberLink: Bool
    /// True when this Mac serves the tenant, so Show in Finder and Refresh can act.
    public let servesHere: Bool
    /// The viewer runs the tenant (owner or admin): the only role that revokes another member's link.
    public let isAdmin: Bool
    /// Trailing relative age (`today`, `1d`, `8d`, `3w`, `5mo`, `2y`); nil when the CLI gave no `added` day.
    public var age: String? = nil

    public var dimmed: Bool { !state.answers }
    public var canCopy: Bool { state.canCopy }
    public var canDrag: Bool { state.canDrag }
    public var accessibilityLabel: String { meta.isEmpty ? title : "\(title), \(meta)" }
}

public struct PopoverPrefs {
    public static let recentChoices = [5, 8, 12]
    public static let recentDefault = 8
    public static let recentKey = "RecentLinkCount"
    public static let currentKey = "PopoverCurrentProfile"
    static func scopeKey(_ profile: String) -> String { "PopoverScope.\(profile)" }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// General's count: 5, 8 or 12; anything else reads as the default 8.
    public var recentCount: Int {
        get {
            let stored = defaults.integer(forKey: Self.recentKey)
            return Self.recentChoices.contains(stored) ? stored : Self.recentDefault
        }
        nonmutating set { defaults.set(newValue, forKey: Self.recentKey) }
    }

    /// Mine unless the viewer picked Team for this tenant.
    public func scope(for profile: String) -> LinkScope {
        defaults.string(forKey: Self.scopeKey(profile)) == "team" ? .team : .mine
    }

    public func setScope(_ scope: LinkScope, for profile: String) {
        defaults.set(scope == .team ? "team" : "mine", forKey: Self.scopeKey(profile))
    }

    public var currentProfile: String? {
        get { defaults.string(forKey: Self.currentKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.currentKey) }
    }
}

public struct PopoverViewModel: Sendable, Equatable {
    /// The regions in drawing order. `scope` is absent when every link is the viewer's.
    public enum Region: String, Sendable, Equatable, CaseIterable {
        case header, search, scope, list, showAll, footer
    }

    public let header: HeaderModel
    public let search: SearchModel
    /// Nil when every link is the viewer's: the control is hidden.
    public let scope: ScopeModel?
    public let rows: [RowModel]
    /// The sentence shown instead of rows, or nil.
    public let emptyText: String?
    /// `Show all N links…`, nil with no links at all.
    public let showAllTitle: String?
    public let footer: FooterModel
    public let currentProfile: String?
    public let scopeValue: LinkScope

    public var regions: [Region] {
        var list: [Region] = [.header, .search]
        if scope != nil { list.append(.scope) }
        list.append(.list)
        if showAllTitle != nil { list.append(.showAll) }
        list.append(.footer)
        return list
    }

    /// The status item's accessible label: carries the count (SPEC-009 `### Components & states`).
    public var statusItemLabel: String { PopoverViewModel.statusItemLabel(count: footer.count) }

    public static func statusItemLabel(count: Int) -> String {
        count > 0 ? "Handout Bar, \(count) need a look" : "Handout Bar"
    }

    public static let emptyTenant = "No links yet. Drop a file on the menu bar icon to share it."

    /// `needCount` is the total of needs-a-look lines over every tenant, from `IssueList`.
    public init(
        profiles: ProfilesSnapshot?,
        current: String?,
        scope requested: LinkScope,
        query: String,
        recentCount: Int = PopoverPrefs.recentDefault,
        needCount: Int = 0,
        now: Date = Date()
    ) {
        let entries = (profiles?.profiles ?? []).filter { ProfileView(entry: $0).role != .unset }
        let currentEntry = entries.first { $0.name == current } ?? entries.first
        let tenants = entries.map { entry -> TenantEntry in
            let view = ProfileView(entry: entry)
            return TenantEntry(
                profile: entry.name,
                host: entry.state?.host ?? entry.name,
                roleLabel: RoleLabel.of(view.role),
                isCurrent: entry.name == currentEntry?.name
            )
        }
        header = HeaderModel(title: tenants.first { $0.isCurrent }?.host ?? "Handout Bar", tenants: tenants)
        search = SearchModel(query: query)
        currentProfile = currentEntry?.name
        footer = FooterModel(count: needCount)

        let shares = currentEntry?.state?.shares ?? []
        let role = currentEntry.map { ProfileView(entry: $0).role } ?? .unset
        let state = currentEntry?.state
        let all = shares.map { share -> (RowModel, Share) in
            (PopoverViewModel.row(for: share, profile: currentEntry?.name ?? "", state: state, role: role, scope: requested, now: now), share)
        }
        let live = all.filter { !PopoverViewModel.isExpired($0.1, now: now) }
        let anyOthers = live.contains { !$0.0.own }
        scope = anyOthers ? ScopeModel(selected: requested) : nil
        let effective: LinkScope = anyOthers ? requested : .mine
        scopeValue = effective

        var visible = live
        if effective == .mine { visible = visible.filter { $0.0.own } }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            visible = visible.filter { pair in
                pair.1.name.lowercased().contains(needle)
                    || (PopoverViewModel.ownerName(of: pair.1, state: state, role: role)?.lowercased().contains(needle) ?? false)
            }
        }
        rows = visible.prefix(recentCount).map(\.0)
        if rows.isEmpty {
            emptyText = needle.isEmpty ? PopoverViewModel.emptyTenant : "No links match \"\(query.trimmingCharacters(in: .whitespaces))\"."
        } else {
            emptyText = nil
        }
        showAllTitle = shares.isEmpty ? nil : "Show all \(shares.count) links…"
    }

    // MARK: rows

    /// An expired link never shows in the popover: the CLI's `link_state`, or the clock for a
    /// CLI that predates it (the rule `LinkView` uses).
    static func isExpired(_ share: Share, now: Date) -> Bool {
        if LinkState(raw: share.linkState) == .expired { return true }
        return share.linkState == nil && share.kind != "live" && share.expires != 0
            && share.expires <= Int(now.timeIntervalSince1970)
    }

    /// Decision D2: whose link a row is.
    static func isOwn(_ share: Share, state: Snapshot?, role: Role) -> Bool {
        if role == .member {
            guard let me = state?.member?.id, let mine = MemberID.suffix(of: me),
                  let origin = share.origin, let theirs = MemberID.suffix(of: origin) else { return false }
            return mine == theirs
        }
        return share.origin == nil
    }

    /// Decision D4: the owner name the Team meta line and the search use.
    static func ownerName(of share: Share, state: Snapshot?, role: Role) -> String? {
        if isOwn(share, state: state, role: role) { return "You" }
        if let origin = share.origin, let name = MemberID.name(of: origin) {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        if let by = share.by, !by.isEmpty { return by }
        return nil
    }

    static func row(for share: Share, profile: String, state: Snapshot?, role: Role, scope: LinkScope, now: Date) -> RowModel {
        let own = isOwn(share, state: state, role: role)
        let base = LinkView(share: share, scope: .mine, now: now)
        var meta = base.meta
        // Decision D9: a member's own link on its own Mac reads `this Mac`; another member's reads
        // `<Name>'s machine` with the name capitalised like the Team owner.
        if let origin = share.origin, let name = MemberID.name(of: origin), share.storage != "cloud" {
            let raw = "\(name)'s machine"
            meta = meta.replacingOccurrences(of: raw, with: own ? "this Mac" : "\(display(name))'s machine")
        }
        if scope == .team, let owner = ownerName(of: share, state: state, role: role) {
            meta = meta.isEmpty ? owner : "\(owner) · \(meta)"
        }
        let machine = share.by ?? LinkView.place(of: share) ?? "this Mac"
        return RowModel(
            id: share.id,
            profile: profile,
            title: base.title,
            meta: meta,
            glyph: glyph(for: share),
            state: base.state,
            url: share.url,
            own: own,
            machine: machine,
            storage: share.storage,
            isMemberLink: share.origin != nil,
            servesHere: state?.servesHere ?? false,
            isAdmin: role.isOrigin,
            age: RowAge.text(added: share.added, now: now)
        )
    }

    static func display(_ name: String) -> String { name.prefix(1).uppercased() + name.dropFirst() }

    /// The type glyph: SF Symbols only.
    static func glyph(for share: Share) -> String {
        if share.kind == "live" { return "bolt.horizontal" }
        switch share.type {
        case "video": return "film"
        case "image": return "photo"
        case "pdf", "text", "sheet", "doc": return "doc.text"
        case "folder", "dir": return "folder"
        case "page", "html": return "safari"
        default: return "doc"
        }
    }
}
