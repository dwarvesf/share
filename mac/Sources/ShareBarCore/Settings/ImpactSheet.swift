import Foundation

/// One line of a confirm: a cross for what stops, a check for what keeps working.
public struct ImpactLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case stops, keeps }
    public let kind: Kind
    public let text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

/// The one confirm sheet of the Share Bar (interactions doc 3b): a title, an optional body,
/// impact lines with real counts, Cancel and one action button (red ink when destructive).
public struct ImpactSheet: Sendable, Equatable {
    /// A pop-up inside the sheet (Remove member: what happens to their cloud links).
    public struct Choice: Sendable, Equatable {
        public let label: String
        public let options: [String]
    }

    public let title: String
    public let body: String?
    public let lines: [ImpactLine]
    public let choice: Choice?
    public let actionTitle: String
    public let destructive: Bool

    public init(title: String, body: String? = nil, lines: [ImpactLine] = [], choice: Choice? = nil, actionTitle: String, destructive: Bool = false) {
        self.title = title
        self.body = body
        self.lines = lines
        self.choice = choice
        self.actionTitle = actionTitle
        self.destructive = destructive
    }
}

/// Counts come from `share state` rows; the copy never holds a fixed number.
public enum Impact {
    private static func links(_ count: Int) -> String { count == 1 ? "1 link" : "\(count) links" }

    /// Rows that live on this Mac: `place` says `this Mac`, neither cloud nor another member's machine.
    public static func linksOnThisMac(_ shares: [Share]) -> Int {
        shares.filter { LinkView.place(of: $0) == "this Mac" }.count
    }

    /// Stop serving: this Mac's links stop; cloud and member links keep working.
    public static func stopServing(host: String, shares: [Share]) -> ImpactSheet {
        let here = linksOnThisMac(shares)
        let rest = shares.count - here
        var lines: [ImpactLine] = []
        if here > 0 {
            lines.append(ImpactLine(.stops, "\(links(here)) on this Mac \(here == 1 ? "stops" : "stop") answering until you start again"))
        } else {
            lines.append(ImpactLine(.stops, "Nothing on this Mac answers until you start again"))
        }
        if rest > 0 {
            lines.append(ImpactLine(.keeps, "\(rest) cloud and member \(rest == 1 ? "link keeps" : "links keep") working"))
        } else {
            lines.append(ImpactLine(.keeps, "Cloud and member links keep working"))
        }
        return ImpactSheet(title: "Stop serving \(host) from this Mac?", lines: lines, actionTitle: "Stop serving")
    }

    /// Pause: the member's machine links answer 503; their cloud links keep working.
    public static func pause(member: String, shares: [Share]) -> ImpactSheet {
        let lower = member.lowercased()
        let machine = shares.filter { share in
            guard let origin = share.origin, let name = MemberID.name(of: origin) else { return false }
            return name.lowercased() == lower
        }.count
        let cloud = shares.filter { $0.storage == "cloud" && ($0.by ?? "").lowercased() == lower }.count
        var lines: [ImpactLine] = []
        if machine > 0 {
            lines.append(ImpactLine(.stops, "\(links(machine)) on their computer \(machine == 1 ? "answers" : "answer") \"paused\" until you resume"))
        } else {
            lines.append(ImpactLine(.stops, "Links on their computer answer \"paused\" until you resume"))
        }
        lines.append(ImpactLine(.stops, "\(member) cannot add links while paused"))
        lines.append(ImpactLine(.keeps, cloud > 0 ? "Their \(links(cloud)) in the cloud \(cloud == 1 ? "keeps" : "keep") working" : "Their cloud links keep working"))
        return ImpactSheet(title: "Pause \(member)?", lines: lines, actionTitle: "Pause")
    }

    /// Remove member: their machine links stop, their tunnel and key are deleted, their files stay.
    public static func removeMember(member: String, shares: [Share]) -> ImpactSheet {
        let lower = member.lowercased()
        let machine = shares.filter { share in
            guard let origin = share.origin, let name = MemberID.name(of: origin) else { return false }
            return name.lowercased() == lower
        }.count
        let cloud = shares.filter { $0.storage == "cloud" && ($0.by ?? "").lowercased() == lower }.count
        return ImpactSheet(
            title: "Remove \(member)?",
            body: "Their machine links stop answering now. Their tunnel and key are deleted. Their files stay on their machine.",
            lines: [
                ImpactLine(.stops, machine > 0 ? "\(links(machine)) on their computer stop answering now" : "Their machine links stop answering now"),
                ImpactLine(.keeps, "Their files stay on their machine"),
            ],
            choice: ImpactSheet.Choice(label: cloud > 0 ? "Their cloud links (\(cloud))" : "Their cloud links", options: ["Keep until they expire", "Delete now"]),
            actionTitle: "Remove", destructive: true
        )
    }

    /// Rotate keys: the old keys stop now, the links keep their addresses, the member joins again with a new code.
    public static func rotate(member: String) -> ImpactSheet {
        ImpactSheet(
            title: "Rotate keys for \(member)?",
            body: "You get a new code to send them. They join again with it.",
            lines: [
                ImpactLine(.stops, "Their old keys stop working now"),
                ImpactLine(.keeps, "Their links keep the same addresses"),
            ],
            actionTitle: "Rotate keys"
        )
    }

    /// Renew key: extends the key by the CLI's default; nothing changes on their machine.
    public static func renew(member: String) -> ImpactSheet {
        ImpactSheet(
            title: "Renew \(member)'s key?",
            body: "Extends the key by 90 days. Nothing changes on their machine.",
            actionTitle: "Renew"
        )
    }

    /// Delete record: only a removed member has one; nothing of them is left to stop.
    public static func purge(member: String) -> ImpactSheet {
        ImpactSheet(
            title: "Delete \(member)'s record?",
            body: "\(member) is already removed. This deletes the record that remembers them. It cannot be undone.",
            actionTitle: "Delete record", destructive: true
        )
    }

    /// Turn on members: the CLI's own warning, shown before `--yes` is passed.
    public static func turnOnMembers(host: String) -> ImpactSheet {
        ImpactSheet(
            title: "Turn on members for \(host)?",
            body: "A share older than 0.10 still lists, adds and removes cloud links here, but never sees member links, and its orphan sweep is skipped.",
            actionTitle: "Turn on members"
        )
    }

    /// Roll back names its command.
    public static func rollBack(what: String, command: String) -> ImpactSheet {
        ImpactSheet(
            title: "Roll back \(what)?",
            body: "Runs \"\(command)\". The last step is undone and the earlier ones stay as they were.",
            actionTitle: "Roll back"
        )
    }

    /// The remove sheet of a tenant, per role (interactions doc 5).
    public static func removeTenant(_ detail: TenantDetail, shares: [Share]) -> ImpactSheet? {
        guard let removal = detail.removal else { return nil }
        let here = linksOnThisMac(shares)
        switch removal {
        case .refusedMembers:
            return nil
        case .teardown(let cloudKeeps):
            let body = cloudKeeps
                ? "Deletes the tunnel, the DNS record and this Mac's links. Cloud links keep answering from the bucket until they expire."
                : "Deletes the tunnel, the DNS record and this Mac's \(links(here)). Visitors get a Cloudflare error."
            return ImpactSheet(title: "Remove \(detail.host)?", body: body, actionTitle: "Remove", destructive: true)
        case .leave:
            return ImpactSheet(
                title: "Leave \(detail.host)?",
                body: "You leave \(detail.host). Your links stop answering and are removed from this Mac. The admin finishes the cloud side.",
                actionTitle: "Leave", destructive: true
            )
        case .cleanUp:
            return ImpactSheet(
                title: "Clean up \(detail.host)?",
                body: "Removes what is left of \(detail.host) on this Mac. Nothing on the team side changes.",
                actionTitle: "Clean up", destructive: true
            )
        }
    }

    /// The refusal for a tenant that has members (gap G6, DEC-49): shown before anything runs.
    public static func refusedMembers(host: String) -> RefusalSheet {
        RefusalSheet(
            title: "Can't remove \(host) yet",
            sentence: "\(host) has members. Remove every member first; then this Mac can remove the tenant.",
            next: "Open Members",
            action: .openMembers
        )
    }
}

/// The refusal sheet: the CLI's sentence and its next action as a button.
public struct RefusalSheet: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case openMembers
        case copyCommand(String)
        case none
    }

    public let title: String
    public let sentence: String
    /// The button label; nil when the refusal has no next action.
    public let next: String?
    public let action: Action

    /// A CLI refusal by its stable code. `members_present` maps to the members refusal; any
    /// other code shows its sentence and, when it names one, the next command to copy.
    public static func from(code: String, message: String, next: String?, host: String) -> RefusalSheet {
        if code == "members_present" { return Impact.refusedMembers(host: host) }
        if let known = knownJoinOrMember(code: code, message: message) { return known }
        if let next, !next.isEmpty {
            return RefusalSheet(title: "Can't do that", sentence: message, next: "Copy command", action: .copyCommand(Redact.tokenShaped(next)))
        }
        return RefusalSheet(title: "Can't do that", sentence: message, next: nil, action: .none)
    }
}

extension RefusalSheet {
    /// The codes SPEC-009 maps to a sheet beyond `members_present`: a member verb refused for a
    /// verb still running, a CLI below the Worker's minimum, and the join table of
    /// `share-bar-interactions.md` 2a. Each reads as a sentence plus the way through.
    static func knownJoinOrMember(code: String, message: String) -> RefusalSheet? {
        let ask = "Ask your admin for a new code."
        switch code {
        case "member_busy":
            return RefusalSheet(title: "Still working", sentence: message.isEmpty ? "Another change to this member is still running. Wait for it to finish, or press Finish in Members." : message,
                                next: "Open Members", action: .openMembers)
        case "cli_below_min":
            return RefusalSheet(title: "Update share to \(AppState.defaultMinimum)", sentence: message.isEmpty ? "This share command is older than the team's server allows." : message,
                                next: "Copy upgrade command", action: .copyCommand(AppState.upgradeCommand))
        case "invite_unknown_or_used":
            return RefusalSheet(title: "Can't join", sentence: "This code was already used, or it does not exist. \(ask)", next: nil, action: .none)
        case "invite_expired":
            return RefusalSheet(title: "Can't join", sentence: "This code expired. \(ask)", next: nil, action: .none)
        case "invite_tampered":
            return RefusalSheet(title: "Can't join", sentence: "This code was changed on the way. \(ask)", next: nil, action: .none)
        case "member_changed":
            return RefusalSheet(title: "Can't join", sentence: "The admin changed your invite. \(ask)", next: nil, action: .none)
        case "invite_unavailable":
            return RefusalSheet(title: "Can't join", sentence: "The invite is not available right now. \(ask)", next: nil, action: .none)
        default:
            return nil
        }
    }
}

/// The code sheet: the code once, Copy code, Done.
public struct CodeSheet: Sendable, Equatable {
    public let title: String
    public let body: String
    public let code: String
    public let note = "Share Bar shows the code only now. If it is lost, send a new one."

    public init(member: String, code: String, rotate: Bool, ttlDays: Int) {
        title = rotate ? "New keys for \(member)" : "Invite code for \(member)"
        body = rotate
            ? "Old keys stop working now. Their links keep the same addresses. They join again with this code."
            : "Send this to \(member). It works once, for \(ttlDays == 1 ? "1 day" : "\(ttlDays) days")."
        self.code = code
    }
}

/// The invite sheet's choices (SPEC-009 TASK-4b16): name, where links live, code expiry.
public struct InviteForm: Sendable, Equatable {
    public enum Mode: String, Sendable, Equatable, CaseIterable {
        case machine, cloud

        public var title: String { self == .machine ? "On their computer" : "In the cloud" }
        public var detail: String {
            self == .machine
                ? "Files stay on their machine. Links answer while it is on."
                : "Uploaded to the team bucket. Links answer any time."
        }
    }

    public static let ttlChoices = [1, 7, 30]

    public var name = ""
    public var mode: Mode = .machine
    public var ttlDays = 7

    public init() {}

    /// A member name reaches argv: letters, digits and `-` or `_`, never a leading dash.
    public var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.count <= 32 && !trimmed.hasPrefix("-")
            && trimmed.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }

    /// The code `member add` prints on its one `share join <host> <code>` line.
    public static func code(fromStdout stdout: String) -> String? {
        for line in stdout.split(separator: "\n").reversed() {
            let words = line.split(separator: " ").map(String.init)
            if words.count >= 4, words[0] == "share", words[1] == "join" { return words[3] }
        }
        return nil
    }

    /// `member add <name> --machine|--cloud --invite-ttl <n>d`
    public func argv(profile: String) -> [String]? {
        guard isValid, Self.ttlChoices.contains(ttlDays) else { return nil }
        return ProfileArgs.argv(profile, ["member", "add", name.trimmingCharacters(in: .whitespaces), "--\(mode.rawValue)", "--invite-ttl", "\(ttlDays)d"])
    }
}
