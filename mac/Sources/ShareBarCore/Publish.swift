import Foundation

/// Shape-only validation of an `--access` rule: the app checks the prefix and length, the
/// CLI owns the full grammar, and its refusal reaches the user verbatim (so the two can
/// never disagree).
public enum AccessRule {
    /// After trimming: `group:`, `email:`, or `domain:` followed by at least one
    /// character, and no whitespace anywhere.
    public static func isWellFormed(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        for prefix in ["group:", "email:", "domain:"] where trimmed.hasPrefix(prefix) {
            return trimmed.count > prefix.count
        }
        return false
    }
}

/// Who may open a published share.
public enum Audience: Sendable, Equatable {
    case anyone
    case login
}

/// Which profiles can take an `add`, and the argv each add runs.
public enum PublishChoice {
    /// Eligible profiles: `stopped` or `serving` with no `error`, in listing order. `add`
    /// auto-starts a stopped profile; an `elsewhere` profile keeps its post-add notice.
    public static func eligible(_ snapshot: ProfilesSnapshot) -> [String] {
        snapshot.profiles.compactMap { isEligible($0) ? $0.name : nil }
    }

    public static func isEligible(_ entry: ProfileEntry) -> Bool {
        guard entry.error == nil, let state = entry.state else { return false }
        return state.state == "stopped" || state.state == "serving"
    }

    /// argv for one add; nil unless `path` is absolute, so a bare `8080` can never reach
    /// `add` and become a live port share by accident.
    public static func args(profile: String, rule: String?, path: String) -> [String]? {
        guard path.hasPrefix("/") else { return nil }
        if let rule, !rule.isEmpty {
            return ["--profile", profile, "add", "--access", rule, path]
        }
        return ["--profile", profile, "add", path]
    }
}

/// The publish dialog's state and rules, free of AppKit so every rule is unit-testable.
/// The form never moves the audience from `login` to `anyone` on its own: a mistaken
/// carry-over gates a file (visible at once) rather than exposing one.
public struct PublishForm: Sendable, Equatable {
    /// The selected profile, nil only when no profile is eligible.
    public private(set) var profile: String?
    public private(set) var audience: Audience
    /// The rule field's text; meaningful only while `audience == .login`.
    public var rule: String

    private let profiles: ProfilesSnapshot
    private let lastRules: [String: String]
    /// True while the snapshot is stale (the latest refresh failed): hosts may be wrong,
    /// so the button names the profile instead.
    private let staleHosts: Bool

    /// `lastProfile` wins when still eligible, else the first eligible profile. The
    /// audience and rule start from the selected profile's stored rule (empty = anyone).
    public init(profiles: ProfilesSnapshot, lastProfile: String?, lastRules: [String: String], staleHosts: Bool = false) {
        self.profiles = profiles
        self.lastRules = lastRules
        self.staleHosts = staleHosts
        let eligible = PublishChoice.eligible(profiles)
        profile = (lastProfile.flatMap { eligible.contains($0) ? $0 : nil }) ?? eligible.first
        let stored = lastRules[profile ?? ""] ?? ""
        rule = stored
        audience = stored.isEmpty ? .anyone : .login
    }

    /// Under `login` the audience and the typed rule survive a profile switch, even when
    /// the new profile's stored choice is `anyone`. Under `anyone` the new profile's own
    /// stored choice loads.
    public mutating func select(profile name: String) {
        profile = name
        if audience == .anyone {
            let stored = lastRules[name] ?? ""
            rule = stored
            audience = stored.isEmpty ? .anyone : .login
        }
    }

    public mutating func choose(_ newAudience: Audience) {
        audience = newAudience
    }

    /// `login` needs a named setup; a quick-mode profile cannot take `--access`.
    public var loginAvailable: Bool {
        profiles.profiles.first { $0.name == profile }?.state?.mode != "quick"
    }

    public var canPublish: Bool {
        guard profile != nil else { return false }
        switch audience {
        case .anyone:
            return true
        case .login:
            // On a quick profile the user must pick `Anyone with the link` by hand.
            return loginAvailable && AccessRule.isWellFormed(rule)
        }
    }

    /// The default button names what will happen; the profile name stands in for the host
    /// when it is unknown (a stale snapshot, or a stopped profile with none).
    public var buttonTitle: String {
        let target: String
        if staleHosts {
            target = profile ?? "?"
        } else {
            target = profiles.profiles.first { $0.name == profile }?.state?.host ?? profile ?? "?"
        }
        switch audience {
        case .anyone: return "Publish publicly on \(target)"
        case .login: return "Publish behind login on \(target)"
        }
    }

    /// The `UserDefaults` key the form's audience+rule persist under for a profile.
    public static func ruleKey(for profile: String) -> String {
        "publish.rule.\(profile)"
    }
}

/// The dialog's message line for a batch (the folder phrasing replaces the old separate
/// folder confirm: one dialog covers the whole batch).
public enum PublishMessage {
    public static func text(paths: [String], isDirectory: (String) -> Bool) -> String {
        if paths.count > 1 {
            return "Publish \(paths.count) items?"
        }
        guard let path = paths.first else { return "Publish?" }
        let name = (path as NSString).lastPathComponent
        if isDirectory(path) {
            return "Publish the folder \(name) for 30 days?"
        }
        return "Publish \(name)?"
    }
}
