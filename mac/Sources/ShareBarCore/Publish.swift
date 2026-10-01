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

/// Where one published link lives; the argv flag it maps to.
public enum PublishStorage: Sendable, Equatable {
    case local // --local: this tenant's origin machine
    case cloud // --cloud: the tenant's bucket
}

/// What the dialog's `Storage` row shows for the selected profile.
public enum StorageField: Sendable, Equatable {
    /// No control at all: a tunnel profile with R2 off, or an older CLI with no `r2` key.
    case none
    /// An r2 member profile publishes cloud links only: a disabled `In the cloud` label.
    case member
    /// An origin with R2 on (the tunnel runs here): an `On <machine>` / `In the cloud`
    /// popup, `machine` being this Mac's name out of the state `hosts` line (or its first
    /// entry when this Mac is not named there).
    case picker(machine: String)
}

/// Which profiles can take an `add`, and the argv each add runs.
public enum PublishChoice {
    /// Eligible profiles: `stopped` or `serving` with no `error`, in listing order. `add`
    /// auto-starts a stopped profile; an `elsewhere` profile keeps its post-add notice.
    /// None when the listing's top-level `schema` is above 1 (the app cannot read it).
    public static func eligible(_ snapshot: ProfilesSnapshot) -> [String] {
        guard snapshot.schema <= 1 else { return [] }
        return snapshot.profiles.compactMap { isEligible($0) ? $0.name : nil }
    }

    public static func isEligible(_ entry: ProfileEntry) -> Bool {
        guard entry.error == nil, let state = entry.state else { return false }
        return state.state == "stopped" || state.state == "serving"
    }

    /// argv for one add; nil unless `path` is absolute, so a bare `8080` can never reach
    /// `add` and become a live port share by accident. `storage` adds `--cloud` or
    /// `--local`; nil leaves the choice to the CLI's `storage_default`.
    public static func args(profile: String, rule: String?, path: String, storage: PublishStorage? = nil) -> [String]? {
        guard path.hasPrefix("/") else { return nil }
        var argv = ["--profile", profile, "add"]
        if let rule, !rule.isEmpty {
            argv += ["--access", rule]
        }
        if let storage {
            argv.append(storage == .cloud ? "--cloud" : "--local")
        }
        argv.append(path)
        return argv
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
    /// The `Storage` popup's selection; read through `storageField`/`storageFlag`, which
    /// decide whether the choice applies at all.
    public private(set) var storage: PublishStorage

    /// This Mac's name, as the `hosts=` config key would spell it (the CLI's `this_host`:
    /// `uname -n` before the first dot). Overridable in tests.
    public static let defaultCurrentMachineName: () -> String = {
        ProcessInfo.processInfo.hostName.split(separator: ".", maxSplits: 1).first.map(String.init)
            ?? ProcessInfo.processInfo.hostName
    }
    public static var currentMachineName: () -> String = defaultCurrentMachineName

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
        storage = PublishForm.defaultStorage(of: profile, in: profiles)
    }

    /// Under `login` the audience and the typed rule survive a profile switch, even when
    /// the new profile's stored choice is `anyone`. Under `anyone` the new profile's own
    /// stored choice loads. Storage reloads from the new profile's `storage_default`
    /// either way: the picker is per-tenant, not a remembered preference.
    public mutating func select(profile name: String) {
        profile = name
        storage = PublishForm.defaultStorage(of: name, in: profiles)
        if audience == .anyone {
            let stored = lastRules[name] ?? ""
            rule = stored
            audience = stored.isEmpty ? .anyone : .login
        }
    }

    public mutating func choose(_ newAudience: Audience) {
        audience = newAudience
    }

    public mutating func choose(storage newStorage: PublishStorage) {
        storage = newStorage
    }

    /// The `Storage` row for the selected profile: a picker on an R2-on origin serving
    /// here, a disabled `In the cloud` label on an r2 member, nothing otherwise.
    public var storageField: StorageField {
        guard let state = profiles.profiles.first(where: { $0.name == profile })?.state else { return .none }
        if state.backend == "r2" { return .member }
        if state.r2 == true && state.servesHere {
            guard !state.hosts.isEmpty else { return .picker(machine: "this machine") }
            let names = state.hosts.split(separator: " ").map(String.init)
            let mine = PublishForm.currentMachineName()
            let machine = names.contains(mine) ? mine : (names.first ?? state.hosts)
            return .picker(machine: machine)
        }
        return .none
    }

    /// The `--cloud`/`--local` flag the add argv gains; nil unless the picker is showing
    /// (a member's adds are cloud already, and a plain tunnel profile takes no flag).
    public var storageFlag: PublishStorage? {
        if case .picker = storageField { return storage }
        return nil
    }

    /// A picker's preselection: the profile's `storage_default`, local when unset.
    private static func defaultStorage(of profile: String?, in profiles: ProfilesSnapshot) -> PublishStorage {
        let state = profile.flatMap { name in profiles.profiles.first { $0.name == name }?.state }
        return state?.storageDefault == "cloud" ? .cloud : .local
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
