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
    /// Set only for `.privateWarning`: the share id its Remove button removes.
    public let removeShareID: String?

    public init(kind: Kind, message: String, removeShareID: String? = nil) {
        self.kind = kind
        self.message = message
        self.removeShareID = removeShareID
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
            return MutationAlert(kind: .failure, message: result.lastErrorLine)
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
            .first { $0.hasPrefix("share: WARNING") }
    }
}

/// The folder-publish confirm text (UI changes: Share File… and drop both ask this before
/// running `add` on a directory).
public enum FolderConfirm {
    public static func text(name: String) -> String {
        "Publish the folder \(name) at a public link for 30 days?"
    }
}

/// The "Stop Waiting" affordance a stuck mutating verb offers after it has been running too
/// long: when it appears, and what its confirm dialog says before TERMing the process group.
public enum StopWaiting {
    public static let delay: TimeInterval = 60
    public static let confirmText =
        "The share may be left half-published; run it again from the terminal to finish. " +
        "If sharing was starting, this also stops it."
}
