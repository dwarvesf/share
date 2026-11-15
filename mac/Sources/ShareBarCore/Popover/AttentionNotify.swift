import Foundation

/// General's three "Notify me when" toggles, as values the app reads.
public struct NotifyPrefs: Sendable, Equatable {
    public var offline: Bool
    public var expiry: Bool
    public var member: Bool

    public init(offline: Bool, expiry: Bool, member: Bool) {
        self.offline = offline
        self.expiry = expiry
        self.member = member
    }
}

extension GeneralPrefs {
    public var notifyPrefs: NotifyPrefs { NotifyPrefs(offline: notifyOffline, expiry: notifyExpiry, member: notifyMember) }
}

public struct NotifyEvent: Sendable, Equatable {
    public let key: String
    public let title: String
    public let body: String

    public init(key: String, title: String, body: String) {
        self.key = key
        self.title = title
        self.body = body
    }
}

/// Turns the change between two `profiles` reads into notifications, one per new fact. The
/// first read only primes the set (a launch never announces what was already true), a fact
/// that clears can fire again, and the app never decides what a state means: each event comes
/// from the CLI's own `link_state` and needs-a-look lines.
public struct AttentionNotifier: Sendable {
    private var seen: Set<String> = []
    private var primed = false

    public init() {}

    /// Links that expire within this many seconds count as about to expire.
    public static let expirySoon = 86_400

    public mutating func events(
        profiles: ProfilesSnapshot?, members: [String: MemberList], prefs: NotifyPrefs, current: String?, now: Date = Date()
    ) -> [NotifyEvent] {
        guard let profiles else { return [] }
        var facts: [NotifyEvent] = []
        for entry in profiles.profiles {
            guard let state = entry.state else { continue }
            let role = ProfileView(entry: entry).role
            let host = state.host ?? entry.name
            if prefs.offline {
                let offline = state.shares.filter {
                    LinkState(raw: $0.linkState) == .offline && PopoverViewModel.isOwn($0, state: state, role: role)
                }
                let machines = Dictionary(grouping: offline) { $0.by ?? "this Mac" }
                for (machine, rows) in machines {
                    let count = rows.count
                    facts.append(NotifyEvent(
                        key: "offline:\(entry.name):\(machine)", title: "\(machine) is offline",
                        body: "\(count) of your \(count == 1 ? "link answers" : "links answer") 503 on \(host) until it is back."))
                }
            }
            if prefs.expiry {
                let now = Int(now.timeIntervalSince1970)
                for share in state.shares where share.kind != "live" && share.expires > now && share.expires - now <= Self.expirySoon
                    && LinkState(raw: share.linkState) == .live && PopoverViewModel.isOwn(share, state: state, role: role) {
                    let hours = max(1, (share.expires - now) / 3_600)
                    facts.append(NotifyEvent(key: "expiry:\(entry.name):\(share.id)", title: "\(share.name) expires soon",
                                             body: "It stops answering in about \(hours) \(hours == 1 ? "hour" : "hours") on \(host)."))
                }
            }
        }
        if prefs.member {
            let issues = IssueList(profiles: profiles, current: current, members: members, now: now)
            for group in issues.groups {
                for line in group.lines where line.kind == .member {
                    facts.append(NotifyEvent(key: "member:\(line.id)", title: line.title, body: "\(line.detail) on \(group.host)."))
                }
            }
        }
        let keys = Set(facts.map(\.key))
        defer { seen = keys }
        guard primed else {
            primed = true
            return []
        }
        return facts.filter { !seen.contains($0.key) }.sorted { $0.key < $1.key }
    }
}
