import Foundation

/// What a tenant's status word looks like: a dot, a spinner, or a quiet or attention mark.
public enum TenantStatusTone: Sendable, Equatable {
    case ok, spinner, quiet, attention
}

public struct TenantStatus: Sendable, Equatable {
    public let word: String
    public let tone: TenantStatusTone
}

/// Every button the Tenants detail can offer. Which ones show is `TenantDetail.actions`,
/// the table of interactions doc section 5.
public enum TenantAction: String, Sendable, Equatable, CaseIterable {
    case start, stop, turnOnCloud, turnOnMembers, resume, rollBack, openInBrowser, copyRequest, cleanUp

    public var title: String {
        switch self {
        case .start: return "Start serving"
        case .stop: return "Stop serving"
        case .turnOnCloud: return "Turn on cloud storage…"
        case .turnOnMembers: return "Turn on members…"
        case .resume: return "Resume"
        case .rollBack: return "Roll back"
        case .openInBrowser: return "Open in browser"
        case .copyRequest: return "Copy request"
        case .cleanUp: return "Clean up"
        }
    }
}

/// A member's or owner's situation that replaces the detail's ordinary buttons.
public enum TenantBanner: Sendable, Equatable {
    /// The member's own record reads `removed` (DEC-47): Clean up runs `leave --local`.
    case removed(host: String)
    /// `token.status` is `expired`: copy a request for the admin, never Clean up (DEC-79).
    case keyExpired
    /// `token.status` is `invalid` (a 401): the same, never Clean up (DEC-79).
    case keyInvalid

    public var text: String {
        switch self {
        case .removed(let host): return "You were removed from \(host)"
        case .keyExpired: return "Your key expired; ask the admin to renew it"
        case .keyInvalid: return "Your key stopped working; ask the admin"
        }
    }

    public var detail: String? {
        switch self {
        case .removed: return "Your links stopped answering. Clean up removes what is left on this Mac."
        case .keyExpired, .keyInvalid: return "Copy request puts a note for your admin on the clipboard."
        }
    }
}

/// The interrupted-command callout: a journal whose process died.
public struct TenantCallout: Sendable, Equatable {
    public let title: String
    public let detail: String
    public let op: OpInfo
    public let canResume: Bool
    public let canRollBack: Bool
}

/// What the minus button does for this tenant (interactions doc section 5, second table).
public enum TenantRemoval: Sendable, Equatable {
    /// Owner or admin of a tenant with no members: `teardown --yes`.
    case teardown(cloudLinksKeepAnswering: Bool)
    /// An active member: `leave`.
    case leave
    /// A removed member: `leave --local`.
    case cleanUp
    /// An admin of a T2 tenant: refused before anything runs (DEC-49).
    case refusedMembers

    /// The argv this removal runs after the impact sheet; nil when it is refused.
    public func argv(profile: String) -> [String]? {
        switch self {
        case .teardown: return ProfileArgs.argv(profile, ["teardown", "--yes"])
        case .leave: return ProfileArgs.argv(profile, ["leave"])
        case .cleanUp: return ProfileArgs.argv(profile, ["leave", "--local"])
        case .refusedMembers: return nil
        }
    }
}

public enum TenantRoleWord {
    /// D13: `origin` is Owner; `tenant_origin` and `r2_profile` are Admin, as the prototype words them.
    public static func word(role: Role, tier: String?) -> String {
        switch role {
        case .origin, .quick: return "Owner"
        case .tenantOrigin, .r2Profile: return "Admin"
        case .member: return "Member"
        case .migrated: return "Moved"
        case .unset, .unknown: return "No role"
        }
    }
}

/// The detail panel of one tenant, derived from the CLI's keys only. It never classifies
/// state beyond reading them: `role`, `tier`, `serve.phase`, `ops`, `member.status`,
/// `token.status`.
public struct TenantDetail: Sendable, Equatable {
    public let profile: String
    public let host: String
    public let role: Role
    public let roleWord: String
    public let status: TenantStatus
    public let storage: String
    /// `On` or `Off`; nil for a member, who never sees the row.
    public let members: String?
    public let servedFrom: String
    public let key: String?
    public let banner: TenantBanner?
    public let callout: TenantCallout?
    public let actions: [TenantAction]
    public let removal: TenantRemoval?
    public let tier: String?
    public let phase: String?

    /// The source-list line under the host: `<role> · <status word>`.
    public let listLine: String
    /// The needs-a-look dot of the source list.
    public let needsLook: Bool

    public init?(entry: ProfileEntry, adminKeyLabel: String = "Asks each time") {
        guard entry.error == nil, let state = entry.state, state.schema <= 1 else { return nil }
        let role = Role(raw: state.role)
        guard role != .unset else { return nil }
        let view = ProfileView(entry: entry)
        profile = entry.name
        host = state.host ?? state.member?.name ?? entry.name
        self.role = role
        tier = state.tier
        phase = state.serve?.phase
        roleWord = TenantRoleWord.word(role: role, tier: state.tier)

        let isMember = role == .member
        let phaseName = state.serve?.phase
        let tone: TenantStatusTone
        switch phaseName {
        case "serving": tone = .ok
        case "starting": tone = .spinner
        case "failed", "tunnel_down", "worker_down": tone = .attention
        default: tone = .quiet
        }
        status = TenantStatus(word: view.serveSentence, tone: tone)

        let cloud = state.r2 == true || state.tier == "t1" || state.tier == "t2"
        storage = cloud ? "This Mac and the cloud" : "This Mac only"
        members = isMember ? nil : (state.tier == "t2" ? "On" : "Off")
        if state.state != "serving", !state.servesHere, role != .r2Profile {
            servedFrom = "Another Mac: \(state.hosts)"
        } else if role == .r2Profile {
            servedFrom = "The cloud"
        } else {
            servedFrom = "\(state.hosts) (this Mac)"
        }
        key = TenantDetail.keyLine(state: state, isMember: isMember, adminKeyLabel: adminKeyLabel)

        // The op whose process died: a live one is another process's work, shown in the footer.
        let dead = (state.ops ?? []).first { $0.aliveKnown && !$0.alive }
        if let op = dead {
            callout = TenantCallout(
                title: TenantDetail.calloutTitle(op),
                detail: TenantDetail.calloutDetail(op),
                op: op,
                canResume: JournalRun.argv(op: op, kind: .rerun, profile: entry.name) != nil,
                canRollBack: JournalRun.argv(op: op, kind: .rollback, profile: entry.name) != nil
            )
        } else {
            callout = nil
        }

        let memberStatus = state.member?.status
        let tokenStatus = state.token?.status
        if isMember, memberStatus == "removed" {
            banner = .removed(host: host)
        } else if isMember, tokenStatus == "expired" {
            banner = .keyExpired
        } else if isMember, tokenStatus == "invalid" {
            banner = .keyInvalid
        } else {
            banner = nil
        }

        removal = TenantDetail.removal(role: role, tier: state.tier, memberStatus: memberStatus)

        var buttons: [TenantAction] = []
        let runsHere = role.isOrigin || (isMember && state.member?.mode != "cloud")
        if callout != nil {
            if callout?.canResume == true { buttons.append(.resume) }
            if callout?.canRollBack == true { buttons.append(.rollBack) }
        }
        if banner == nil, runsHere {
            if phaseName == "stopped" || phaseName == "failed" { buttons.append(.start) }
            if phaseName == "serving" || phaseName == "starting" || phaseName == "tunnel_down" { buttons.append(.stop) }
        }
        if callout == nil, role.isOrigin, state.tier == "t0" { buttons.append(.turnOnCloud) }
        if callout == nil, role == .tenantOrigin, state.tier == "t1" { buttons.append(.turnOnMembers) }
        switch banner {
        case .removed?: buttons.append(.cleanUp)
        case .keyExpired?, .keyInvalid?: buttons.append(.copyRequest)
        case nil: if isMember { buttons.append(.copyRequest) }
        }
        if state.host != nil { buttons.append(.openInBrowser) }
        actions = buttons

        let word: String
        if dead != nil { word = "Interrupted" } else if phaseName == "failed" { word = "Stopped" } else { word = TenantDetail.listWord(phase: phaseName, fallback: view.serveSentence) }
        listLine = "\(roleWord) · \(word)"
        needsLook = dead != nil || phaseName == "failed" || banner != nil
    }

    private static func listWord(phase: String?, fallback: String) -> String {
        switch phase {
        case "serving": return "Serving"
        case "starting": return "Starting"
        case "stopped": return "Stopped"
        case "tunnel_down": return "Tunnel not connected"
        case "worker_down": return "Worker not answering"
        case "elsewhere": return "Elsewhere"
        default: return fallback
        }
    }

    private static func keyLine(state: Snapshot, isMember: Bool, adminKeyLabel: String) -> String? {
        guard isMember else { return "Admin key: \(adminKeyLabel)" }
        guard let token = state.token else { return nil }
        var parts: [String] = []
        switch token.source {
        case "keychain": parts.append("Keychain")
        case "file": parts.append("A file on this Mac")
        case "env": parts.append("The environment")
        case "cmd": parts.append("A command")
        case let other?: parts.append(other.capitalized)
        case nil: break
        }
        switch token.status {
        case "expired": parts.append("expired")
        case "invalid": parts.append("stopped working")
        default:
            if let on = token.expiresOn { parts.append("expires \(on)") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func removal(role: Role, tier: String?, memberStatus: String?) -> TenantRemoval? {
        switch role {
        case .member:
            return memberStatus == "removed" ? .cleanUp : .leave
        case .tenantOrigin where tier == "t2", .r2Profile where tier == "t2":
            return .refusedMembers
        case .origin, .tenantOrigin, .r2Profile, .quick:
            return .teardown(cloudLinksKeepAnswering: tier == "t1")
        case .migrated:
            return .cleanUp
        case .unset, .unknown:
            return nil
        }
    }

    private static func calloutTitle(_ op: OpInfo) -> String {
        let place = op.step.map { s in op.of.map { "step \(s) of \($0)" } ?? "step \(s)" } ?? "a step"
        switch op.verb {
        case "join": return "Joining stopped at \(place)"
        case "setup-r2": return "Cloud storage setup stopped at \(place)"
        case "setup-members": return "Turning on members stopped at \(place)"
        case "setup-tunnel": return "Setup stopped at \(place)"
        default: return "\(op.verb.replacingOccurrences(of: "-", with: " ").capitalized) stopped at \(place)"
        }
    }

    private static func calloutDetail(_ op: OpInfo) -> String {
        let named = op.name.map { "The \(StepCopy.short(verb: op.verb, name: $0)) step did not finish. " } ?? ""
        switch op.verb {
        case "setup-r2": return named + "Resume continues from there; Roll back undoes the cloud storage change."
        case "setup-members": return named + "Resume continues from there."
        case "join": return named + "Resume continues from there; Roll back leaves this tenant and cleans up this Mac."
        default: return named + "Resume continues from there."
        }
    }
}

/// The source list of the Tenants tab: every profile that has a role, set up or not.
public enum TenantList {
    public static func entries(_ profiles: ProfilesSnapshot?) -> [ProfileEntry] {
        (profiles?.profiles ?? []).filter { entry in
            guard entry.error == nil, let state = entry.state else { return false }
            return Role(raw: state.role) != .unset
        }
    }
}
