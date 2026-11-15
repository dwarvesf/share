import ShareBarCore
import SwiftUI

/// The Members tab's own state: the last `member ls --json` read, its filter and search, the
/// open row menu. `SettingsStore` loads it when the tab opens and after each member action
/// (DEC-54), never on the 60 s poll.
@MainActor
final class MembersStore: ObservableObject {
    @Published private(set) var list: MemberList?
    /// The CLI's sentence when `member ls` failed; shown in place of the list.
    @Published private(set) var failure: String?
    @Published private(set) var loading = false
    @Published var filter: MemberFilter = .all
    @Published var query = ""
    /// The member id whose row menu is open.
    @Published var menuMember: String?
    /// The row Needs a look pointed at ("Open Members").
    @Published var highlighted: String?
    /// The profile the list was read for.
    @Published private(set) var profile: String?
    private var pointedName: String?
    private var lastRequest = Date.distantPast

    /// A tab open and the refresh behind it can both ask; one read per second is enough.
    func shouldRequest(now: Date = Date()) -> Bool {
        defer { lastRequest = now }
        return now.timeIntervalSince(lastRequest) > 1
    }

    func begin(profile: String) {
        self.profile = profile
        loading = list == nil
    }

    func loaded(_ list: MemberList, profile: String) {
        self.profile = profile
        self.list = list
        failure = nil
        loading = false
        if let pointedName { point(at: pointedName) }
    }

    func failed(_ sentence: String, profile: String) {
        self.profile = profile
        failure = sentence
        loading = false
    }

    func model(shares: [Share], now: Date = Date()) -> MembersModel {
        MembersModel(members: list?.members ?? [], shares: shares, filter: filter, query: query, now: now)
    }

    func record(_ id: String) -> MemberRecord? { list?.members.first { $0.memberID == id } }

    /// A member named by Needs a look: show it in a filter that holds it, with the row marked.
    func point(at name: String) {
        pointedName = name
        guard let found = list?.members.first(where: { $0.name == name }) else { highlighted = nil; return }
        highlighted = found.memberID
        if found.status == "removed" { filter = .removed } else if filter == .removed { filter = .all }
    }

    func toggleMenu(_ id: String) { menuMember = menuMember == id ? nil : id }
    func closeMenu() { menuMember = nil }
}
