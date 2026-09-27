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

    /// The last non-empty stderr line, kept as-is if it already starts with `share: `,
    /// prefixed with `share: ` otherwise, or `share exited <status>` when stderr is empty.
    /// Shared by `Snapshot.from` (the header line for a failed `state` call) and
    /// `MutationOutcome.alert` (a mutating verb's failure alert), since both failure
    /// messages follow the same rule (TASK-017).
    public var lastErrorLine: String {
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: false)
        if let line = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return line.hasPrefix("share: ") ? String(line) : "share: \(line)"
        }
        return "share exited \(status)"
    }
}
