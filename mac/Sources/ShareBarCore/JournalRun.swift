import Foundation

/// Runs the `rerun_argv` or `rollback_argv` of a stopped journal (SPEC-010 DEC-21).
///
/// A journal file is written by the CLI, but any local process can write one. So the
/// arguments are an array, never a string; they run by exec of the app's own located
/// `share` with no shell; and they are checked first against a shape per journal verb:
/// the leading `--profile` must name the profile the op was listed under, the verb must be
/// one the journal's own verb may rerun or roll back to, and every other argument must be
/// a flag that verb's own journal writes (a value that starts with `-` is never a value).
/// An op whose liveness is unknown or true never runs. Anything else returns nil and
/// nothing runs. The display strings `rerun` and `rollback` are text only and never reach
/// this code.
public enum JournalRun {
    public enum Kind: Sendable {
        case rerun, rollback
    }

    /// What one rerun or rollback may look like after `--profile <name>`: the `share`
    /// verb, its flags (true when the flag takes a value), and how many bare arguments.
    private struct Shape {
        let verb: String
        var flags: [String: Bool] = [:]
        var positionals: ClosedRange<Int> = 0...0
        /// A rollback of `add` names the add's own share id.
        var needsOwnID = false
        /// `member <sub>`: the sub-verb is the journal verb's suffix.
        var subverbFromOp = false
    }

    private static let setupHost = 1...1

    /// The rerun shape per journal verb, from the `op_begin` sites of `bin/share`.
    private static func rerunShape(_ op: String) -> Shape? {
        switch op {
        case "setup-tunnel":
            return Shape(verb: "setup", flags: ["--tunnel-name": true, "--force": false, "--no-service": false, "--login": false], positionals: setupHost)
        case "setup-r2":
            return Shape(verb: "setup", flags: ["--r2": false, "--bucket": true, "--storage-default": true, "--force": false, "--alias": true], positionals: setupHost)
        case "no-r2":
            return Shape(verb: "setup", flags: ["--no-r2": false], positionals: setupHost)
        case "setup-members", "no-members":
            return Shape(verb: "setup", flags: ["--r2": false, "--bucket": true, "--members": false, "--no-members": false, "--yes": false], positionals: setupHost)
        case "teardown":
            return Shape(verb: "teardown", flags: ["--yes": false])
        case "teardown-purge":
            return Shape(verb: "teardown", flags: ["--yes": false, "--purge": false])
        case "migrate":
            return Shape(verb: "migrate", flags: ["--to": true, "--remote-profile": true, "--remote-bin": true, "--max-bytes": true, "--yes": false])
        case "add":
            return Shape(verb: "add", flags: ["--ttl": true, "--host": true, "--access": true, "--no-index": false, "--cloud": false, "--local": false], positionals: 1...1)
        case "join":
            return Shape(verb: "join")
        default:
            if op.hasPrefix("member-"), op.count > "member-".count {
                return Shape(verb: "member", flags: [:], positionals: 0...8, subverbFromOp: true)
            }
            return nil
        }
    }

    /// The rollback shape per journal verb: `--no-r2` for `setup-r2`, `rm <id>` or a bare
    /// `prune` for `add`, `leave --local` for `join`.
    private static func rollbackShapes(_ op: String) -> [Shape] {
        switch op {
        case "setup-r2":
            return [Shape(verb: "setup", flags: ["--no-r2": false], positionals: setupHost)]
        case "add":
            return [Shape(verb: "rm", positionals: 1...1, needsOwnID: true), Shape(verb: "prune")]
        case "join":
            return [Shape(verb: "leave", flags: ["--local": false])]
        default:
            return []
        }
    }

    private static let profilePattern = try? NSRegularExpression(pattern: "^[a-z0-9][a-z0-9-]{0,31}\\z")

    static func isProfileName(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return profilePattern?.firstMatch(in: text, range: range) != nil
    }

    private static func matches(_ args: ArraySlice<String>, shape: Shape, op: OpInfo) -> Bool {
        var rest = args
        guard rest.first == shape.verb else { return false }
        rest = rest.dropFirst()
        if shape.subverbFromOp {
            guard let sub = rest.first, op.verb == "member-" + sub else { return false }
            rest = rest.dropFirst()
        }
        var bare: [String] = []
        while let argument = rest.first {
            rest = rest.dropFirst()
            if argument == "--profile" { return false }
            if let takesValue = shape.flags[argument] {
                if takesValue {
                    guard let value = rest.first, !value.hasPrefix("-"), !value.isEmpty else { return false }
                    rest = rest.dropFirst()
                }
            } else if argument.hasPrefix("-") {
                // A member sub-verb takes its own flags and values, so a member shape lets an
                // unlisted `--flag` through; every other verb refuses it.
                guard shape.subverbFromOp, argument.hasPrefix("--") else { return false }
            } else {
                bare.append(argument)
            }
        }
        if shape.needsOwnID, bare != [op.id ?? ""] { return false }
        return shape.positionals.contains(bare.count)
    }

    /// The argv to run after `share`, or nil when the journal's argv fails a check. The
    /// result always leads with `--profile <profile>` (the app's own convention), so a
    /// stored argv without it still runs on the right profile.
    public static func argv(op: OpInfo, kind: Kind, profile: String) -> [String]? {
        guard op.aliveKnown, !op.alive, isProfileName(profile) else { return nil }
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
        let shapes = kind == .rerun ? [rerunShape(op.verb)].compactMap { $0 } : rollbackShapes(op.verb)
        guard shapes.contains(where: { matches(rest, shape: $0, op: op) }) else { return nil }
        return ProfileArgs.argv(profile, Array(rest))
    }

    /// Runs a checked argv by exec through the app's located CLI. Nil when a check fails
    /// (nothing ran); otherwise the verb's result.
    public static func run(op: OpInfo, kind: Kind, profile: String, timeout: TimeInterval? = nil) async -> CLIResult? {
        guard let argv = argv(op: op, kind: kind, profile: profile) else { return nil }
        return await CLI.run(argv, timeout: timeout)
    }
}
