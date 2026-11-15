import Foundation

/// A verb of the Members row menu. The CLI's `can[]` decides which ones a member has (DEC-53);
/// this type only names them, orders them and builds the argv.
public enum MemberVerb: String, CaseIterable, Sendable {
    case finish, resume, pause, invite, rotate, renew, rm, purge

    /// The menu title. `finish` reads "Finish pausing" and so on from the running status.
    public func title(status: String) -> String {
        switch self {
        case .finish:
            let word = MemberStatus(raw: status)?.stateWord.word.lowercased() ?? "the verb"
            return "Finish \(word)"
        case .resume: return "Resume"
        case .pause: return "Pause…"
        case .invite: return "Send a new code"
        case .rotate: return "Rotate keys…"
        case .renew: return "Renew key…"
        case .rm: return "Remove…"
        case .purge: return "Delete record"
        }
    }

    /// The destructive item sits last, after a separator.
    public var isDestructive: Bool { self == .rm || self == .purge }
}

/// The Members filter control: All, Needs a look, Removed, each with its count.
public enum MemberFilter: String, CaseIterable, Sendable {
    case all, needsLook, removed

    public var title: String {
        switch self {
        case .all: return "All"
        case .needsLook: return "Needs a look"
        case .removed: return "Removed"
        }
    }
}

public struct MemberChip: Sendable, Equatable {
    public enum Tone: Sendable, Equatable { case info, quiet, attention }
    public let text: String
    public let tone: Tone
}

/// One row of the Members list (`### Components & states`): initials, name, a sub line, a
/// status chip or the presence word, the link count and the row menu.
public struct MemberRowModel: Sendable, Equatable, Identifiable {
    public var id: String { memberID }
    public let memberID: String
    public let name: String
    public let initials: String
    public let subLine: String
    /// A chip for Invited, Paused, Removed, Left and a running or stopped verb; nil for an
    /// active member, who shows `presence` instead.
    public let chip: MemberChip?
    /// `Online` or `Offline` for an active machine or cloud member with no chip.
    public let presence: String?
    public let isOnline: Bool
    public let linkCount: Int
    public let menu: [MemberVerb]
    public let status: String

    public var linkText: String { linkCount == 0 ? "" : (linkCount == 1 ? "1 link" : "\(linkCount) links") }

    /// What VoiceOver reads: the name, then what the row shows.
    public var accessibilityLabel: String {
        var parts = [name, subLine]
        if let chip { parts.append(chip.text) } else if let presence { parts.append(presence) }
        if linkCount > 0 { parts.append(linkText) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// The Members tab's list model: pure, so a swift row covers every filter, count and menu.
public struct MembersModel: Sendable, Equatable {
    public let filter: MemberFilter
    public let query: String
    public let rows: [MemberRowModel]
    public let counts: [MemberFilter: Int]
    /// The sentence shown instead of rows.
    public let emptyText: String?

    public init(members: [MemberRecord], shares: [Share], filter: MemberFilter, query: String, now: Date = Date()) {
        self.filter = filter
        self.query = query
        let built = members.filter { !$0.name.isEmpty }.map { Self.row(for: $0, shares: shares, now: now) }
        let pairs = zip(members.filter { !$0.name.isEmpty }, built).map { ($0, $1) }
        let removed = pairs.filter { $0.0.status == "removed" }
        let live = pairs.filter { $0.0.status != "removed" }
        counts = [
            .all: live.count,
            .needsLook: pairs.filter { Self.needsLook($0.0, links: $0.1.linkCount) }.count,
            .removed: removed.count,
        ]
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        var chosen: [(MemberRecord, MemberRowModel)]
        switch filter {
        case .all: chosen = live
        case .needsLook: chosen = pairs.filter { Self.needsLook($0.0, links: $0.1.linkCount) }
        case .removed: chosen = removed
        }
        if !needle.isEmpty { chosen = chosen.filter { $0.0.name.lowercased().contains(needle) } }
        rows = chosen.map(\.1)
        if rows.isEmpty {
            emptyText = !needle.isEmpty ? "No members match."
                : filter == .needsLook ? "Nobody needs a look." : filter == .removed ? "No removed members." : "No members yet. Invite the first one."
        } else {
            emptyText = nil
        }
    }

    // MARK: row

    static func row(for member: MemberRecord, shares: [Share], now: Date) -> MemberRowModel {
        let name = display(member.name)
        let links = linkCount(of: member, in: shares)
        let stale = member.isRunning && (member.lease.map { !$0.live } ?? true)
        let machine = machineName(of: member, shares: shares, fallback: name)
        let chip: MemberChip?
        var presence: String?
        switch member.status {
        case "invited": chip = MemberChip(text: member.expired ? "Code expired" : "Invited", tone: member.expired ? .attention : .info)
        case "paused": chip = MemberChip(text: "Paused", tone: .quiet)
        case "left": chip = MemberChip(text: "Left", tone: .attention)
        case "removed": chip = MemberChip(text: "Removed", tone: .quiet)
        case "expired": chip = MemberChip(text: "Code expired", tone: .attention)
        case "invalid": chip = MemberChip(text: "Unreadable", tone: .attention)
        default:
            if member.isRunning {
                chip = MemberChip(text: stale ? "Stopped" : MemberStatus(raw: member.status)?.stateWord.word ?? member.status, tone: .attention)
            } else {
                chip = nil
                presence = member.mode == "cloud" ? "Online" : (member.isOnline ? "Online" : "Offline")
            }
        }
        return MemberRowModel(
            memberID: member.memberID, name: name, initials: String(name.prefix(2)),
            subLine: subLine(member, machine: machine, stale: stale, now: now),
            chip: chip, presence: presence, isOnline: member.isOnline, linkCount: links,
            menu: menu(for: member), status: member.status
        )
    }

    public static func display(_ name: String) -> String { name.prefix(1).uppercased() + name.dropFirst() }

    /// The machine a member publishes from: the `by` of one of their links, else `<Name>'s machine`.
    static func machineName(of member: MemberRecord, shares: [Share], fallback: String) -> String {
        if member.mode == "cloud" { return "cloud only" }
        let suffix = MemberID.suffix(of: member.memberID)
        let by = shares.first { share in
            guard let origin = share.origin, let theirs = MemberID.suffix(of: origin) else { return false }
            return theirs == suffix
        }?.by
        return by ?? "\(fallback)'s machine"
    }

    static func linkCount(of member: MemberRecord, in shares: [Share]) -> Int {
        guard let mine = MemberID.suffix(of: member.memberID) else { return 0 }
        return shares.filter { share in
            guard let origin = share.origin, let theirs = MemberID.suffix(of: origin) else { return false }
            return theirs == mine && LinkState(raw: share.linkState) != .expired
        }.count
    }

    /// The second line: a code expiry, the step of a running verb, "left", or the machine
    /// (with "offline" when it is not connected).
    static func subLine(_ member: MemberRecord, machine: String, stale: Bool, now: Date) -> String {
        if member.status == "invited" || member.status == "expired" {
            if member.expired { return "code expired" }
            if let seconds = member.inviteExpires {
                let left = seconds - Int(now.timeIntervalSince1970)
                if left > 0 { return "code expires in \(max(1, left / 86_400))d" }
                return "code expired"
            }
            return "waiting for them to join"
        }
        if member.isRunning {
            let verb = (MemberStatus(raw: member.status)?.stateWord.word ?? member.status).lowercased()
            let step = member.lease?.step ?? member.step
            let position = step.map { s in member.of.map { "step \(s) of \($0)" } ?? "step \(s)" }
            if stale { return position.map { "\(verb) stopped at \($0)" } ?? "\(verb) stopped" }
            let word = member.stepName.map { " (\($0))" } ?? ""
            let head = verb.prefix(1).uppercased() + verb.dropFirst()
            return position.map { "\(head), \($0)\(word)" } ?? head
        }
        if member.status == "left" { return "left, \(machine)" }
        if member.status == "removed" { return machine }
        if member.mode == "machine", !member.isOnline, member.status == "active" { return "\(machine) · offline" }
        return machine
    }

    // MARK: menu and filters

    /// The verbs `member ls --json` reports in `can[]`, in the menu's order; a verb this app does
    /// not know (add, adopt, join, leave, sync) never shows. Never mirrors the CLI's table.
    public static func menu(for member: MemberRecord) -> [MemberVerb] {
        let allowed = Set(member.can)
        return MemberVerb.allCases.filter { allowed.contains($0.rawValue) }
    }

    /// Needs a look: a paused, left or expired-code member, a verb stopped half way, or an
    /// active machine member that is offline while links depend on it.
    public static func needsLook(_ member: MemberRecord, links: Int) -> Bool {
        switch member.status {
        case "paused", "left", "expired", "invalid": return true
        case "invited": return member.expired
        case "removed": return false
        default:
            if member.isRunning { return true }
            return member.mode == "machine" && member.status == "active" && !member.isOnline && links > 0
        }
    }

    // MARK: argv

    /// The CLI call a menu item runs. `finish` reruns the verb its `...ing` status stopped on.
    /// A name starting with `-` never becomes an argument (nil).
    public static func argv(_ verb: MemberVerb, member: MemberRecord, profile: String) -> [String]? {
        guard !member.name.hasPrefix("-"), !member.name.isEmpty, !profile.isEmpty else { return nil }
        let real: String
        switch verb {
        case .finish:
            guard let rerun = IssueList.finishVerb[member.status] ?? member.lease?.verb, rerun != "add" else { return nil }
            real = rerun
        default: real = verb.rawValue
        }
        return ProfileArgs.argv(profile, ["member", real, member.name])
    }

    /// `share member ls --json` for a profile.
    public static func listArgv(profile: String) -> [String] { ProfileArgs.argv(profile, ["member", "ls", "--json"]) }

    /// The sentence shown in place of the list when `member ls` fails (never the raw exit code).
    public static func failureSentence(_ result: CLIResult) -> String {
        if let error = ErrorLine.last(inStderr: result.stderr) { return error.message }
        guard !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Couldn't read the members. Try again, or run share member ls."
        }
        let line = result.lastErrorLine
        return line.hasPrefix("share: ") ? String(line.dropFirst(7)) : line
    }
}
