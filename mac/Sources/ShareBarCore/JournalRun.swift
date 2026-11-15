import Foundation

/// Runs the `rerun_argv` or `rollback_argv` of a stopped journal (SPEC-010 DEC-21).
///
/// A journal file is written by the CLI, but any local process can write one. So the
/// arguments are an array, never a string; they run by exec of the app's own located
/// `share` with no shell; and they are checked first: the leading `--profile` must name
/// the profile the op was listed under, and the verb must be one the journal's own verb
/// may rerun or roll back to. Anything else returns nil and nothing runs. The display
/// strings `rerun` and `rollback` are text only and never reach this code.
public enum JournalRun {
    public enum Kind: Sendable {
        case rerun, rollback
    }

    /// Journal verb to the `share` verbs its rerun or rollback may name.
    private static let allowedVerbs: [String: Set<String>] = [
        "setup-tunnel": ["setup"],
        "setup-r2": ["setup"],
        "no-r2": ["setup"],
        "setup-members": ["setup"],
        "no-members": ["setup"],
        "teardown": ["teardown"],
        "teardown-purge": ["teardown"],
        "migrate": ["migrate"],
        "add": ["add", "rm", "prune"],
        "join": ["join", "leave"],
    ]

    /// Admin member verbs journal as `member-<verb>` and rerun as `member <verb> ...`.
    private static let memberPrefix = "member-"

    private static let profilePattern = try? NSRegularExpression(pattern: "^[a-z0-9][a-z0-9-]{0,31}$")

    static func isProfileName(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return profilePattern?.firstMatch(in: text, range: range) != nil
    }

    private static func allowed(verb: String, for op: String) -> Bool {
        if let set = allowedVerbs[op] { return set.contains(verb) }
        if op.hasPrefix(memberPrefix), op.count > memberPrefix.count { return verb == "member" }
        return false
    }

    /// The argv to run after `share`, or nil when the journal's argv fails a check. The
    /// result always leads with `--profile <profile>` (the app's own convention), so a
    /// stored argv without it still runs on the right profile.
    public static func argv(op: OpInfo, kind: Kind, profile: String) -> [String]? {
        guard !op.alive, isProfileName(profile) else { return nil }
        guard let stored = (kind == .rerun ? op.rerunArgv : op.rollbackArgv),
              !stored.isEmpty, stored.count <= 64 else { return nil }
        for argument in stored where argument.utf8.count > 4096 || argument.contains("\0") {
            return nil
        }
        var rest = stored[...]
        if rest.first == "--profile" {
            guard rest.count >= 2, rest[rest.startIndex + 1] == profile else { return nil }
            rest = rest.dropFirst(2)
        }
        guard let verb = rest.first, allowed(verb: verb, for: op.verb) else { return nil }
        return ProfileArgs.argv(profile, Array(rest))
    }

    /// Runs a checked argv by exec through the app's located CLI. Nil when a check fails
    /// (nothing ran); otherwise the verb's result.
    public static func run(op: OpInfo, kind: Kind, profile: String, timeout: TimeInterval? = nil) async -> CLIResult? {
        guard let argv = argv(op: op, kind: kind, profile: profile) else { return nil }
        return await CLI.run(argv, timeout: timeout)
    }
}
