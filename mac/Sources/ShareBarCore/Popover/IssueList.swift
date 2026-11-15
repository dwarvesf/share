import Foundation

/// The one thing a needs-a-look line offers (interactions doc, section 4). Each maps to a
/// command argv, or to a place in the app a router opens, or to text to copy. The app never
/// classifies state itself: a line exists because the CLI's own keys say so.
public enum IssueAction: Sendable, Equatable {
    case resume(argv: [String])
    case start(argv: [String])
    case renew(argv: [String])
    case copyRequest(text: String)
    case open(profile: String, member: String)
    case resumeMember(argv: [String])
    case remove(profile: String, member: String)
    case sendCode(argv: [String])
    case finish(argv: [String])
    case cleanUp(argv: [String])
    case openLog(profile: String)

    public var label: String {
        switch self {
        case .resume: return "Resume"
        case .start: return "Start"
        case .renew: return "Renew"
        case .copyRequest: return "Copy request"
        case .open: return "Open"
        case .resumeMember: return "Resume"
        case .remove: return "Remove"
        case .sendCode: return "Send a new code"
        case .finish: return "Finish"
        case .cleanUp: return "Clean up"
        case .openLog: return "Open log"
        }
    }

    /// The command this action runs, nil for an action that opens a place or copies text.
    public var argv: [String]? {
        switch self {
        case .resume(let argv), .start(let argv), .renew(let argv), .resumeMember(let argv),
             .sendCode(let argv), .finish(let argv), .cleanUp(let argv):
            return argv
        case .copyRequest, .open, .remove, .openLog:
            return nil
        }
    }
}

public enum IssueKind: Int, Sendable, Equatable, Comparable {
    case interrupted = 0, serving, key, member

    public static func < (lhs: IssueKind, rhs: IssueKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct IssueLine: Sendable, Equatable, Identifiable {
    public let id: String
    public let profile: String
    public let host: String
    public let kind: IssueKind
    public let title: String
    public let detail: String
    /// SF Symbol name.
    public let symbol: String
    /// Nil when the CLI's own argv failed its shape check (nothing runs, only the text shows).
    public let action: IssueAction?
}

public struct IssueGroup: Sendable, Equatable, Identifiable {
    public var id: String { profile }
    public let profile: String
    public let host: String
    public let isCurrent: Bool
    public let lines: [IssueLine]
}

/// The needs-a-look list: lines grouped by tenant, the current tenant first, each tenant's
/// lines in the interactions doc's order (interrupted commands, own serving problems, key
/// problems, member problems). An invited member is never a line.
public struct IssueList: Sendable, Equatable {
    public let groups: [IssueGroup]
    public static let emptyText = "Nothing needs a look."

    public var lines: [IssueLine] { groups.flatMap(\.lines) }
    public var count: Int { lines.count }

    public init(groups: [IssueGroup]) { self.groups = groups }

    /// `members` is each admin profile's `member ls --json`, keyed by profile name.
    public init(profiles: ProfilesSnapshot?, current: String?, members: [String: MemberList] = [:], now: Date = Date()) {
        let entries = (profiles?.profiles ?? []).filter { $0.error == nil && $0.state != nil }
        let currentName = entries.first { $0.name == current }?.name ?? entries.first?.name
        let ordered = entries.filter { $0.name == currentName } + entries.filter { $0.name != currentName }
        groups = ordered.compactMap { entry -> IssueGroup? in
            let lines = IssueList.tenantLines(for: entry, members: members[entry.name], now: now)
            guard !lines.isEmpty else { return nil }
            return IssueGroup(
                profile: entry.name,
                host: entry.state?.host ?? entry.name,
                isCurrent: entry.name == currentName,
                lines: lines
            )
        }
    }

    // MARK: one tenant

    static func tenantLines(for entry: ProfileEntry, members: MemberList?, now: Date) -> [IssueLine] {
        guard let state = entry.state else { return [] }
        let role = Role(raw: state.role)
        if role == .migrated || role == .unset { return [] }
        let host = state.host ?? entry.name
        var found: [(rank: Int, line: IssueLine)] = []
        func add(_ rank: Int, _ line: IssueLine) { found.append((rank, line)) }
        func line(_ key: String, _ kind: IssueKind, _ title: String, _ detail: String, _ symbol: String, _ action: IssueAction?) -> IssueLine {
            IssueLine(id: "\(entry.name):\(key)", profile: entry.name, host: host, kind: kind, title: title, detail: detail, symbol: symbol, action: action)
        }

        // 1. interrupted commands: a journal whose process died
        for (index, op) in (state.ops ?? []).enumerated() where op.verb != "?" && op.aliveKnown && !op.alive {
            let argv = JournalRun.argv(op: op, kind: .rerun, profile: entry.name)
            var title = "\(opWord(op.verb)) stopped"
            if let step = op.step, let of = op.of { title += " at step \(step) of \(of)" }
            let detail = op.name.flatMap { $0.isEmpty ? nil : "The \(OpLine.clean($0)) step did not finish" } ?? "Resume continues from the last step"
            add(0, line("op\(index)", .interrupted, title, detail, "arrow.clockwise", argv.map { .resume(argv: $0) }))
        }

        // 2. own serving problems
        if let serve = state.serve {
            if serve.phase == "failed" {
                let reason = ServeSentence.reasonCopy(serve.reason)
                add(1, line("serve", .serving, "This Mac stopped serving", reason.prefix(1).uppercased() + reason.dropFirst(), "stop.circle", .start(argv: ProfileArgs.start(entry.name))))
            } else if serve.phase == "tunnel_down" {
                add(1, line("tunnel", .serving, "Tunnel not connected", "Links on this Mac do not answer until it reconnects", "wifi.slash", .openLog(profile: entry.name)))
            }
        }

        // 3. key problems
        if let token = state.token, let key = keyLine(token: token, state: state, role: role, profile: entry.name, host: host, now: now) {
            add(2, line("token", .key, key.title, key.detail, "key", key.action))
        }

        // 4. member problems
        if state.member?.status == "removed" {
            add(3, line("removed", .member, "You were removed from \(host)", "Clean up this Mac", "person.crop.circle.badge.minus", .cleanUp(argv: ProfileArgs.argv(entry.name, ["leave", "--local"]))))
        }
        if role == .tenantOrigin, let members {
            for (rank, memberLine) in memberLines(members: members, state: state, profile: entry.name, host: host) {
                add(3 + rank, memberLine)
            }
        }
        return found.sorted { $0.rank < $1.rank }.map(\.line)
    }

    static func opWord(_ verb: String) -> String {
        if verb.hasPrefix("setup") || verb == "no-r2" || verb == "no-members" { return "Setup" }
        if verb == "join" { return "Joining" }
        if verb == "add" { return "Adding a link" }
        if verb.hasPrefix("teardown") { return "Removing the tenant" }
        if verb == "migrate" { return "Moving" }
        if verb.hasPrefix("member-") { return "Member \(verb.dropFirst("member-".count))" }
        return verb.prefix(1).uppercased() + verb.dropFirst()
    }

    // MARK: key

    static func keyLine(token: TokenInfo, state: Snapshot, role: Role, profile: String, host: String, now: Date)
        -> (title: String, detail: String, action: IssueAction)? {
        let title: String
        switch token.status {
        case "expiring":
            let days = daysLeft(token.expiresOn, now: now)
            title = days.map { $0 <= 0 ? "Your key expires today" : "Your key expires in \($0) day\($0 == 1 ? "" : "s")" } ?? "Your key expires soon"
        case "expired": title = "Your key expired"
        case "invalid": title = "Your key stopped working"
        default: return nil
        }
        let me = state.member?.name ?? profile
        switch role {
        case .member:
            let when = token.expiresOn.map { " on \($0)" } ?? ""
            let text = "Hi, my key for \(host) expires\(when) or has stopped working. Please run: share member renew \(me)"
            return (title, "Ask the admin to renew it", .copyRequest(text: text))
        case .tenantOrigin:
            return (title, "Renew it with share member renew", .renew(argv: ProfileArgs.argv(profile, ["member", "renew", me])))
        default:
            return (title, "Store a new key with share api-token", .renew(argv: ProfileArgs.argv(profile, ["api-token"])))
        }
    }

    static func daysLeft(_ expiresOn: String?, now: Date) -> Int? {
        guard let expiresOn else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let end = formatter.date(from: String(expiresOn.prefix(10))) else { return nil }
        return Int((end.timeIntervalSince(now) / 86_400).rounded(.down))
    }

    // MARK: members (admin)

    /// The verb a stopped `...ing` status reruns.
    static let finishVerb: [String: String] = [
        "pausing": "pause", "resuming": "resume", "rotating": "rotate", "renewing": "renew",
        "removing": "rm", "inviting": "invite", "adding": "add",
    ]

    static func display(_ name: String) -> String { name.prefix(1).uppercased() + name.dropFirst() }

    static func memberLines(members: MemberList, state: Snapshot, profile: String, host: String) -> [(Int, IssueLine)] {
        var out: [(Int, IssueLine)] = []
        func line(_ key: String, _ title: String, _ detail: String, _ symbol: String, _ action: IssueAction) -> IssueLine {
            IssueLine(id: "\(profile):m:\(key)", profile: profile, host: host, kind: .member, title: title, detail: detail, symbol: symbol, action: action)
        }
        for member in members.members {
            let name = display(member.name)
            let suffix = MemberID.suffix(of: member.memberID)
            let links = (state.shares).filter { share in
                guard let origin = share.origin, let theirs = MemberID.suffix(of: origin), let mine = suffix else { return false }
                return mine == theirs && LinkState(raw: share.linkState) != .expired
            }
            let count = links.count
            let linkWord = "\(count) link\(count == 1 ? "" : "s")"
            let machine = links.compactMap(\.by).first ?? "\(name)'s machine"
            switch member.status {
            case "paused":
                out.append((1, line("\(member.name):paused", "\(name) is paused", count > 0 ? "\(linkWord) answer\(count == 1 ? "s" : "") 503" : "Their links answer 503", "pause.circle",
                                    .resumeMember(argv: ProfileArgs.argv(profile, ["member", "resume", member.name])))))
            case "left":
                out.append((2, line("\(member.name):left", "\(name) left", "Remove to close the tunnel and token", "rectangle.portrait.and.arrow.right", .remove(profile: profile, member: member.name))))
            case "expired":
                out.append((3, line("\(member.name):code", "\(name)'s code expired", "Send a new code", "clock.badge.xmark", .sendCode(argv: ProfileArgs.argv(profile, ["member", "invite", member.name])))))
            case "invited" where member.expired:
                out.append((3, line("\(member.name):code", "\(name)'s code expired", "Send a new code", "clock.badge.xmark", .sendCode(argv: ProfileArgs.argv(profile, ["member", "invite", member.name])))))
            case let status where member.isRunning:
                let stale = member.lease.map { !$0.live } ?? true
                guard stale, member.can.contains("finish"), let verb = finishVerb[status] else { break }
                let step = member.lease?.step ?? member.step
                let stopped = step.map { "stopped at step \($0)" } ?? "stopped"
                let progressive = MemberStatus(raw: status)?.stateWord.word ?? status.capitalized
                out.append((4, line("\(member.name):finish", "\(progressive) \(name) \(stopped)", "Finish continues from where it stopped", "arrow.clockwise",
                                    .finish(argv: ProfileArgs.argv(profile, ["member", verb, member.name])))))
            default:
                if member.mode == "machine", member.status == "active", !member.isOnline, count > 0 {
                    out.append((0, line("\(member.name):offline", "\(machine) is offline", "\(linkWord) answer\(count == 1 ? "s" : "") 503 until it is back", "moon",
                                        .open(profile: profile, member: member.name))))
                }
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }
}
