import Foundation

/// Which status-item icon a `MenuModel` calls for. AppKit picks the actual `NSImage`
/// (template SF Symbols); this only names the two states the model can tell apart.
public enum Icon: Sendable, Equatable {
    case connected // antenna.radiowaves.left.and.right: serving and ready
    case disconnected // antenna.radiowaves.left.and.right.slash: anything else
}

/// One profile's condition for the menu, first matching rule of the spec's table wins.
public enum Health: Sendable, Equatable {
    case ok // serving and ready
    case tunnelDown // serving but not ready
    case stopped // deliberately stopped
    case error // an `error` entry, or a `state` the app could not read
    case elsewhere // set up but serving from another Mac
    case notSetUp // never set up (checked before `elsewhere`: an unset profile reports serves_here false)

    /// `stopped`, `tunnelDown`, and `error` need operator attention; `elsewhere` and
    /// `notSetUp` are neutral and never slash the icon on their own.
    public var isAttention: Bool {
        switch self {
        case .stopped, .tunnelDown, .error: return true
        case .ok, .elsewhere, .notSetUp: return false
        }
    }

    public var isNeutral: Bool { !isAttention && self != .ok }

    /// The classification table, evaluated in order.
    public static func of(_ entry: ProfileEntry) -> Health {
        if entry.error != nil { return .error }
        guard let state = entry.state, state.schema <= 1 else { return .error }
        if state.state == "not_setup" { return .notSetUp }
        if state.state != "serving", !state.servesHere { return .elsewhere }
        if state.state == "stopped" { return .stopped }
        if state.state == "serving" { return state.ready ? .ok : .tunnelDown }
        return .error
    }

    /// The status text the section title and the `Needs attention` header show.
    public static func statusText(of entry: ProfileEntry) -> String {
        switch of(entry) {
        case .error:
            // "Error: Update Share Bar" reads oddly, so that one text stands alone.
            if let error = entry.error, error == "Update Share Bar" { return error }
            return "Error: \(entry.error ?? "state not readable")"
        case .notSetUp: return "Not set up"
        case .elsewhere: return "Not serving on this Mac (hosts=\(entry.state?.hosts ?? ""))"
        case .stopped: return "Stopped"
        case .tunnelDown: return "Tunnel not connected"
        case .ok: return "Serving"
        }
    }
}

/// What a running mutating verb means for the menu header.
public enum Working: Sendable, Equatable {
    case plain // "Working…"
    case gatedAdd // an `add --access`: the gate wait can hold the queue for minutes
}

/// One row in a profile's section, derived from a `Share` plus the current time.
public struct Row: Sendable, Equatable {
    public let id: String
    /// The profile this row belongs to; rows and hits are keyed by (profile, id) because
    /// two profiles can mint the same 6-hex id.
    public let profile: String
    public let title: String
    public let trailing: String
    public let url: String
    /// The `--access` rule on a gated share; nil means public.
    public let access: String?
    public let canRefresh: Bool
    public let canCopy: Bool
    public let removeText: String
    /// What VoiceOver reads for the row: name, status, and the login gate when present.
    public let accessibilityTitle: String
    /// The composite key the hits cache uses.
    public var key: String { "\(profile)|\(id)" }

    init(share: Share, profile: String, now: Date) {
        id = share.id
        self.profile = profile
        title = share.ownHost ?? share.name
        trailing = Row.trailingText(share: share, now: now)
        url = share.url
        access = share.access
        canRefresh = share.kind == "snapshot"
        canCopy = !(url.contains("<pending>") || url.contains("<no-hostname>"))
        accessibilityTitle = access == nil
            ? "\(title), \(trailing)"
            : "\(title), \(trailing), login required"
        if let ownHost = share.ownHost {
            removeText = access == nil
                ? "Remove \(share.name)? This also deletes the DNS record for \(ownHost)."
                : "Remove \(share.name)? This also deletes the DNS record for \(ownHost) and its login gate."
        } else if access != nil {
            removeText = "Remove \(share.name)? The copy goes to the Trash and its login gate is deleted."
        } else {
            removeText = "Remove \(share.name)? The copy goes to the Trash."
        }
    }

    /// `live` for live kind; `never` for `expires == 0`; `expired` when `expires <= now`;
    /// else the largest whole unit left (floor, minimum `1m left`).
    static func trailingText(share: Share, now: Date) -> String {
        if share.kind == "live" { return "live" }
        if share.expires == 0 { return "never" }
        let nowEpoch = Int(now.timeIntervalSince1970)
        let remaining = share.expires - nowEpoch
        if remaining <= 0 { return "expired" }
        if remaining >= 86_400 { return "\(remaining / 86_400)d left" }
        if remaining >= 3_600 { return "\(remaining / 3_600)h left" }
        return "\(max(1, remaining / 60))m left"
    }
}

/// One menu section: a profile's title line, its rows, and its actions.
public struct Section: Sendable, Equatable {
    public let profile: String
    public let host: String?
    public let status: String
    public let health: Health
    public let rows: [Row]
    public let more: Int
    public let showStart: Bool
    public let showStop: Bool
    public let showSetUp: Bool
    public let accessPending: Int
    /// `share` for the default profile, `share --profile <name>` otherwise; the command
    /// the `more` and `access_pending` hint lines name (`<cmd> ls`, `<cmd> prune`).
    public let command: String

    init(entry: ProfileEntry, rowCap: Int, now: Date) {
        let health = Health.of(entry)
        profile = entry.name
        host = entry.state?.host
        status = Health.statusText(of: entry)
        self.health = health
        command = ProfileArgs.commandName(entry.name)
        accessPending = entry.state?.accessPending ?? 0
        // An `error` section shows its title line only: no rows, no action, so the app
        // never runs `--profile <bad name>`.
        if health == .error {
            rows = []
            more = 0
            showStart = false
            showStop = false
            showSetUp = false
        } else {
            let allRows = (entry.state?.shares ?? []).map { Row(share: $0, profile: entry.name, now: now) }
            rows = Array(allRows.prefix(rowCap))
            more = max(0, allRows.count - rowCap)
            showStart = entry.state?.state != "serving" && entry.state?.servesHere == true
            showStop = entry.state?.state == "serving"
            showSetUp = entry.state?.state != "serving"
        }
    }
}

/// The whole rendered menu state, derived from the latest `profiles --json` result (or
/// its failure).
public struct MenuModel: Sendable {
    /// One set-up profile caps at 25 rows; two or more cap at 10 each.
    public static let rowCapSingle = 25
    public static let rowCapEach = 10
    public static let workingHeader = "Working…"
    public static let gatedWorkingHeader = "Working… (a login gate can take minutes)"

    public let header: String
    public let sections: [Section]
    public let icon: Icon
    /// False when no profile can take an `add`; Share File… and the drop both honor it.
    public let canPublish: Bool
    public let showCopyInstallCommand: Bool
    public let showCopyUpgradeCommand: Bool
    /// True only before the first `profiles` result ever lands (no snapshot, no failure
    /// yet). Distinct from `Not set up`, which means a real result came back saying so.
    public let isLoading: Bool

    /// `working` overrides the header to the Working… line, above every other rule
    /// including `isLoading`, since a verb can only run after a first result landed.
    /// A non-nil `failure` beside a non-nil `profiles` means the snapshot is stale (the
    /// last refresh failed): the sections still render, the icon slashes, and the header
    /// shows the failure line.
    public init(profiles: ProfilesSnapshot?, failure: Failure?, now: Date, working: Working? = nil) {
        isLoading = profiles == nil && failure == nil
        showCopyInstallCommand = failure == .cliNotFound
        showCopyUpgradeCommand = failure == .oldCLI

        let entries = profiles?.profiles ?? []
        let setUpCount = entries.filter { Health.of($0) != .notSetUp }.count
        let cap = setUpCount <= 1 ? MenuModel.rowCapSingle : MenuModel.rowCapEach
        sections = entries.map { Section(entry: $0, rowCap: cap, now: now) }
        canPublish = entries.contains(where: PublishChoice.isEligible)

        if let working {
            header = working == .gatedAdd ? MenuModel.gatedWorkingHeader : MenuModel.workingHeader
        } else {
            header = MenuModel.headerText(profiles: profiles, sections: sections, failure: failure, isLoading: isLoading)
        }

        // `connected` needs the latest refresh to have succeeded, at least one `ok`
        // profile, and no attention anywhere; neutral profiles never slash the icon.
        let anyOK = sections.contains { $0.health == .ok }
        let anyAttention = sections.contains { $0.health.isAttention }
        icon = (failure == nil && anyOK && !anyAttention) ? .connected : .disconnected
    }

    /// First match wins, in the order the spec lists. `isLoading` (no snapshot, no
    /// failure: the cold-launch instant before the first `profiles` call returns) wins
    /// over all of them.
    private static func headerText(profiles: ProfilesSnapshot?, sections: [Section], failure: Failure?, isLoading: Bool) -> String {
        if isLoading { return "Loading…" }
        if case .cliNotFound? = failure { return "share CLI not found" }
        if case .oldCLI? = failure { return "Update share CLI" }
        if let profiles, profiles.schema > 1 { return "Update Share Bar" }
        if case .other(let message)? = failure { return message }
        let attention = sections.filter { $0.health.isAttention }
        if attention.count == 1 {
            return "Needs attention: \(attention[0].profile) (\(attention[0].status))"
        }
        if attention.count > 1 {
            return "Needs attention: \(attention.map(\.profile).joined(separator: ", "))"
        }
        let serving = sections.filter { $0.health == .ok }
        if !serving.isEmpty {
            return "Serving at \(serving.map { $0.host ?? $0.profile }.joined(separator: ", "))"
        }
        // Every set-up profile serves elsewhere; `notSetUp` entries never count.
        if sections.contains(where: { $0.health != .notSetUp }) {
            return "Not serving on this Mac"
        }
        return "Not set up"
    }
}
