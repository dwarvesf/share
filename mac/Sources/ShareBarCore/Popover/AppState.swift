import Foundation

/// The app states before any tenant view (`share-bar-interactions.md` section 1, gap G8).
/// Pure: the CLI's answer picks the state, the view only draws its panel.
public enum AppState: Sendable, Equatable {
    case loading
    case cliMissing
    case cliTooOld(minimum: String)
    case noTenant
    case ready

    /// First match wins: no CLI, an old CLI, nothing read yet, no tenant set up, else ready.
    /// A `cli_below_min` answer counts only when every set-up tenant gives it (one tenant
    /// that needs a newer share never hides the others).
    public static func of(profiles: ProfilesSnapshot?, failure: Failure?) -> AppState {
        if failure == .cliNotFound { return .cliMissing }
        if failure == .oldCLI { return .cliTooOld(minimum: Self.defaultMinimum) }
        guard let profiles else { return failure == nil ? .loading : .ready }
        let setUp = profiles.profiles.filter { ProfileView(entry: $0).role != .unset }
        if setUp.isEmpty { return .noTenant }
        let below = setUp.filter { $0.state?.compat?.status == "cli_below_min" }
        if below.count == setUp.count, let first = below.first {
            return .cliTooOld(minimum: Self.minorVersion(first.state?.compat?.minCLI) ?? Self.defaultMinimum)
        }
        return .ready
    }

    public static let defaultMinimum = "0.10"
    public static let installCommand = "brew install dwarvesf/tools/share"
    public static let upgradeCommand = "brew upgrade dwarvesf/tools/share"

    /// `0.10.0` reads `0.10`.
    static func minorVersion(_ version: String?) -> String? {
        guard let version else { return nil }
        let parts = version.split(separator: ".")
        guard parts.count >= 2, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return "\(parts[0]).\(parts[1])"
    }

    /// What replaces the popover's list body; nil for `noTenant` (the first-run panel) and `ready`.
    public var panel: AppStatePanel? {
        switch self {
        case .loading:
            return AppStatePanel(symbol: "ellipsis.circle", title: "Loading", body: "Reading your tenants.", button: nil, copy: nil)
        case .cliMissing:
            return AppStatePanel(
                symbol: "terminal", title: "Install the share command",
                body: "Share Bar runs the share command to read and publish links. Install it, then open this menu again.",
                button: "Copy install command", copy: Self.installCommand)
        case .cliTooOld(let minimum):
            return AppStatePanel(
                symbol: "arrow.down.circle", title: "Update share to \(minimum)",
                body: "This Share Bar needs a newer share command. Update it, then open this menu again.",
                button: "Copy upgrade command", copy: Self.upgradeCommand)
        case .noTenant, .ready:
            return nil
        }
    }
}

public struct AppStatePanel: Sendable, Equatable {
    public let symbol: String
    public let title: String
    public let body: String
    public let button: String?
    /// What the button puts on the pasteboard.
    public let copy: String?
}

/// The footer's line for a journaled command another process is running: `Working: add (3/6)`.
public enum WorkingLine {
    /// The newest alive op of the profile, or nil; a journal the CLI could not read never shows.
    public static func text(for entry: ProfileEntry?) -> String? {
        guard let op = entry?.state?.ops?.last(where: { $0.alive && $0.verb != "?" }) else { return nil }
        let verb = OpLineText.clean(op.verb)
        guard let step = op.step, let of = op.of else { return "Working: \(verb)" }
        return "Working: \(verb) (\(step)/\(of))"
    }
}

enum OpLineText {
    static func clean(_ text: String) -> String { OpLine.clean(text) }
}

/// Keyboard focus by row id: arrows move by id, a refresh that reorders rows keeps the id.
public enum RowFocus {
    /// The id after a refresh: the same id when its row is still there, else the nearest slot.
    public static func restored(previous: String?, previousIndex: Int?, ids: [String]) -> String? {
        guard let previous else { return nil }
        if ids.contains(previous) { return previous }
        guard !ids.isEmpty else { return nil }
        return ids[min(max(previousIndex ?? 0, 0), ids.count - 1)]
    }

    /// Arrow Down (+1) or Up (-1): the next id, clamped; with no focus, the first or last row.
    public static func moved(from current: String?, step: Int, ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return step > 0 ? ids.first : ids.last }
        return ids[max(0, min(ids.count - 1, index + step))]
    }
}

/// What VoiceOver reads and offers for one link row.
public enum RowAccessibility {
    /// The row's actions beyond the default press, in the row menu's order (VoiceOver's
    /// Actions rotor): the same items the menu offers, so nothing is reachable by pointer only.
    public static func actions(for row: RowModel) -> [RowAction] { RowMenu.items(for: row) }
}

/// A failure toast reads `<sentence> Next: <command>` (`PublishOutcome`): the sentence, then the
/// command as its own copyable line.
public enum FailureLine {
    public static func split(_ text: String) -> (sentence: String, next: String?) {
        guard let range = text.range(of: " Next: ", options: .backwards) else { return (text, nil) }
        let next = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !next.isEmpty else { return (text, nil) }
        return (String(text[..<range.lowerBound]), next)
    }
}
