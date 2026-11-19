import Foundation

/// `state.role` (SPEC-010 G3). An older CLI prints none of it, and a value this app does
/// not know reads as `.unknown`; both fall back to today's derivation.
public enum Role: Sendable, Equatable {
    case unset, quick, origin, tenantOrigin, r2Profile, member, migrated
    case unknown

    public init(raw: String?) {
        switch raw {
        case "none": self = .unset
        case "quick": self = .quick
        case "origin": self = .origin
        case "tenant_origin": self = .tenantOrigin
        case "r2_profile": self = .r2Profile
        case "member": self = .member
        case "migrated": self = .migrated
        default: self = .unknown
        }
    }

    /// True for the roles that run a tenant: the admin's origin, with or without R2.
    public var isOrigin: Bool { self == .origin || self == .tenantOrigin }
}

/// The serve sentence (G6): `serve.phase` read as copy. Pure display; the classification
/// stays the CLI's.
public enum ServeSentence {
    /// The `Health` a phase implies, so a `serve` that contradicts `state`/`ready` is not
    /// trusted over them.
    static func health(forPhase phase: String) -> Health? {
        switch phase {
        case "serving": return .ok
        case "starting", "tunnel_down", "worker_down": return .tunnelDown
        case "stopped", "failed": return .stopped
        case "elsewhere": return .elsewhere
        case "not_setup": return .notSetUp
        default: return nil
        }
    }

    /// The copy for a known phase that agrees with `health`; nil otherwise, which sends
    /// the caller to today's derivation (SB-02).
    public static func text(of state: Snapshot, health: Health) -> String? {
        guard let serve = state.serve, Self.health(forPhase: serve.phase) == health else { return nil }
        switch serve.phase {
        case "serving": return "Serving"
        case "starting": return "Starting…"
        case "tunnel_down": return "Tunnel not connected"
        case "worker_down": return "Worker not answering"
        case "stopped": return "Stopped"
        case "failed": return "Stopped: \(reasonCopy(serve.reason))"
        case "elsewhere": return "Not serving on this Mac (hosts=\(state.hosts))"
        default: return "Not set up"
        }
    }

    /// `.serve-exit` codes the CLI records; any other code reads as itself with the
    /// underscores opened, so an unknown reason is still a sentence.
    static func reasonCopy(_ reason: String?) -> String {
        switch reason {
        case "cloudflared_died": return "the tunnel process exited"
        case "caddy_failed": return "the web server failed"
        case let code? where !code.isEmpty:
            let words = code.replacingOccurrences(of: "_", with: " ")
            return words.filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { $0.value >= 32 } }
        default: return "it exited"
        }
    }
}

/// Whether a profile can take an `add`, and why not.
public enum PublishEligibility: Sendable, Equatable {
    case eligible
    /// `reason` is the sentence the dialog and the menu show; `neutral` marks a state that
    /// is not a fault (a profile that moved to another machine).
    case ineligible(reason: String, neutral: Bool)

    public var isEligible: Bool { self == .eligible }
}

/// One profile as the popover and the menu read it: the serve sentence, the role, and
/// whether it can publish with the reason. Every field comes from the CLI's keys when
/// they are present and from today's rules when they are not (SPEC-009 TASK-4b rule).
public struct ProfileView: Sendable, Equatable {
    public let name: String
    public let role: Role
    public let health: Health
    /// The one-line serving status.
    public let serveSentence: String
    public let publish: PublishEligibility

    public init(entry: ProfileEntry) {
        name = entry.name
        health = Health.of(entry)
        serveSentence = Health.statusText(of: entry)
        guard entry.error == nil, let state = entry.state, state.schema <= 1 else {
            role = .unknown
            publish = .ineligible(reason: serveSentence, neutral: false)
            return
        }
        let role = Role(raw: state.role)
        self.role = role
        publish = ProfileView.eligibility(state: state, role: role, health: health, sentence: serveSentence)
    }

    /// First match wins: the role, then the member's own status, then the key, then the
    /// compat check; with none of those keys, today's rule (`stopped` or `serving`).
    static func eligibility(state: Snapshot, role: Role, health: Health, sentence: String) -> PublishEligibility {
        if role == .migrated {
            return .ineligible(reason: "Moved to another machine", neutral: true)
        }
        let host = state.host ?? state.member?.name ?? "this tenant"
        switch state.member?.status {
        case "paused": return .ineligible(reason: "This member is paused: ask an admin to resume you.", neutral: false)
        case "left": return .ineligible(reason: "You left \(host).", neutral: true)
        case "removed": return .ineligible(reason: "You were removed from \(host).", neutral: false)
        default: break
        }
        let isMember = role == .member
        switch state.token?.status {
        case "expired":
            return .ineligible(
                reason: isMember ? "Your key expired; ask the admin to renew it." : "The stored key expired; run handout api-token.",
                neutral: false
            )
        case "invalid":
            return .ineligible(
                reason: isMember ? "Your key stopped working; ask the admin." : "Cloudflare rejected the stored key; run handout api-token.",
                neutral: false
            )
        default: break
        }
        if state.compat?.status == "cli_below_min" {
            let min = state.compat?.minCLI.map { " to \($0)" } ?? ""
            return .ineligible(reason: "Upgrade share\(min); \(host) requires it.", neutral: false)
        }
        if state.state == "stopped" || state.state == "serving" { return .eligible }
        return .ineligible(reason: sentence, neutral: health.isNeutral)
    }
}

/// Which links the popover lists: the viewer's own, or the whole team's.
public enum LinkScope: Sendable, Equatable {
    case mine, team
}

/// One link row's text, built from a `Share`: the meta line of `### Components & states`.
public struct LinkView: Sendable, Equatable {
    public let id: String
    public let title: String
    public let state: LinkState
    /// The meta line, pieces joined with ` · `.
    public let meta: String
    /// The state word when the link does not answer, else nil.
    public let stateWord: String?

    public init(share: Share, scope: LinkScope = .mine, now: Date = Date()) {
        id = share.id
        title = share.ownHost ?? share.name
        state = LinkState(raw: share.linkState)
        var pieces: [String] = []
        if scope == .team, let owner = LinkView.owner(of: share) { pieces.append(owner) }
        if let place = LinkView.place(of: share) { pieces.append(place) }
        // A clock past `expires` is the fallback for a CLI with no `link_state`.
        let lapsed = share.linkState == nil && share.kind != "live" && share.expires != 0
            && share.expires <= Int(now.timeIntervalSince1970)
        if !state.answers || lapsed {
            let word = lapsed ? LinkState.expired.stateWord.word : state.stateWord.word
            stateWord = word
            pieces.append(word)
        } else {
            stateWord = nil
            if let left = LinkView.timeLeft(of: share, now: now) { pieces.append(left) }
        }
        if share.storage == "cloud", let views = share.views {
            pieces.append(views == 1 ? "1 view" : "\(views) views")
        }
        meta = pieces.joined(separator: " · ")
    }

    /// The publisher: a member row's member name, else the `by` the CLI printed.
    static func owner(of share: Share) -> String? {
        if let origin = share.origin, let name = MemberID.name(of: origin) { return name }
        guard let by = share.by, !by.isEmpty else { return nil }
        return by
    }

    /// `cloud`, `<member>'s machine` for a v:3 row (DEC-40), else `this Mac`; nil when the
    /// CLI predates per-link storage.
    static func place(of share: Share) -> String? {
        if share.storage == "cloud" { return "cloud" }
        if let origin = share.origin, let name = MemberID.name(of: origin) { return "\(name)'s machine" }
        return share.storage == nil ? nil : "this Mac"
    }

    /// Time left in the largest whole unit; nothing for a link that never expires;
    /// `live server` for a port share.
    static func timeLeft(of share: Share, now: Date) -> String? {
        if share.kind == "live" { return "live server" }
        if share.expires == 0 { return nil }
        let remaining = secondsLeft(share.expires, now: now)
        if remaining <= 0 { return "expired" }
        if remaining >= 86_400 { return "\(remaining / 86_400)d left" }
        if remaining >= 3_600 { return "\(remaining / 3_600)h left" }
        return "\(max(1, remaining / 60))m left"
    }
}

/// The member id `m-<name>-<8 hex>` the CLI stores in a row's `origin`.
public enum MemberID {
    /// The display name, or nil when `id` is not a member id.
    public static func name(of id: String) -> String? {
        guard id.hasPrefix("m-") else { return nil }
        let body = id.dropFirst(2)
        guard let dash = body.lastIndex(of: "-") else { return nil }
        let suffix = body[body.index(after: dash)...]
        guard suffix.count == 8, suffix.allSatisfy(\.isHexDigit) else { return nil }
        let name = body[..<dash]
        return name.isEmpty ? nil : String(name)
    }

    /// The last 8 hex, the key the members cache matches by (DEC-71).
    public static func suffix(of id: String) -> String? {
        guard name(of: id) != nil else { return nil }
        return String(id.suffix(8))
    }
}
