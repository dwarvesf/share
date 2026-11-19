import Foundation

/// The prefix the CLI puts on its own stderr lines: `handout: ` since the rename, `share: `
/// from a CLI that predates it (the app still runs one through the `share` fallback).
public enum CLIPrefix {
    public static let current = "handout: "
    public static let legacy = "share: "

    /// True when the line starts with either prefix.
    public static func has(_ line: String) -> Bool {
        line.hasPrefix(current) || line.hasPrefix(legacy)
    }

    /// The line without its prefix, or the line as-is when it has none.
    public static func strip(_ line: String) -> String {
        if line.hasPrefix(current) { return String(line.dropFirst(current.count)) }
        if line.hasPrefix(legacy) { return String(line.dropFirst(legacy.count)) }
        return line
    }
}

/// The outcome of one CLI invocation.
public struct CLIResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public init(status: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    /// The last non-empty stderr line, verbatim (no `handout: ` prefixing), or nil when stderr
    /// has no non-empty line. Shared by `lastErrorLine` and `hitsText`, which each format a
    /// missing line differently (`handout exited <status>` on failure, trimmed stdout on
    /// success).
    public var lastNonEmptyStderrLine: String? {
        stderr
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    /// `lastNonEmptyStderrLine`, kept as-is if it already starts with `handout: ` (or an older
    /// CLI's `share: `), prefixed with `handout: ` otherwise, or `handout exited <status>` when
    /// there is none. Shared by
    /// `ProfilesSnapshot.from` (the header line for a failed `profiles` call) and `MutationOutcome.alert`
    /// (a mutating verb's failure alert), since both failure messages follow the same rule
    ///.
    public var lastErrorLine: String {
        guard let line = lastNonEmptyStderrLine else { return "handout exited \(status)" }
        return CLIPrefix.has(line) ? line : CLIPrefix.current + line
    }

    /// What a row's hits submenu item shows once the `hits <id>` call this backs finishes:
    /// on a non-zero exit, `lastNonEmptyStderrLine` verbatim (or `handout exited <status>`
    /// when stderr is empty); on exit 0, stdout trimmed. Shared so the rule lives once in the
    /// tested Core target instead of duplicated in the app's `StatusItemController`.
    public var hitsText: String {
        if status != 0 {
            return lastNonEmptyStderrLine ?? "handout exited \(status)"
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
