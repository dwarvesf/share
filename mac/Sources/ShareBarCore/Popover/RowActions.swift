import Foundation

/// One item of a link's row menu (gap G9, DEC-52).
public enum RowAction: String, Sendable, Equatable, CaseIterable {
    case copyLink, openInBrowser, showInFinder, refresh, remove, revoke

    public var title: String {
        switch self {
        case .copyLink: return "Copy link"
        case .openInBrowser: return "Open in browser"
        case .showInFinder: return "Show in Finder"
        case .refresh: return "Refresh from source"
        case .remove: return "Remove link…"
        case .revoke: return "Revoke link…"
        }
    }

    /// The destructive item: last, after a separator, in red ink.
    public var isDestructive: Bool { self == .remove || self == .revoke }
}

/// The `link_state` table of `### Components & states`, as functions.
public enum RowMenu {
    /// Only the items the table allows; the rest are hidden, never dimmed.
    public static func items(for row: RowModel) -> [RowAction] {
        var items: [RowAction] = []
        if row.canCopy {
            items.append(.copyLink)
            items.append(.openInBrowser)
        }
        // Show in Finder and Refresh need the file: the viewer's own link on the Mac that serves
        // the tenant (decision D8). A revoked link has no file to act on.
        let onThisMac = row.own && row.servesHere && row.storage != "cloud" && row.state != .revoked
        if onThisMac {
            items.append(.showInFinder)
            items.append(.refresh)
        }
        if row.own {
            items.append(.remove)
        } else if row.isAdmin && row.isMemberLink {
            items.append(.revoke)
        }
        return items
    }
}

/// What a click or Return on a row does.
public struct ClickOutcome: Sendable, Equatable {
    public let copies: Bool
    public let message: String
}

public enum LinkClick {
    public static func outcome(for row: RowModel) -> ClickOutcome {
        switch row.state {
        case .live, .shadowed:
            return ClickOutcome(copies: true, message: "Link copied: \(row.title)")
        case .offline:
            return ClickOutcome(copies: true, message: "Copied. \(row.machine) is offline: visitors get a 503 until it is back.")
        case .paused:
            return ClickOutcome(copies: true, message: "Copied. \(row.state.copyWarning ?? "")")
        case .gateMissing:
            return ClickOutcome(copies: true, message: "Copied. \(row.state.copyWarning ?? "")")
        case .expired, .revoked:
            return ClickOutcome(copies: false, message: row.state.copyWarning ?? "")
        }
    }
}

/// A Remove, a Revoke or the Delete key: what the footer says and what runs after the Undo window.
public enum LinkRemoval {
    public static func action(for row: RowModel) -> Undo.Action { row.own ? .remove : .revoke }

    /// `share --profile <p> rm <id>`; an admin's rm of another member's v:3 link is a revoke
    /// (TASK-2a), the same verb.
    public static func argv(for row: RowModel) -> [String] { ProfileArgs.remove(row.profile, id: row.id) }

    public static func footer(for row: RowModel) -> String {
        row.own
            ? "Removed \(row.title). The link stops answering."
            : "Revoked \(row.title). It stops answering now; the file stays on \(row.machine)."
    }

    /// Whether the viewer may start a removal on this row at all (the Delete key on a row
    /// the menu would not list does nothing).
    public static func allowed(for row: RowModel) -> Bool {
        RowMenu.items(for: row).contains(row.own ? .remove : .revoke)
    }
}

extension PopoverState {
    /// Click or Return on a row: copies when the state allows and always sets the footer toast.
    /// Returns whether the row flashes "Copied".
    public func clicked(_ row: RowModel, now: Date) -> (state: PopoverState, effects: [PopoverEffect], flash: Bool) {
        let outcome = LinkClick.outcome(for: row)
        var result: (state: PopoverState, effects: [PopoverEffect])
        if outcome.copies {
            result = reduce(.copyLink(url: row.url))
        } else {
            result = (self, [])
        }
        let expires = now.addingTimeInterval(PopoverState.toastSeconds)
        result.state.footer = Footer(text: outcome.message, kind: .toast, expires: expires)
        return (result.state, result.effects, outcome.copies)
    }

    /// Remove, Revoke or the Delete key: appends an undo and puts its sentence in the footer
    /// for the whole window. Nil when the menu would not offer the action.
    public func removing(_ row: RowModel, now: Date) -> PopoverState? {
        guard LinkRemoval.allowed(for: row) else { return nil }
        var next = reduce(.remove(action: LinkRemoval.action(for: row), ids: [row.id], argv: LinkRemoval.argv(for: row), now: now)).state
        next.footer = Footer(text: LinkRemoval.footer(for: row), kind: .toast, expires: now.addingTimeInterval(Undo.window))
        return next
    }

    /// Undo or Command-Z: cancels the newest undo with no CLI call and clears the footer.
    public func undone() -> PopoverState {
        var next = reduce(.undo).state
        next.footer = nil
        next.undoHeld = false
        return next
    }
}

/// The defaults key `LegacyMenu` (the Advanced checkbox, TASK-4b15): on, the status item
/// keeps today's `NSMenu` for one release (DEC-42).
public enum LegacyMenu {
    public static let key = "LegacyMenu"

    public static func isOn(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key) }

    /// Today's menu model, unchanged.
    public static func model(profiles: ProfilesSnapshot?, failure: Failure?, now: Date, working: Working? = nil) -> MenuModel {
        MenuModel(profiles: profiles, failure: failure, now: now, working: working)
    }
}

/// Where a link's bytes live on this Mac: `pub/<id>` under the profile's root
/// (`$HOME/share`, or `$HOME/share/profiles/<name>`), the layout of `bin/share`.
public enum FinderPath {
    public static func pub(profile: String, id: String, home: String = NSHomeDirectory()) -> String {
        let root = profile == "default" ? "\(home)/share" : "\(home)/share/profiles/\(profile)"
        return "\(root)/pub/\(id)"
    }
}
