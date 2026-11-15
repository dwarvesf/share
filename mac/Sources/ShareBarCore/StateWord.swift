import Foundation

/// A symbol and a word for one state. Color is never the only signal (the spec's
/// `Exclude` line): every state a row, chip or footer can show has both.
public struct StateWord: Sendable, Equatable {
    /// An SF Symbol name.
    public let symbol: String
    /// The word the meta line, chip and VoiceOver read.
    public let word: String

    public init(symbol: String, word: String) {
        self.symbol = symbol
        self.word = word
    }
}

/// The values of a share row's `link_state` (SPEC-010 G7 and SPEC-009 TASK-0c). Any other
/// string reads as `live`: an unknown value must never hide or disable a link (SB-04).
public enum LinkState: String, CaseIterable, Sendable {
    case live, offline, paused, expired, revoked, shadowed
    case gateMissing = "gate_missing"

    /// `nil` (an older CLI) and an unknown value both read as `live`.
    public init(raw: String?) {
        self = raw.flatMap(LinkState.init(rawValue:)) ?? .live
    }

    /// Whether a visitor's request is answered. `offline` and `paused` answer 503,
    /// `expired` and `revoked` answer nothing a visitor can use, `shadowed` loses to a
    /// newer link of the same name, and `gate_missing` has lost its login gate.
    public var answers: Bool { self == .live }

    /// The row's copy action: `expired` and `revoked` never copy (DEC-52).
    public var canCopy: Bool { self != .expired && self != .revoked }

    /// The click or Return outcome of the link-state table of `### Components & states`.
    public var copyWarning: String? {
        switch self {
        case .paused: return "This member is paused: visitors get a 503."
        case .expired: return "This link expired, so it no longer answers. Share the file again for a new link."
        case .revoked: return "This link was removed by an admin."
        case .gateMissing: return "This link's login gate is missing: anyone with the link can open it."
        case .live, .offline, .shadowed: return nil
        }
    }

    /// Drag out: `live`, `offline` and `paused` rows only (DEC-52).
    public var canDrag: Bool { self == .live || self == .offline || self == .paused }

    public var stateWord: StateWord {
        switch self {
        case .live: return StateWord(symbol: "checkmark.circle", word: "live")
        case .offline: return StateWord(symbol: "moon", word: "offline")
        case .paused: return StateWord(symbol: "pause.circle", word: "paused")
        case .expired: return StateWord(symbol: "clock.badge.xmark", word: "expired")
        case .revoked: return StateWord(symbol: "nosign", word: "removed by admin")
        case .shadowed: return StateWord(symbol: "square.on.square.dashed", word: "replaced")
        case .gateMissing: return StateWord(symbol: "lock.slash", word: "no login gate")
        }
    }
}

/// The stored statuses of a member record (SPEC-009 `### Member status transitions`), plus
/// `invalid` for a record the CLI could not read and `expired` for an invite past its
/// expiry (derived by the CLI, shown as its own word).
public enum MemberStatus: String, CaseIterable, Sendable {
    case adding, invited, joining, active, pausing, paused, resuming, inviting
    case rotating, renewing, removing, removed, left, expired, invalid

    /// Nil for a status this app does not know; the row then shows the raw word.
    public init?(raw: String?) {
        guard let raw, let known = MemberStatus(rawValue: raw) else { return nil }
        self = known
    }

    public var stateWord: StateWord {
        switch self {
        case .adding: return StateWord(symbol: "arrow.triangle.2.circlepath", word: "Adding")
        case .invited: return StateWord(symbol: "envelope", word: "Invited")
        case .joining: return StateWord(symbol: "arrow.triangle.2.circlepath", word: "Joining")
        case .active: return StateWord(symbol: "checkmark.circle", word: "Active")
        case .pausing: return StateWord(symbol: "arrow.triangle.2.circlepath", word: "Pausing")
        case .paused: return StateWord(symbol: "pause.circle", word: "Paused")
        case .resuming: return StateWord(symbol: "arrow.triangle.2.circlepath", word: "Resuming")
        case .inviting: return StateWord(symbol: "arrow.triangle.2.circlepath", word: "Sending a new code")
        case .rotating: return StateWord(symbol: "arrow.triangle.2.circlepath", word: "Rotating keys")
        case .renewing: return StateWord(symbol: "arrow.triangle.2.circlepath", word: "Renewing")
        case .removing: return StateWord(symbol: "arrow.triangle.2.circlepath", word: "Removing")
        case .removed: return StateWord(symbol: "person.crop.circle.badge.minus", word: "Removed")
        case .left: return StateWord(symbol: "rectangle.portrait.and.arrow.right", word: "Left")
        case .expired: return StateWord(symbol: "clock.badge.xmark", word: "Invite expired")
        case .invalid: return StateWord(symbol: "exclamationmark.triangle", word: "Unreadable record")
        }
    }
}
