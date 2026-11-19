import Foundation

/// Decision logic for the mutating actions (TASK-017): which alert a finished verb calls
/// for, which share id an add just created, the folder-publish confirm text, and the
/// Stop Waiting threshold/confirm text. AppKit only presents these; every rule here is
/// plain data in and data out, so it is unit-tested without a menu or an `NSAlert`.
public struct MutationAlert: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case failure
        case privateWarning
        case notServingHere
    }

    public let kind: Kind
    public let message: String
    /// The whole stderr verbatim (trailing newlines aside) when it holds two or more
    /// non-empty lines: the O1 no-token block, the O3 group-not-found block, and the
    /// gate-timeout lines reach the user exactly as the CLI printed them. Nil otherwise.
    public let detail: String?
    /// Set only for `.privateWarning`: the share id its Remove button removes.
    public let removeShareID: String?
    /// The command the CLI's JSON error line names as the way through (`next`), shown as
    /// text a person can copy; nil when the CLI sent none.
    public let next: String?

    public init(kind: Kind, message: String, detail: String? = nil, removeShareID: String? = nil, next: String? = nil) {
        self.kind = kind
        self.message = message
        self.detail = detail
        self.removeShareID = removeShareID
        self.next = next
    }
}

/// The CLI's `{"error":{"code","message","next"}}` stderr line, printed last under
/// `SHARE_ERROR_JSON=1` (SPEC-010 G1). It never starts with `share: `.
public struct ErrorLine: Sendable, Equatable {
    public let code: String
    public let message: String
    public let next: String?

    private struct Envelope: Decodable {
        struct Body: Decodable {
            let code: String?
            let message: String
            let next: String?
        }
        let error: Body
    }

    /// Reads one stderr line; nil for anything that is not an error line.
    public static func parse(line: String) -> ErrorLine? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{\"error\""), let data = trimmed.data(using: .utf8),
              let body = (try? JSONDecoder().decode(Envelope.self, from: data))?.error,
              !body.message.isEmpty else { return nil }
        let next = body.next.flatMap { $0.isEmpty ? nil : $0 }
        return ErrorLine(code: body.code ?? "", message: body.message, next: next)
    }

    /// The last error line of a stderr buffer.
    public static func last(inStderr stderr: String) -> ErrorLine? {
        stderr.split(separator: "\n", omittingEmptySubsequences: true).reversed().lazy
            .compactMap { parse(line: String($0)) }.first
    }

    /// True for the lines a mutation's stderr carries that are machine-readable, not for
    /// a person: this error line and the progress line.
    static func isMachineLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("{\"error\"") || trimmed.hasPrefix("{\"progress\"")
    }
}

public enum MutationOutcome {
    /// Decides what to show after a mutating verb finishes and the follow-up `state` read
    /// completes. Precedence: a non-zero exit always wins (the verb failed outright, so
    /// nothing else about it matters); otherwise a `share: WARNING` stderr line on exit 0
    /// (the private-repo warning) wins over the not-serving-here notice, because a warning
    /// naming a specific share to review is more actionable than the general "no Mac here
    /// is serving" notice. Not pinned by the spec; the two are not stated to be mutually
    /// exclusive, so a strict precedence is chosen over trying to show both at once.
    ///
    /// `warningShareID` is the id a `share: WARNING` line on this result would name: the
    /// row being refreshed, or (for `add`) the id `newShare` found versus the ids captured
    /// before the add ran. Pass nil when the verb has no single share to point at (`rm`,
    /// `start`, `stop`, or an add whose new id could not be determined).
    public static func alert(
        for result: CLIResult,
        warningShareID: String?,
        notServingHere: Bool
    ) -> MutationAlert? {
        if result.status != 0 {
            // A JSON error line wins: its message and `next` are the CLI's own contract.
            // Without one (an older CLI, or a failure that is not a `die_code`), today's
            // last `share: ` line.
            let human = humanStderr(result.stderr)
            if let error = ErrorLine.last(inStderr: result.stderr) {
                return MutationAlert(
                    kind: .failure,
                    message: error.message,
                    detail: detailText(human, excludingMessage: error.message),
                    next: error.next
                )
            }
            return MutationAlert(
                kind: .failure,
                message: dieLine(human) ?? CLIResult(status: result.status, stdout: "", stderr: human, timedOut: false).lastErrorLine,
                detail: detailText(human)
            )
        }
        if let warningShareID, let warning = warningLine(result.stderr) {
            return MutationAlert(kind: .privateWarning, message: warning, removeShareID: warningShareID)
        }
        if notServingHere {
            return MutationAlert(
                kind: .notServingHere,
                message: "This Mac isn't in hosts=; the link works only once a Mac in hosts= is serving."
            )
        }
        return nil
    }

    /// The share in `after` that was not present in `before` (edge case 24): shares are
    /// newest-first, so the first match is the one the add that just ran created. Returns
    /// nil when no such share exists (the add failed before publishing, or the ids happen
    /// to be unchanged).
    public static func newShare(before ids: Set<String>, after shares: [Share]) -> Share? {
        shares.first { !ids.contains($0.id) }
    }

    /// Any stderr line starting `share: WARNING` (`warn_private`'s output), or nil.
    private static func warningLine(_ stderr: String) -> String? {
        stderr
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .first { CLIPrefix.has($0) && CLIPrefix.strip($0).hasPrefix("WARNING") }
    }

    /// The last stderr line starting `share: `, or nil. That is the `die` line (or the
    /// first line of a guided block like O1), which names the failure better than a
    /// trailing detail line.
    private static func dieLine(_ stderr: String) -> String? {
        stderr
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .last { CLIPrefix.has($0) }
    }

    /// The stderr a person reads: every line but the machine-readable error and progress
    /// lines, which only `SHARE_ERROR_JSON` and `SHARE_PROGRESS` add.
    private static func humanStderr(_ stderr: String) -> String {
        stderr
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !ErrorLine.isMachineLine($0) }
            .joined(separator: "\n")
    }

    /// The detail when the CLI's JSON message is what the alert already says: the human
    /// lines other than the `share: <message>` line it repeats; nil when none remain
    /// beyond a second.
    private static func detailText(_ stderr: String, excludingMessage message: String) -> String? {
        let remaining = stderr
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !(CLIPrefix.has($0) && CLIPrefix.strip($0) == message) }
            .joined(separator: "\n")
        return detailText(remaining)
    }

    /// The whole stderr verbatim (trailing newlines trimmed) when it holds two or more
    /// non-empty lines; nil otherwise.
    private static func detailText(_ stderr: String) -> String? {
        let nonEmpty = stderr
            .split(separator: "\n", omittingEmptySubsequences: false)
            .count { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard nonEmpty >= 2 else { return nil }
        var text = stderr
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}

/// The "Stop Waiting" affordance a stuck mutating verb offers after it has been running too
/// long: when it appears, and what its confirm dialog says before TERMing the process group.
public enum StopWaiting {
    public static let delay: TimeInterval = 60
    public static let confirmText =
        "The share may be left half-published; run it again from the terminal to finish. " +
        "If sharing was starting, this also stops it."
    /// What Stop Waiting says while an `add` runs: the add stops where it is and a bare
    /// `share prune` finishes or removes what it left (SPEC-010 G9).
    public static let addConfirmText = "The add stops where it is; handout prune cleans up what it left."

    public static func confirmText(isAdd: Bool) -> String {
        isAdd ? addConfirmText : confirmText
    }
}
