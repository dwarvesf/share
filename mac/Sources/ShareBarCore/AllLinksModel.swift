import Foundation

/// The tabs of the All links window (`share-bar-interactions.md` 3a): every link of the
/// current tenant, expired ones included.
public enum AllLinksTab: String, CaseIterable, Sendable {
    case all, live, needsLook, expired

    public var title: String {
        switch self {
        case .all: return "All"
        case .live: return "Live"
        case .needsLook: return "Needs a look"
        case .expired: return "Expired"
        }
    }
}

/// One table row: the popover's `RowModel` plus the columns the window adds.
public struct AllLinksRow: Sendable, Equatable, Identifiable {
    public var id: String { row.id }
    public let row: RowModel
    public let tab: AllLinksTab
    public let owner: String
    public let livesOn: String
    public let expires: String
    /// Cloud rows only; blank for every other row.
    public let views: Int?
    /// `created today`, `created yesterday`, `created 3d ago`; nil when the CLI gave no day.
    public let created: String?
    /// The state word when the link does not answer (`Owner offline`, `Paused`, `Expired`).
    public let stateWord: String?

    public var dimmed: Bool { tab == .expired }
    /// Copy is off for an expired or removed link (DEC-52).
    public var canCopy: Bool { tab != .expired && row.canCopy }
    public var removable: Bool { LinkRemoval.allowed(for: row) }

    public var accessibilityLabel: String {
        var parts = [row.title, owner, livesOn, "expires \(expires)"]
        if let stateWord { parts.insert(stateWord, at: 1) }
        if let views { parts.append(views == 1 ? "1 view" : "\(views) views") }
        return parts.joined(separator: ", ")
    }
}

/// The window's own state: a tab, a query and a selection. Pure, so a swift row covers each move.
public struct AllLinksState: Sendable, Equatable {
    public var tab: AllLinksTab = .all
    public var query = ""
    public var selection: Set<String> = []

    public init(tab: AllLinksTab = .all, query: String = "", selection: Set<String> = []) {
        self.tab = tab
        self.query = query
        self.selection = selection
    }

    /// A tab change clears the selection, as the design does.
    public mutating func show(_ next: AllLinksTab) {
        tab = next
        selection = []
    }

    public mutating func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// Select all: selects every visible row, or clears them when all are already selected.
    public mutating func selectAll(_ visible: [AllLinksRow]) {
        let ids = Set(visible.map(\.id))
        if !ids.isEmpty, ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
    }

    public mutating func clear() { selection = [] }
}

/// What the All links window shows for the current tenant. Pure: the CLI's `link_state` decides
/// every tab, the window never classifies a link itself.
public struct AllLinksModel: Sendable, Equatable {
    public let profile: String
    public let host: String
    public let all: [AllLinksRow]
    public let rows: [AllLinksRow]
    public let counts: [AllLinksTab: Int]
    public let state: AllLinksState
    public let emptyText: String?

    public static let columns = ["Name", "Owner", "Lives on", "Expires", "Views"]

    public init(entry: ProfileEntry?, state: AllLinksState, now: Date = Date()) {
        self.state = state
        profile = entry?.name ?? ""
        host = entry?.state?.host ?? entry?.name ?? ""
        let snapshot = entry?.state
        let role = entry.map { ProfileView(entry: $0).role } ?? .unset
        let built = (snapshot?.shares ?? []).map { share in
            Self.row(for: share, profile: entry?.name ?? "", snapshot: snapshot, role: role, now: now)
        }
        all = built
        counts = Dictionary(uniqueKeysWithValues: AllLinksTab.allCases.map { tab in
            (tab, tab == .all ? built.count : built.filter { $0.tab == tab }.count)
        })
        let needle = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        var shown = state.tab == .all ? built : built.filter { $0.tab == state.tab }
        if !needle.isEmpty {
            shown = shown.filter { "\($0.row.title) \($0.owner) \($0.livesOn)".lowercased().contains(needle) }
        }
        rows = shown
        emptyText = shown.isEmpty ? (needle.isEmpty ? "Nothing here." : "No links match.") : nil
    }

    // MARK: rows

    static func row(for share: Share, profile: String, snapshot: Snapshot?, role: Role, now: Date) -> AllLinksRow {
        let model = PopoverViewModel.row(for: share, profile: profile, state: snapshot, role: role, scope: .team, now: now)
        let expired = PopoverViewModel.isExpired(share, now: now)
        let tab: AllLinksTab = expired ? .expired : (model.state == .live ? .live : .needsLook)
        let owner = PopoverViewModel.ownerName(of: share, state: snapshot, role: role) ?? ""
        let place = share.storage == "cloud" ? "cloud" : (model.own ? "this Mac" : model.machine)
        return AllLinksRow(
            row: model, tab: tab, owner: owner, livesOn: place,
            expires: expiresText(share, expired: expired, now: now),
            views: share.storage == "cloud" ? share.views : nil,
            created: createdText(model.age),
            stateWord: stateWord(model.state, expired: expired)
        )
    }

    static func expiresText(_ share: Share, expired: Bool, now: Date) -> String {
        if expired { return "Expired" }
        if share.kind == "live" { return "Live" }
        if share.expires == 0 { return "Never" }
        let left = LinkView.timeLeft(of: share, now: now) ?? "Never"
        return left.replacingOccurrences(of: " left", with: "")
    }

    static func createdText(_ age: String?) -> String? {
        guard let age else { return nil }
        if age == "today" { return "created today" }
        if age == "1d" { return "created yesterday" }
        return "created \(age) ago"
    }

    static func stateWord(_ state: LinkState, expired: Bool) -> String? {
        if expired { return "Expired" }
        switch state {
        case .live, .shadowed: return nil
        case .offline: return "Owner offline"
        case .paused: return "Paused"
        case .revoked: return "Removed by admin"
        case .expired: return "Expired"
        case .gateMissing: return "No login gate"
        }
    }

    // MARK: footer and bulk bar

    public var footer: String {
        let mine = all.filter(\.row.own).count
        return "\(all.count) \(all.count == 1 ? "link" : "links") · \(mine) yours · Views are counted for cloud links only"
    }

    /// Only rows on screen count: a search that hides a selected row also takes it out of every bulk action.
    public var selectedRows: [AllLinksRow] { rows.filter { state.selection.contains($0.id) } }
    public var selectedText: String { "\(selectedRows.count) selected" }

    // MARK: bulk actions

    /// One URL per line, in table order; an expired or removed link is skipped (its Copy is off).
    public var bulkCopyText: String { selectedRows.filter(\.canCopy).map(\.row.url).joined(separator: "\n") }

    public var bulkCopyCount: Int { selectedRows.filter(\.canCopy).count }

    public static func copiedSentence(_ count: Int) -> String {
        count == 1 ? "Copied 1 link." : "Copied \(count) links, one per line."
    }

    /// The links a bulk Remove acts on: own links, and another member's link when the viewer is
    /// an admin (that one is revoked, not removed).
    public var bulkRemovable: [AllLinksRow] { selectedRows.filter(\.removable) }

    /// One `rm <id>...` for every removable id: another member's link is revoked by the same verb.
    public var bulkRemoveArgv: [String]? {
        let ids = bulkRemovable.map(\.id)
        guard !ids.isEmpty, !profile.isEmpty else { return nil }
        return ProfileArgs.argv(profile, ["rm"] + ids)
    }

    public var bulkRemoveSentence: String {
        let rows = bulkRemovable
        let revoked = rows.filter { !$0.row.own }.count
        let removed = rows.count - revoked
        if revoked == 0 { return "Removed \(removed) \(removed == 1 ? "link" : "links"). \(removed == 1 ? "It stops" : "They stop") answering." }
        if removed == 0 { return "Revoked \(revoked) \(revoked == 1 ? "link" : "links"). \(revoked == 1 ? "It stops" : "They stop") answering now; the files stay on their machines." }
        return "Removed \(removed) and revoked \(revoked). They stop answering."
    }
}
