import AppKit
import ShareBarCore
import SwiftUI

/// The popover's one source of truth for the views: the last profiles read, the reducer's
/// `PopoverState`, and the few view-local flags (tenant menu, focused row, flash). Every
/// decision is a call into `ShareBarCore`; this class only wires effects to AppKit.
@MainActor
final class PopoverStore: ObservableObject {
    @Published private(set) var profiles: ProfilesSnapshot?
    @Published private(set) var failure: Failure?
    @Published private(set) var state = PopoverState()
    @Published private(set) var currentProfile: String?
    @Published private(set) var members: [String: MemberList] = [:]
    @Published private(set) var now = Date()
    @Published var tenantMenuOpen = false
    @Published var focusedRow: String?
    /// The focus ring shows for keyboard moves only, as `:focus-visible` does in the prototype.
    @Published private(set) var keyboardFocus = false
    @Published private(set) var flashRow: String?
    @Published private(set) var hoveredRow: String?

    let prefs: PopoverPrefs
    let router: AppRouter
    /// Runs one CLI call; replaced in tests of the view layer, never in the app.
    var runCLI: ([String]) async -> CLIResult = { await CLI.run($0, timeout: 120) }
    /// Re-reads `profiles` after a verb: set by the controller.
    var onChanged: () -> Void = {}
    /// The + button: the controller's file picker and publish dialog.
    var onAddFile: () -> Void = {}
    /// Closes the popover window.
    var onDismiss: () -> Void = {}
    private var visible = false

    init(prefs: PopoverPrefs = PopoverPrefs(), router: AppRouter = .shared) {
        self.prefs = prefs
        self.router = router
    }

    // MARK: derived

    var scope: LinkScope {
        if case .list(let scope, _) = baseMode { return scope }
        return .mine
    }

    var query: String {
        if case .list(_, let query) = baseMode { return query }
        return ""
    }

    private var baseMode: PopoverState.Mode {
        switch state.mode {
        case .menu(_, let prev), .quickLook(_, let prev), .dropTarget(let prev): return prev
        default: return state.mode
        }
    }

    var issues: IssueList {
        IssueList(profiles: profiles, current: currentProfile, members: members, now: now)
    }

    var viewModel: PopoverViewModel {
        PopoverViewModel(
            profiles: profiles, current: currentProfile, scope: scope, query: query,
            recentCount: prefs.recentCount, needCount: issues.count, now: now
        )
    }

    var menuRowID: String? {
        if case .menu(let id, _) = state.mode { return id }
        return nil
    }

    var showsIssues: Bool { state.mode == .issues }
    var isFirstRun: Bool { state.mode == .firstRun }
    var isStale: Bool { failure != nil }
    var undoVisible: Bool { !state.pending.isEmpty }

    // MARK: input

    /// A fresh `profiles` read from the controller.
    func update(profiles: ProfilesSnapshot?, failure: Failure?) {
        self.profiles = profiles
        self.failure = failure
        now = Date()
        let tenants = (profiles?.profiles ?? []).filter { ProfileView(entry: $0).role != .unset }
        let names = tenants.map(\.name)
        if currentProfile == nil || !names.contains(currentProfile ?? "") {
            let stored = prefs.currentProfile
            currentProfile = names.contains(stored ?? "") ? stored : names.first
            applyRememberedScope()
        }
        if profiles != nil {
            send(.profilesChanged(hasRole: !tenants.isEmpty))
        }
    }

    private func applyRememberedScope() {
        guard let profile = currentProfile else { return }
        send(.setScope(prefs.scope(for: profile)))
    }

    func send(_ event: PopoverEvent) {
        let result = state.reduce(event)
        state = result.state
        run(result.effects)
    }

    func setQuery(_ query: String) { send(.setQuery(query)) }

    func setScope(_ scope: LinkScope) {
        guard let profile = currentProfile else { return }
        prefs.setScope(scope, for: profile)
        send(.setScope(scope))
    }

    func selectTenant(_ profile: String) {
        tenantMenuOpen = false
        guard profile != currentProfile else { return }
        currentProfile = profile
        prefs.currentProfile = profile
        focusedRow = nil
        send(.setQuery(""))
        send(.setScope(prefs.scope(for: profile)))
    }

    func showIssues() {
        tenantMenuOpen = false
        send(.showIssues)
    }

    func back() { send(.back) }

    // MARK: rows

    func hover(_ id: String?) { hoveredRow = id }

    func row(_ id: String) -> RowModel? { viewModel.rows.first { $0.id == id } }

    func click(_ row: RowModel) {
        focusedRow = row.id
        keyboardFocus = false
        let result = state.clicked(row, now: Date())
        state = result.state
        run(result.effects)
        if result.flash { flash(row.id) }
    }

    private func flash(_ id: String) {
        flashRow = id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if self?.flashRow == id { self?.flashRow = nil }
        }
    }

    func openMenu(_ id: String) {
        tenantMenuOpen = false
        focusedRow = id
        send(.openMenu(id: id))
    }

    func closeMenu() { send(.menuClosed) }

    func choose(_ action: RowAction, for row: RowModel) {
        send(.menuClosed)
        switch action {
        case .copyLink: click(row)
        case .openInBrowser:
            if let url = URL(string: row.url) { NSWorkspace.shared.open(url) }
        case .showInFinder:
            let path = FinderPath.pub(profile: row.profile, id: row.id)
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } else {
                state.footer = Footer(text: "The file is not on this Mac.", kind: .failure)
            }
        case .refresh:
            run([.run(ProfileArgs.refresh(row.profile, id: row.id))])
        case .remove, .revoke:
            remove(row)
        }
    }

    func remove(_ row: RowModel) {
        guard let next = state.removing(row, now: Date()) else { return }
        state = next
    }

    /// The Delete key.
    func deleteFocused() {
        guard let id = focusedRow, let row = row(id) else { return }
        remove(row)
        let rows = viewModel.rows.map(\.id)
        if let index = rows.firstIndex(of: id) {
            focusedRow = rows.indices.contains(index + 1) ? rows[index + 1] : (index > 0 ? rows[index - 1] : nil)
        }
    }

    func undo() { state = state.undone() }

    func holdUndo(_ held: Bool) { send(.holdUndo(held: held, now: Date())) }

    // MARK: keyboard

    func moveFocus(_ step: Int) {
        keyboardFocus = true
        let ids = viewModel.rows.map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = focusedRow, let index = ids.firstIndex(of: current) else {
            focusedRow = step > 0 ? ids.first : ids.last
            return
        }
        focusedRow = ids[max(0, min(ids.count - 1, index + step))]
    }

    func returnOnFocused() {
        guard let id = focusedRow, let row = row(id) else { return }
        click(row)
    }

    func openMenuOnFocused() {
        guard let id = focusedRow else { return }
        openMenu(id)
    }

    // MARK: clock and lifecycle

    func tick() {
        now = Date()
        send(.tick(now: now))
    }

    var needsClock: Bool { !state.pending.isEmpty || state.footer?.expires != nil || flashRow != nil }

    func opened() {
        visible = true
        tenantMenuOpen = false
    }

    /// The popover closed, or the app is quitting: every pending undo commits at once.
    func closed(commitSynchronously: Bool = false) {
        visible = false
        tenantMenuOpen = false
        focusedRow = nil
        guard commitSynchronously else {
            send(.close)
            return
        }
        // The app is quitting: the calls must finish before the process ends.
        let result = state.reduce(.close)
        state = result.state
        for case .run(let argv) in result.effects {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                _ = await CLI.run(argv, timeout: 20)
                done.signal()
            }
            _ = done.wait(timeout: .now() + 25)
        }
    }

    // MARK: members

    /// The admin's roster, read by Settings > Members when its tab opens and after a member
    /// action (DEC-54). The popover never runs `member ls` itself: its member lines of
    /// needs a look exist once the tab has loaded the roster.
    func setMembers(_ list: MemberList?, for profile: String) {
        if let list { members[profile] = list } else { members[profile] = nil }
    }

    // MARK: effects

    private func run(_ effects: [PopoverEffect]) {
        for effect in effects {
            switch effect {
            case .copy(let text):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case .run(let argv):
                execute(argv)
            case .open(let text):
                if let url = URL(string: text) { NSWorkspace.shared.open(url) }
            case .focus(let id):
                focusedRow = id == "search" ? nil : id
            }
        }
    }

    /// Runs a CLI call, then re-reads `profiles`. A failure puts the CLI's sentence in the footer.
    func execute(_ argv: [String]) {
        let run = runCLI
        Task { @MainActor [weak self] in
            let result = await run(argv)
            guard let self else { return }
            if result.status != 0 {
                self.state.footer = Footer(text: result.lastNonEmptyStderrLine ?? "share exited \(result.status)", kind: .failure)
            }
            self.onChanged()
        }
    }

    // MARK: needs a look

    func perform(_ action: IssueAction) {
        switch action {
        case .copyRequest(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            state.footer = Footer(text: "Copied a renew request for your admin.", kind: .toast, expires: Date().addingTimeInterval(PopoverState.toastSeconds))
        case .open(_, let member), .remove(_, let member):
            router.openSettings(tab: .members, member: member)
        case .openLog:
            router.openSettings(tab: .advanced)
        default:
            if let argv = action.argv { execute(argv) }
        }
    }

    // MARK: routes

    func openSettings(_ tab: SettingsTab) {
        tenantMenuOpen = false
        router.openSettings(tab: tab)
    }

    func openAllLinks() { router.openAllLinks() }
    func openAdd(_ kind: AddSheetKind) { router.openAddSheet(kind: kind) }
}
