import Foundation

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

    /// The last non-empty stderr line, verbatim (no `share: ` prefixing), or nil when stderr
    /// has no non-empty line. Shared by `lastErrorLine` and `hitsText`, which each format a
    /// missing line differently (`share exited <status>` on failure, trimmed stdout on
    /// success).
    public var lastNonEmptyStderrLine: String? {
        stderr
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    /// `lastNonEmptyStderrLine`, kept as-is if it already starts with `share: `, prefixed
    /// with `share: ` otherwise, or `share exited <status>` when there is none. Shared by
    /// `Snapshot.from` (the header line for a failed `state` call) and `MutationOutcome.alert`
    /// (a mutating verb's failure alert), since both failure messages follow the same rule
    /// (TASK-017).
    public var lastErrorLine: String {
        guard let line = lastNonEmptyStderrLine else { return "share exited \(status)" }
        return line.hasPrefix("share: ") ? line : "share: \(line)"
    }

    /// What a row's hits submenu item shows once the `hits <id>` call this backs finishes:
    /// on a non-zero exit, `lastNonEmptyStderrLine` verbatim (or `share exited <status>`
    /// when stderr is empty); on exit 0, stdout trimmed. Shared so the rule lives once in the
    /// tested Core target instead of duplicated in the app's `StatusItemController`.
    public var hitsText: String {
        if status != 0 {
            return lastNonEmptyStderrLine ?? "share exited \(status)"
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
