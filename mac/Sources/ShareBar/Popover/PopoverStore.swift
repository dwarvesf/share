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
    /// The search field has focus (⌃⌥S, or a click in it).
    @Published var searchFocused = false
    /// The journal step name of each file being published, for the placeholder row.
    @Published var stepNames: [String: String] = [:]
    /// Whether ⌃⌥S registered; General's Shortcut shows `hotkeyStatus.message`.
    @Published var hotkeyStatus: HotkeyStatus = .registered

    let prefs: PopoverPrefs
    let router: AppRouter
    /// Runs one mutating CLI call. The controller points it at the app's `MutationQueue`, so a
    /// popover action never runs beside an add and never carries a timeout that kills a journal.
    var runCLI: ([String]) async -> CLIResult = { await CLI.run($0, timeout: nil) }
    /// Re-reads `profiles` after a verb: set by the controller.
    var onChanged: () -> Void = {}
    /// The + button: the controller's file picker and publish dialog.
    var onAddFile: () -> Void = {}
    /// Closes the popover window.
    var onDismiss: () -> Void = {}
    /// Opens the popover when a drop or a picked file needs the first-run panel on screen.
    var onReveal: () -> Void = {}
    /// Runs one `add` with `SHARE_PROGRESS=1`, streaming the journal's text to the second argument.
    var runPublish: ([String], @escaping @Sendable (String) -> Void) async -> CLIResult = { argv, out in
        await CLI.spawnCancellable(argv, environment: ["SHARE_PROGRESS": "1", "SHARE_ERROR_JSON": "1"], onOutput: out).result
    }
    private var visible = false
    /// General's After sharing and Notify me when, read at the moment they matter.
    var general = GeneralPrefs()
    /// Posts one notification; the app points it at `Notifier`, tests and shots leave it empty.
    var notify: (NotifyEvent) -> Void = { _ in }
    private var attention = AttentionNotifier()

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

    /// Loading, CLI missing, CLI too old: bodies that replace the list (the first-run panel is `isFirstRun`).
    var appState: AppState { AppState.of(profiles: profiles, failure: failure) }

    /// `Working: add (3/6)` for a journaled command another process runs; our own publishes show their placeholder rows.
    var workingLine: String? {
        guard state.publishing.isEmpty else { return nil }
        return WorkingLine.text(for: profiles?.profiles.first { $0.name == currentProfile })
    }

    /// The panel's button: puts the command on the pasteboard and says so.
    func copyCommand(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        state.footer = Footer(text: "Copied. Paste it in Terminal.", kind: .toast, expires: Date().addingTimeInterval(PopoverState.toastSeconds))
    }
    var undoVisible: Bool { !state.pending.isEmpty }

    // MARK: input

    /// A fresh `profiles` read from the controller.
    #if DEBUG
    /// Screenshot scenes only: holds the state a scene set against the controller's own reads.
    var shotsFrozen = false

    func freezeForShots(profiles: ProfilesSnapshot?, failure: Failure?) {
        shotsFrozen = true
        self.profiles = profiles
        self.failure = failure
        send(.profilesChanged(hasRole: profiles.map { !$0.profiles.isEmpty } ?? false))
    }
    #endif

    func update(profiles: ProfilesSnapshot?, failure: Failure?) {
        #if DEBUG
        if shotsFrozen { return }
        #endif
        let before = viewModel.rows.map(\.id)
        defer {
            // Focus follows the row's id, never its position: a refresh that reorders rows keeps it.
            if let focused = focusedRow {
                focusedRow = RowFocus.restored(previous: focused, previousIndex: before.firstIndex(of: focused), ids: viewModel.rows.map(\.id))
            }
        }
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
        notifyAttention()
    }

    /// Notify me when: what is newly true since the last read, for the toggles that are on.
    private func notifyAttention() {
        for event in attention.events(profiles: profiles, members: members, prefs: general.notifyPrefs, current: currentProfile) { notify(event) }
    }

    private func applyRememberedScope() {
        guard let profile = currentProfile else { return }
        send(.setScope(prefs.scope(for: profile)))
    }

    func send(_ event: PopoverEvent) {
        let result = state.reduceRestoringFocus(event)
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

    func flash(_ id: String) {
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

    /// A bulk Remove from the All links window: one `pending` entry for every id, with its Undo.
    func removeBulk(ids: [String], argv: [String], message: String) {
        let now = Date()
        var next = state.reduce(.remove(action: .bulkRemove, ids: ids, argv: argv, now: now, message: message)).state
        next.footer = Footer(text: message, kind: .toast, expires: now.addingTimeInterval(Undo.window))
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
        searchFocused = false
        focusedRow = RowFocus.moved(from: focusedRow, step: step, ids: viewModel.rows.map(\.id)) ?? focusedRow
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
        pollDragOut()
        now = Date()
        send(.tick(now: now))
    }

    var needsClock: Bool { !state.pending.isEmpty || state.footer?.expires != nil || flashRow != nil || state.draggingOut != nil }

    func opened() {
        visible = true
        tenantMenuOpen = false
    }

    /// The popover closed, or the app is quitting: every pending undo commits at once.
    func closed(commitSynchronously: Bool = false) {
        visible = false
        tenantMenuOpen = false
        searchFocused = false
        focusedRow = nil
        guard commitSynchronously else {
            send(.popoverClosed)
            return
        }
        // The app is quitting: the calls must finish before the process ends, within one bound.
        let result = state.reduce(.close)
        state = result.state
        let calls = result.effects.compactMap { effect -> [String]? in
            if case .run(let argv) = effect { return argv }
            return nil
        }
        guard !calls.isEmpty else { return }
        let done = DispatchSemaphore(value: 0)
        let run = runCLI
        Task.detached {
            for argv in calls { _ = await run(argv) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
    }

    // MARK: publish and drop

    /// The current tenant's host and where a dropped file will live, for the overlay.
    var dropOverlay: DropOverlayModel? {
        guard case .dropTarget = state.mode else { return nil }
        let entry = profiles?.profiles.first { $0.name == currentProfile }
        return DropOverlayModel(host: entry?.state?.host ?? currentProfile ?? "Share Bar", storedOn: DropOverlayModel.storedOn(entry?.state))
    }

    /// The placeholder rows of files being published, newest first.
    var uploadRows: [UploadRow] {
        state.publishing.reversed().map { UploadRow(publish: $0, stepName: stepNames[$0.file]) }
    }

    func dragEntered() { send(.dragEnter) }
    func dragLeft() { send(.dragLeave) }

    /// Files released on the status item or the popover (`dropTarget`), or chosen with +.
    func publish(paths: [String], dropped: Bool) {
        var seen = Set(state.publishing.map(\.file))
        let paths = paths.filter { seen.insert($0).inserted }
        guard !paths.isEmpty else {
            if case .dropTarget = state.mode { send(.dragLeave) }
            return
        }
        if isFirstRun {
            send(dropped ? .drop(file: paths[0], of: 0) : .publishStarted(file: paths[0]))
            return
        }
        guard let profile = currentProfile else {
            // Profiles have not loaded: no placeholder, no add, an answer in the footer.
            if case .dropTarget = state.mode { send(.dragLeave) }
            state.footer = Footer(text: "Couldn't publish: Share Bar has not read your tenants yet. Try again in a moment.", kind: .failure)
            return
        }
        for (index, path) in paths.enumerated() {
            if dropped, index == 0 { send(.drop(file: path, of: 0)) } else { send(.publishStarted(file: path)) }
        }
        if case .dropTarget = state.mode { send(.dragLeave) }
        Task { @MainActor [weak self] in
            for path in paths { await self?.runAdd(path: path, profile: profile) }
        }
    }

    private func runAdd(path: String, profile: String) async {
        guard let argv = PublishChoice.args(profile: profile, rule: nil, path: path) else {
            send(.publishFinished(file: path, result: .failed(sentence: "Couldn't publish: \(path) is not a file path."), now: Date()))
            return
        }
        let before = Set(rows(of: profile).map(\.id))
        let relay = ProgressRelay { [weak self] line in
            Task { @MainActor in
                guard let self, self.state.publishing.contains(where: { $0.file == path }),
                      let parsed = PublishProgress.parse(line), parsed.verb == "add" else { return }
                self.stepNames[path] = parsed.name
                if let event = PublishProgress.event(file: path, line: line) { self.send(event) }
            }
        }
        let result = await runPublish(argv) { relay.feed($0) }
        onChanged()
        // The CLI prints no link on some versions: the new row is the one the re-read adds.
        let fresh = result.status == 0 && !hasPrintedLink(result.stdout)
            ? await newRowURL(profile: profile, before: before, title: (path as NSString).lastPathComponent) : nil
        stepNames[path] = nil
        let outcome = PublishOutcome.result(status: result.status, stdout: result.stdout, stderr: result.stderr, fallbackURL: fresh?.url)
        // After sharing: Copy the link and Show a notification, each its own toggle.
        var shown = outcome
        if case .copied = outcome, !general.copyAfterSharing { shown = .copied(url: "") }
        send(.publishFinished(file: path, result: shown, now: Date()))
        if case .copied(let url) = outcome {
            if general.copyAfterSharing, let id = fresh?.id { flash(id) }
            if general.notifyAfterSharing {
                let name = (path as NSString).lastPathComponent
                notify(NotifyEvent(key: "shared:\(path)", title: general.copyAfterSharing ? "Link copied" : "Published", body: url.isEmpty ? name : "\(name): \(url)"))
            }
        }
    }

    private func hasPrintedLink(_ stdout: String) -> Bool {
        stdout.split(separator: "\n").contains { $0.hasPrefix("https://") || $0.hasPrefix("http://") }
    }

    private func rows(of profile: String) -> [Share] {
        profiles?.profiles.first { $0.name == profile }?.state?.shares ?? []
    }

    /// Waits for the post-publish re-read (a few polls), then returns the row it added.
    private func newRowURL(profile: String, before: Set<String>, title: String) async -> (id: String, url: String)? {
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let added = rows(of: profile).filter { !before.contains($0.id) }
            if let share = added.first(where: { $0.name == title }) ?? added.first { return (share.id, share.url) }
        }
        return nil
    }

    // MARK: drag out

    func dragPayload(for row: RowModel) -> DragPayload? { DragPayload(row: row) }

    func beginDragOut(_ row: RowModel) -> NSItemProvider {
        guard let payload = DragPayload(row: row) else { return NSItemProvider() }
        send(.dragOutBegan(id: row.id))
        return payload.itemProvider()
    }

    /// The drag ends when the button is up: SwiftUI's `onDrag` has no end callback (decision D18).
    func pollDragOut() {
        if state.draggingOut != nil, NSEvent.pressedMouseButtons == 0 { send(.dragOutEnded) }
    }

    var dragOutHint: String? { state.dragOutHint(rows: viewModel.rows) }

    // MARK: Quick Look

    #if DEBUG
    /// Every row of the current tenant, unfiltered by the recent count, for the screenshot hook.
    func allRowsForShots() -> [RowModel] {
        PopoverViewModel(profiles: profiles, current: currentProfile, scope: .mine, query: "", recentCount: 50, needCount: 0, now: now).rows
    }
    #endif

    var quickLook: QuickLookModel? {
        guard case .quickLook(let id, _) = state.mode, let row = row(id) else { return nil }
        return QuickLookModel(row: row)
    }

    /// Copy link in Quick Look: copies like a click, then closes and hands focus back to the row.
    func copyFromQuickLook(rowID: String) {
        if let row = row(rowID) { click(row) }
        send(.closeQuickLook)
    }

    func toggleQuickLookOnFocused() {
        guard let id = focusedRow, row(id) != nil else { return }
        send(.toggleQuickLook(id: id))
    }

    // MARK: members

    /// The admin's roster, read by Settings > Members when its tab opens and after a member
    /// action (DEC-54). The popover never runs `member ls` itself: its member lines of
    /// needs a look exist once the tab has loaded the roster.
    func setMembers(_ list: MemberList?, for profile: String) {
        if let list { members[profile] = list } else { members[profile] = nil }
        notifyAttention()
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
                guard visible else { break }
                searchFocused = id == "search"
                focusedRow = id == "search" ? nil : id
                if id != "search" { keyboardFocus = true }
            case .reveal:
                onReveal()
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

/// Turns a stream of text chunks into whole lines for `onLine`; callable from any thread.
final class ProgressRelay: @unchecked Sendable {
    private var buffer = ProgressScanner()
    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func feed(_ chunk: String) {
        lock.lock()
        let lines = buffer.feed(chunk)
        lock.unlock()
        for line in lines { onLine(line) }
    }
}
