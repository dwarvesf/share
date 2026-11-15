import AppKit
import Combine
import ShareBarCore
import SwiftUI

/// The All links window's state: a tab, a query and a selection over the popover's last
/// `profiles` read. It holds no CLI state of its own: a bulk Remove joins the popover's one
/// `pending` list (DEC-70), so its Undo, its clock and its single `rm <id>...` are the popover's.
@MainActor
final class AllLinksStore: ObservableObject {
    @Published var state = AllLinksState()
    /// A short confirmation that replaces the footer line (Copied 3 links).
    @Published private(set) var toast: String?
    let popover: PopoverStore
    private var cancellable: AnyCancellable?
    private var toastTask: Task<Void, Never>?

    init(popover: PopoverStore) {
        self.popover = popover
        cancellable = popover.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var entry: ProfileEntry? {
        let profiles = popover.profiles?.profiles ?? []
        return profiles.first { $0.name == popover.currentProfile } ?? profiles.first
    }

    var model: AllLinksModel { AllLinksModel(entry: entry, state: state, now: Date()) }

    /// The window opened: search first, selection cleared, the Undo clock running while one is open.
    func opened() {
        state = AllLinksState()
        toast = nil
    }

    func setQuery(_ text: String) { state.query = text }

    /// One row's Copy button; the sentence is the popover's own for that link state.
    func copy(_ row: AllLinksRow) {
        let outcome = LinkClick.outcome(for: row.row)
        if outcome.copies, row.canCopy { write(row.row.url) }
        say(outcome.message)
    }

    func bulkCopy() {
        let model = self.model
        let count = model.bulkCopyCount
        guard count > 0 else { return }
        write(model.bulkCopyText)
        say(AllLinksModel.copiedSentence(count))
        state.clear()
    }

    func bulkRemove() {
        let model = self.model
        guard let argv = model.bulkRemoveArgv else { return }
        popover.removeBulk(ids: model.bulkRemovable.map(\.id), argv: argv, message: model.bulkRemoveSentence)
        state.clear()
    }

    func undo() { popover.undo() }

    /// The Undo toast of a pending removal, when one is open: its text and whether Undo shows.
    var pendingToast: String? { popover.undoVisible ? popover.state.footer?.text : nil }

    func tick() { if popover.needsClock { popover.tick() } }

    private func write(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func say(_ text: String) {
        toast = text
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(PopoverState.toastSeconds * 1_000_000_000))
            if !Task.isCancelled { self?.toast = nil }
        }
    }
}
