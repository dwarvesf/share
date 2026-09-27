import Foundation

/// Which status-item icon a `MenuModel` calls for. AppKit picks the actual `NSImage`
/// (template SF Symbols); this only names the two states the model can tell apart.
public enum Icon: Sendable, Equatable {
    case connected // antenna.radiowaves.left.and.right: serving and ready
    case disconnected // antenna.radiowaves.left.and.right.slash: anything else
}

/// One row in the menu, derived from a `Share` plus the current time.
public struct Row: Sendable, Equatable {
    public let id: String
    public let title: String
    public let trailing: String
    public let url: String
    public let canRefresh: Bool
    public let canCopy: Bool
    public let removeText: String

    init(share: Share, now: Date) {
        id = share.id
        title = share.ownHost ?? share.name
        trailing = Row.trailingText(share: share, now: now)
        url = share.url
        canRefresh = share.kind == "snapshot"
        canCopy = !(url.contains("<pending>") || url.contains("<no-hostname>"))
        if let ownHost = share.ownHost {
            removeText = "Remove \(share.name)? This also deletes the DNS record for \(ownHost)."
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

/// The whole rendered menu state, derived from the latest `state` result (or its failure).
public struct MenuModel: Sendable {
    public static let rowCap = 25

    public let header: String
    public let rows: [Row]
    public let more: Int
    public let icon: Icon
    public let showStart: Bool
    public let showStop: Bool
    public let showSetUp: Bool
    public let showCopyInstallCommand: Bool
    public let showCopyUpgradeCommand: Bool
    /// True only before the first `state` result ever lands (no snapshot, no failure yet).
    /// Distinct from `Not set up`, which means a real result came back saying so.
    public let isLoading: Bool

    public init(snapshot: Snapshot?, failure: Failure?, now: Date) {
        isLoading = snapshot == nil && failure == nil
        header = MenuModel.headerText(snapshot: snapshot, failure: failure, isLoading: isLoading)
        if case .cliNotFound? = failure {
            showCopyInstallCommand = true
        } else {
            showCopyInstallCommand = false
        }
        if case .oldCLI? = failure {
            showCopyUpgradeCommand = true
        } else {
            showCopyUpgradeCommand = false
        }
        if let snapshot {
            let allRows = snapshot.shares.map { Row(share: $0, now: now) }
            rows = Array(allRows.prefix(MenuModel.rowCap))
            more = max(0, allRows.count - MenuModel.rowCap)
            showStart = snapshot.state != "serving" && snapshot.servesHere
            showStop = snapshot.state == "serving"
            showSetUp = snapshot.state != "serving"
            icon = (snapshot.state == "serving" && snapshot.ready) ? .connected : .disconnected
        } else {
            rows = []
            more = 0
            showStart = false
            showStop = false
            showSetUp = false
            icon = .disconnected
        }
    }

    /// First match wins, in the order the spec lists. `isLoading` (no snapshot, no failure:
    /// the cold-launch instant before the first `state` call returns) wins over all of them,
    /// including `Not set up`, which the fallthrough below would otherwise say.
    private static func headerText(snapshot: Snapshot?, failure: Failure?, isLoading: Bool) -> String {
        if isLoading { return "Loading…" }
        if case .cliNotFound? = failure { return "share CLI not found" }
        if case .oldCLI? = failure { return "Update share CLI" }
        if let snapshot, snapshot.schema > 1 { return "Update Share Bar" }
        if case .other(let message)? = failure { return message }
        guard let snapshot else { return "Not set up" }
        if snapshot.state == "not_setup" { return "Not set up" }
        if snapshot.state != "serving", !snapshot.servesHere {
            return "Not serving on this Mac (hosts=\(snapshot.hosts))"
        }
        if snapshot.state == "stopped" { return "Stopped" }
        if snapshot.state == "serving" {
            return snapshot.ready ? "Serving at \(snapshot.host ?? "")" : "Serving, tunnel not connected"
        }
        return "Not set up"
    }
}
