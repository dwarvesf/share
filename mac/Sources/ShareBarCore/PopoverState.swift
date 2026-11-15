import Foundation

/// A remove, revoke or bulk remove that waits for its Undo window before the CLI runs
/// (gap G1, DEC-70). Not a navigation mode: it rides in `PopoverState.pending`.
public struct Undo: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case remove, revoke, bulkRemove
    }

    /// Seconds the Undo stays open before the verb runs (interactions doc, section 3).
    public static let window: TimeInterval = 6

    public let action: Action
    public let ids: [String]
    /// The argv the deadline runs, built by the caller (`rm <id>...` on the right profile).
    public let argv: [String]
    public let deadline: Date

    public init(action: Action, ids: [String], argv: [String], deadline: Date) {
        self.action = action
        self.ids = ids
        self.argv = argv
        self.deadline = deadline
    }
}

/// A file being published, shown as a placeholder row with its step.
public struct Publish: Sendable, Equatable {
    public let file: String
    public let step: Int
    public let of: Int

    public init(file: String, step: Int, of: Int) {
        self.file = file
        self.step = step
        self.of = of
    }
}

/// How a publish ended.
public enum PublishResult: Sendable, Equatable {
    /// The link, copied when the row lands.
    case copied(url: String)
    /// The CLI's sentence, shown in the footer.
    case failed(sentence: String)
}

/// The footer status line, or the toast that replaces it.
public struct Footer: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case toast, failure
    }

    public let text: String
    public let kind: Kind
    /// A toast clears at this time; a failure stays until the next toast or a dismiss.
    public let expires: Date?

    public init(text: String, kind: Kind, expires: Date? = nil) {
        self.text = text
        self.kind = kind
        self.expires = expires
    }
}

/// Everything that moves the popover (gap G1, DEC-44, DEC-70).
public enum PopoverEvent: Sendable, Equatable {
    /// The profile list changed: `hasRole` is whether any profile has a role other than `none`.
    case profilesChanged(hasRole: Bool)
    case setQuery(String)
    case setScope(LinkScope)
    /// The footer's "N need a look" button.
    case showIssues
    case back
    case escape
    /// Control-Option-S.
    case hotkey
    case dragEnter
    case dragLeave
    case drop(file: String, of: Int)
    /// Right click, More, the ContextMenu key, Shift-F10.
    case openMenu(id: String)
    /// An item was chosen, or the menu closed by a scroll or a click outside.
    case menuClosed
    /// Space on a focused row, or Space again in Quick Look.
    case toggleQuickLook(id: String)
    case closeQuickLook
    case quickLookCopy(url: String)
    case quickLookOpen(url: String)
    /// Click or Return on a row that may copy.
    case copyLink(url: String)
    case remove(action: Undo.Action, ids: [String], argv: [String], now: Date)
    /// The Undo button or Command-Z: cancels the newest pending undo, no CLI call.
    case undo
    /// The clock: runs every pending undo past its deadline, clears a lapsed toast. While the
    /// Undo button has focus nothing runs and nothing clears (TASK-4b9).
    case tick(now: Date)
    /// Focus entered (`held`) or left the Undo button. Leaving restarts every pending
    /// undo's window, so a person who tabbed away still has the full 6 s.
    case holdUndo(held: Bool, now: Date)
    /// The popover closed, or the app is quitting: every pending undo commits at once.
    case close
    case publishStep(file: String, step: Int, of: Int)
    case publishFinished(file: String, result: PublishResult, now: Date)
}

/// A side effect as a value, so a test asserts what the reducer asked for and never
/// what ran: an undone Remove never emits `run`.
public enum PopoverEffect: Sendable, Equatable {
    case run([String])
    case copy(String)
    case focus(String)
    case open(String)
}

/// The popover's state machine: one navigation mode plus the two fields every mode
/// handles, `pending` undos and `publishing` uploads. `reduce` is pure.
public struct PopoverState: Sendable, Equatable {
    /// The six navigation modes. `dropTarget`, `menu` and `quickLook` remember where they
    /// came from so leaving returns there.
    public indirect enum Mode: Sendable, Equatable {
        case firstRun
        case list(scope: LinkScope, query: String)
        case issues
        case dropTarget(prev: Mode)
        case menu(id: String, prev: Mode)
        case quickLook(id: String, prev: Mode)

        public var kind: Kind {
            switch self {
            case .firstRun: return .firstRun
            case .list: return .list
            case .issues: return .issues
            case .dropTarget: return .dropTarget
            case .menu: return .menu
            case .quickLook: return .quickLook
            }
        }
    }

    /// A mode without its payload: the names of the spec's mode table.
    public enum Kind: String, CaseIterable, Sendable {
        case firstRun, list, issues, dropTarget, menu, quickLook
    }

    public var mode: Mode
    public var pending: [Undo]
    public var publishing: [Publish]
    public var footer: Footer?
    /// True while the Undo button has focus.
    public var undoHeld = false

    public static let toastSeconds: TimeInterval = 3.5

    public init(
        mode: Mode = .list(scope: .mine, query: ""),
        pending: [Undo] = [],
        publishing: [Publish] = [],
        footer: Footer? = nil
    ) {
        self.mode = mode
        self.pending = pending
        self.publishing = publishing
        self.footer = footer
    }

    /// The list a mode sits over: where `Back` and a closing menu land.
    private var base: Mode {
        switch mode {
        case .dropTarget(let prev), .menu(_, let prev), .quickLook(_, let prev): return prev
        default: return mode
        }
    }

    /// The scope and query of the list beneath the current mode, for `hotkey` and `close`.
    private var listContext: (scope: LinkScope, query: String)? {
        var current = base
        while true {
            switch current {
            case .list(let scope, let query): return (scope, query)
            case .dropTarget(let prev), .menu(_, let prev), .quickLook(_, let prev): current = prev
            case .firstRun, .issues: return nil
            }
        }
    }

    public func reduce(_ event: PopoverEvent) -> (state: PopoverState, effects: [PopoverEffect]) {
        var next = self
        var effects: [PopoverEffect] = []
        next.apply(event, effects: &effects)
        return (next, effects)
    }

    private mutating func apply(_ event: PopoverEvent, effects: inout [PopoverEffect]) {
        switch event {
        case .profilesChanged(let hasRole):
            if !hasRole {
                mode = .firstRun
            } else if mode == .firstRun {
                mode = .list(scope: .mine, query: "")
            }

        case .setQuery(let query):
            if case .list(let scope, _) = mode { mode = .list(scope: scope, query: query) }

        case .setScope(let scope):
            if case .list(_, let query) = mode { mode = .list(scope: scope, query: query) }

        case .showIssues:
            if case .list = mode { mode = .issues }

        case .back:
            if mode == .issues { mode = .list(scope: .mine, query: "") }

        case .escape:
            switch mode {
            case .issues: mode = .list(scope: .mine, query: "")
            case .menu(_, let prev), .quickLook(_, let prev): mode = prev
            default: break
            }

        case .hotkey:
            // Opens the popover in `list` with the search focused, from anywhere: from
            // `issues`, a menu or Quick Look too. `firstRun` has no list to open.
            guard mode != .firstRun else { break }
            let context = listContext
            mode = .list(scope: context?.scope ?? .mine, query: context?.query ?? "")
            effects.append(.focus("search"))

        case .dragEnter:
            switch mode {
            case .firstRun, .dropTarget: break
            default: mode = .dropTarget(prev: mode)
            }

        case .dragLeave:
            if case .dropTarget(let prev) = mode { mode = prev }

        case .drop(let file, let of):
            if case .dropTarget(let prev) = mode {
                publishing.append(Publish(file: file, step: 0, of: of))
                mode = prev
            }

        case .openMenu(let id):
            if case .list = mode { mode = .menu(id: id, prev: mode) }

        case .menuClosed:
            if case .menu(_, let prev) = mode { mode = prev }

        case .toggleQuickLook(let id):
            switch mode {
            case .list: mode = .quickLook(id: id, prev: mode)
            case .quickLook(_, let prev): mode = prev
            default: break
            }

        case .closeQuickLook:
            if case .quickLook(_, let prev) = mode { mode = prev }

        case .quickLookCopy(let url):
            if case .quickLook(_, let prev) = mode {
                mode = prev
                effects.append(.copy(url))
            }

        case .quickLookOpen(let url):
            if case .quickLook(_, let prev) = mode {
                mode = prev
                effects.append(.open(url))
            }

        case .copyLink(let url):
            effects.append(.copy(url))

        case .remove(let action, let ids, let argv, let now):
            pending.append(Undo(action: action, ids: ids, argv: argv, deadline: now.addingTimeInterval(Undo.window)))

        case .undo:
            if !pending.isEmpty { pending.removeLast() }

        case .holdUndo(let held, let now):
            undoHeld = held
            if !held {
                pending = pending.map { Undo(action: $0.action, ids: $0.ids, argv: $0.argv, deadline: now.addingTimeInterval(Undo.window)) }
                if footer?.expires != nil, !pending.isEmpty { footer = Footer(text: footer?.text ?? "", kind: .toast, expires: now.addingTimeInterval(Undo.window)) }
            }

        case .tick(let now):
            if undoHeld, !pending.isEmpty { break }
            let due = pending.filter { $0.deadline <= now }
            pending.removeAll { $0.deadline <= now }
            effects.append(contentsOf: due.map { .run($0.argv) })
            if let expires = footer?.expires, expires <= now { footer = nil }

        case .close:
            effects.append(contentsOf: pending.map { .run($0.argv) })
            pending.removeAll()
            switch mode {
            case .firstRun: break
            default:
                let context = listContext
                mode = .list(scope: context?.scope ?? .mine, query: context?.query ?? "")
            }

        case .publishStep(let file, let step, let of):
            if let index = publishing.firstIndex(where: { $0.file == file }) {
                publishing[index] = Publish(file: file, step: step, of: of)
            }

        case .publishFinished(let file, let result, let now):
            publishing.removeAll { $0.file == file }
            switch result {
            case .copied(let url):
                effects.append(.copy(url))
                footer = Footer(text: "Link copied", kind: .toast, expires: now.addingTimeInterval(PopoverState.toastSeconds))
            case .failed(let sentence):
                footer = Footer(text: sentence, kind: .failure)
            }
        }
    }
}

extension PopoverState {
    /// One row of the spec's transition table, as the reducer implements it. `clause` is
    /// the words of the spec's cell this row covers; the test checks both against the
    /// spec file and runs `event` from `from`.
    public struct Transition: Sendable {
        public enum Column: Sendable { case entered, left }

        public let mode: Kind
        public let column: Column
        public let clause: String
        public let from: PopoverState
        public let event: PopoverEvent
        public let to: Kind
    }

    /// The spec's `### Components & states` mode table, `Entered by` and `Left by` cells
    /// verbatim. A test reads the spec file and compares.
    public static let specTable: [Kind: (entered: String, left: String)] = [
        .firstRun: ("every profile has `role` `none`", "a profile gains a role"),
        .list: ("default; Back from `issues`; ⌃⌥S", "footer button, a drag entering (`dropTarget`)"),
        .issues: ("the footer \"N need a look\"", "Back, Esc, ⌃⌥S"),
        .dropTarget: (
            "an outside file drag enters the status item or the popover",
            "release (append to `publishing`, back to `prev`), leave (back to `prev`)"
        ),
        .menu: ("right click, More, the ContextMenu key, Shift-F10", "an item, Esc, a scroll, a click outside"),
        .quickLook: ("Space on a focused row", "Space, Esc, Close, Copy link, Open in browser"),
    ]

    /// Every transition of the table, one row per clause, each run by the tests.
    public static let transitions: [Transition] = {
        let list = PopoverState()
        let issues = PopoverState(mode: .issues)
        let dragging = PopoverState(mode: .dropTarget(prev: list.mode))
        let menu = PopoverState(mode: .menu(id: "a1", prev: list.mode))
        let look = PopoverState(mode: .quickLook(id: "a1", prev: list.mode))
        let first = PopoverState(mode: .firstRun)
        return [
            Transition(mode: .firstRun, column: .entered, clause: "every profile has `role` `none`", from: list, event: .profilesChanged(hasRole: false), to: .firstRun),
            Transition(mode: .firstRun, column: .left, clause: "a profile gains a role", from: first, event: .profilesChanged(hasRole: true), to: .list),
            Transition(mode: .list, column: .entered, clause: "default", from: first, event: .profilesChanged(hasRole: true), to: .list),
            Transition(mode: .list, column: .entered, clause: "Back from `issues`", from: issues, event: .back, to: .list),
            Transition(mode: .list, column: .entered, clause: "⌃⌥S", from: issues, event: .hotkey, to: .list),
            Transition(mode: .list, column: .left, clause: "footer button", from: list, event: .showIssues, to: .issues),
            Transition(mode: .list, column: .left, clause: "a drag entering (`dropTarget`)", from: list, event: .dragEnter, to: .dropTarget),
            Transition(mode: .issues, column: .entered, clause: "the footer \"N need a look\"", from: list, event: .showIssues, to: .issues),
            Transition(mode: .issues, column: .left, clause: "Back", from: issues, event: .back, to: .list),
            Transition(mode: .issues, column: .left, clause: "Esc", from: issues, event: .escape, to: .list),
            Transition(mode: .issues, column: .left, clause: "⌃⌥S", from: issues, event: .hotkey, to: .list),
            Transition(mode: .dropTarget, column: .entered, clause: "an outside file drag enters the status item or the popover", from: list, event: .dragEnter, to: .dropTarget),
            Transition(mode: .dropTarget, column: .left, clause: "release (append to `publishing`, back to `prev`)", from: dragging, event: .drop(file: "/tmp/a.pdf", of: 1), to: .list),
            Transition(mode: .dropTarget, column: .left, clause: "leave (back to `prev`)", from: dragging, event: .dragLeave, to: .list),
            Transition(mode: .menu, column: .entered, clause: "right click, More, the ContextMenu key, Shift-F10", from: list, event: .openMenu(id: "a1"), to: .menu),
            Transition(mode: .menu, column: .left, clause: "an item, Esc, a scroll, a click outside", from: menu, event: .menuClosed, to: .list),
            Transition(mode: .menu, column: .left, clause: "an item, Esc, a scroll, a click outside", from: menu, event: .escape, to: .list),
            Transition(mode: .quickLook, column: .entered, clause: "Space on a focused row", from: list, event: .toggleQuickLook(id: "a1"), to: .quickLook),
            Transition(mode: .quickLook, column: .left, clause: "Space", from: look, event: .toggleQuickLook(id: "a1"), to: .list),
            Transition(mode: .quickLook, column: .left, clause: "Esc", from: look, event: .escape, to: .list),
            Transition(mode: .quickLook, column: .left, clause: "Close", from: look, event: .closeQuickLook, to: .list),
            Transition(mode: .quickLook, column: .left, clause: "Copy link", from: look, event: .quickLookCopy(url: "https://s.example.test/a1/x"), to: .list),
            Transition(mode: .quickLook, column: .left, clause: "Open in browser", from: look, event: .quickLookOpen(url: "https://s.example.test/a1/x"), to: .list),
        ]
    }()
}
