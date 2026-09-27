import AppKit
import ServiceManagement
import ShareBarCore
import os

private let actionLogger = Logger(subsystem: "foundation.d.share.bar", category: "actions")

/// Carries a non-Sendable AppKit value across a Task boundary when the caller already
/// guarantees (as here) that it's only ever touched back on the main thread.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A row's submenu, tagged with the share id it belongs to and holding a direct reference
/// to its "Loading…" item, so `menuWillOpen`/hits completion can address it without a
/// lookup table keyed by menu identity.
private final class RowMenu: NSMenu {
    let rowID: String
    let hitsItem: NSMenuItem

    init(rowID: String, hitsItem: NSMenuItem) {
        self.rowID = rowID
        self.hitsItem = hitsItem
        super.init(title: "")
    }

    required init(coder: NSCoder) {
        fatalError("RowMenu does not support NSCoding")
    }
}

/// Owns the status item and its menu: builds a plain `NSMenu` from the latest `MenuModel`,
/// keeps it current on a 60s timer, on wake, and on every open, and applies the icon.
///
/// Rendering (TASK-008) plus the read and app actions (TASK-009): Copy Link, Open in
/// Browser, lazy per-row hit counts, Set Up…, Copy Install/Upgrade Command, Open at Login,
/// and Quit. The mutating actions (TASK-017): Refresh, Remove… (confirm), Start/Stop
/// Sharing, Share File…, the "Working…"/Stop Waiting header state, and the private-repo and
/// not-serving-here alerts. The drop target (TASK-010) reuses the same add path.
// @unchecked Sendable: every mutable property is only ever touched on the main thread (init,
// or a block scheduled through `RunLoop.main.perform(inModes:)`); this just tells the
// compiler what's already true so the refresh closure doesn't need a warning suppressed
// some other way.
final class StatusItemController: NSObject, @unchecked Sendable {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let mutationQueue = MutationQueue()

    private var model = MenuModel(snapshot: nil, failure: nil, now: Date())
    private var isRefreshing = false
    private var pollTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    // MARK: - Mutating-verb state (TASK-017)

    /// The last `state` read, kept alongside `model` so a mutation's start/end can rebuild
    /// `MenuModel` with a new `isMutating` flag without re-reading `state`.
    private var currentSnapshot: Snapshot?
    private var currentFailure: Failure?
    private var isMutating = false
    private var showStopWaitingItem = false
    private var stopWaitingTimer: Timer?
    private var checkmarkRevertTimer: Timer?

    // MARK: - Lazy hits state

    /// One call in flight at a time; a new submenu opening cancels whatever was running.
    private var currentHitsJob: CLIJob?
    private var currentHitsRowID: String?
    /// Bumped on every `requestHits` call; a completion whose generation no longer matches
    /// belonged to a cancelled or superseded call and is discarded rather than applied or
    /// cached (it may carry killed-process garbage, not a real hits line).
    private var hitsGeneration = 0
    /// Cleared when the top-level menu closes, per the spec ("cached until the menu closes").
    private var hitsCache: [String: String] = [:]

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        // Renders the "Loading…" placeholder instantly so the item never opens empty; the
        // first real `state` call (kicked off below) replaces it in place when it returns.
        applyModel()
        startPolling()
        observeWake()
        triggerRefresh()
    }

    deinit {
        pollTimer?.invalidate()
        stopWaitingTimer?.invalidate()
        checkmarkRevertTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    // MARK: - Polling and wake

    private func startPolling() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.triggerRefresh()
        }
        // .common, not the default mode, so the tick still fires while the menu is open
        // (NSMenu tracking runs its own run loop mode).
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.triggerRefresh()
        }
    }

    // MARK: - Refresh

    /// Runs `share state`, then applies the result on the main run loop in common modes, so
    /// an already-open menu still updates in place. Concurrent triggers collapse to the
    /// `state` call already in flight (`CLI.state()` coalesces); this guard just skips
    /// spawning a second `MenuModel` rebuild on top of one already pending.
    private func triggerRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { [weak self] in
            let result = await CLI.state()
            guard let self else { return }
            let snapshot: Snapshot?
            let failure: Failure?
            switch Snapshot.from(result) {
            case .success(let value):
                snapshot = value
                failure = nil
            case .failure(let value):
                snapshot = nil
                failure = value
            }
            RunLoop.main.perform(inModes: [.common]) {
                self.currentSnapshot = snapshot
                self.currentFailure = failure
                self.isRefreshing = false
                self.rebuildModel()
            }
        }
    }

    /// Rebuilds `model` from the last `state` read plus the current mutating-verb flag,
    /// then re-renders. The one place both inputs to `MenuModel` come together, so a
    /// mutation's start/end can flip the header to/from "Working…" without a fresh `state`
    /// call, and a fresh `state` result can land without losing that flag.
    private func rebuildModel() {
        model = MenuModel(snapshot: currentSnapshot, failure: currentFailure, now: Date(), isMutating: isMutating)
        applyModel()
    }

    // MARK: - Rendering

    private func applyModel() {
        if let button = statusItem.button {
            StatusIcon.apply(model.icon, to: button)
            button.setAccessibilityLabel(model.header)
        }

        menu.removeAllItems()

        let headerItem = NSMenuItem(title: model.header, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        if showStopWaitingItem {
            menu.addItem(actionItem("Stop Waiting", action: #selector(stopWaiting)))
        }
        menu.addItem(.separator())

        // The trailing column (`2d left`, `live`, `never`, `expired`) right-aligns at a tab
        // stop past the widest row title in this render, so it reads as one column instead
        // of drifting per row.
        let font = NSFont.menuFont(ofSize: 0)
        let tabLocation = rowTitleTabLocation(for: model.rows, font: font)

        for row in model.rows {
            let item = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
            item.attributedTitle = rowAttributedTitle(row, tabLocation: tabLocation, font: font)
            // AppKit's default accessibility title for a menu item mirrors the rendered
            // `attributedTitle.string` (name + tab + trailing) once one is set, not the
            // plain `title` above; without this override VoiceOver would read
            // "theme-check.md\t2d left" instead of just the name.
            item.setAccessibilityTitle(row.title)
            item.submenu = submenu(for: row)
            menu.addItem(item)
        }

        if model.more > 0 {
            let moreItem = NSMenuItem(title: "\(model.more) more (share ls)", action: nil, keyEquivalent: "")
            moreItem.isEnabled = false
            menu.addItem(moreItem)
        }

        menu.addItem(.separator())

        menu.addItem(actionItem("Share File…", action: #selector(shareFile), keyEquivalent: "n"))

        if model.showStop {
            menu.addItem(actionItem("Stop Sharing", action: #selector(stopSharing)))
        } else if model.showStart {
            menu.addItem(actionItem("Start Sharing", action: #selector(startSharing)))
        }

        menu.addItem(.separator())

        if model.showSetUp {
            menu.addItem(actionItem("Set Up…", action: #selector(setUp)))
        }
        if model.showCopyInstallCommand {
            menu.addItem(actionItem("Copy Install Command", action: #selector(copyInstallCommand)))
        }
        if model.showCopyUpgradeCommand {
            menu.addItem(actionItem("Copy Upgrade Command", action: #selector(copyUpgradeCommand)))
        }

        menu.addItem(openAtLoginItem())

        let quitItem = NSMenuItem(title: "Quit Share Bar", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// Widest row title, plus fixed padding so the tab stop clears it, in points.
    private func rowTitleTabLocation(for rows: [Row], font: NSFont) -> CGFloat {
        let padding: CGFloat = 24
        let widest = rows.reduce(into: CGFloat(0)) { widest, row in
            let width = (row.title as NSString).size(withAttributes: [.font: font]).width
            widest = max(widest, width)
        }
        return widest + padding
    }

    /// The name in the plain font/color, a tab, then the trailing text right-aligned at
    /// `tabLocation` in `secondaryLabelColor` (macOS's shortcut-hint grey). `item.title` is
    /// still set to the plain name (see `applyModel`) so accessibility reads the name alone.
    private func rowAttributedTitle(_ row: Row, tabLocation: CGFloat, font: NSFont) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.tabStops = [NSTextTab(textAlignment: .right, location: tabLocation, options: [:])]
        paragraphStyle.defaultTabInterval = tabLocation

        let result = NSMutableAttributedString(
            string: row.title,
            attributes: [.font: font, .paragraphStyle: paragraphStyle]
        )
        result.append(NSAttributedString(
            string: "\t\(row.trailing)",
            attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle,
            ]
        ))
        return result
    }

    private func submenu(for row: Row) -> NSMenu {
        let hitsItem = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
        hitsItem.isEnabled = false

        let submenu = RowMenu(rowID: row.id, hitsItem: hitsItem)
        submenu.autoenablesItems = false
        submenu.delegate = self

        let copyItem = actionItem("Copy Link", action: #selector(copyLink))
        copyItem.isEnabled = row.canCopy
        copyItem.representedObject = row
        submenu.addItem(copyItem)

        let openItem = actionItem("Open in Browser", action: #selector(openInBrowser))
        openItem.isEnabled = row.canCopy
        openItem.representedObject = row
        submenu.addItem(openItem)

        let refreshItem = actionItem("Refresh", action: #selector(refreshRow))
        refreshItem.isEnabled = row.canRefresh
        refreshItem.representedObject = row
        submenu.addItem(refreshItem)

        submenu.addItem(hitsItem)

        submenu.addItem(.separator())
        let removeItem = actionItem("Remove…", action: #selector(removeRow))
        removeItem.representedObject = row
        submenu.addItem(removeItem)

        return submenu
    }

    /// Reads (never registers on its own) `SMAppService.mainApp.status` every time the menu
    /// renders, i.e. every open. `.requiresApproval` shows the approve-in-Settings wording;
    /// clicking it in that state opens Login Items instead of toggling registration.
    private func openAtLoginItem() -> NSMenuItem {
        let status = SMAppService.mainApp.status
        let title = status == .requiresApproval
            ? "Open at Login (approve in System Settings)"
            : "Open at Login"
        let item = actionItem(title, action: #selector(toggleOpenAtLogin))
        item.state = status == .enabled ? .on : .off
        return item
    }

    private func actionItem(_ title: String, action: Selector = #selector(noOp), keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func noOp() {}

    // MARK: - Row actions

    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Row, row.canCopy else { return }
        actionLogger.log("copy-link id=\(row.id, privacy: .public)")
        setPasteboard(row.url)
    }

    @objc private func openInBrowser(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Row, row.canCopy, let url = URL(string: row.url) else { return }
        actionLogger.log("open-in-browser id=\(row.id, privacy: .public)")
        NSWorkspace.shared.open(url)
    }

    // MARK: - Mutating actions (TASK-017)

    @objc private func refreshRow(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Row, row.canRefresh else { return }
        actionLogger.log("refresh id=\(row.id, privacy: .public)")
        Task { [weak self] in await self?.performMutation(["refresh", row.id], warningShareID: row.id, isAdd: false) }
    }

    @objc private func removeRow(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Row else { return }
        guard confirmRemove(row) else { return }
        actionLogger.log("remove id=\(row.id, privacy: .public)")
        Task { [weak self] in await self?.performMutation(["rm", row.id], warningShareID: nil, isAdd: false) }
    }

    /// Cancel is the default button (added first, so it gets the Return key equivalent and
    /// the rightmost/primary position); Remove is the destructive-styled secondary button.
    private func confirmRemove(_ row: Row) -> Bool {
        let alert = NSAlert()
        alert.messageText = row.removeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        let removeButton = alert.addButton(withTitle: "Remove")
        removeButton.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc private func startSharing() {
        actionLogger.log("start")
        Task { [weak self] in await self?.performMutation(["start"], warningShareID: nil, isAdd: false) }
    }

    @objc private func stopSharing() {
        actionLogger.log("stop")
        Task { [weak self] in await self?.performMutation(["stop"], warningShareID: nil, isAdd: false) }
    }

    @objc private func shareFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Share"
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        Task { [weak self] in await self?.addPaths(paths) }
    }

    @objc private func stopWaiting() {
        let alert = NSAlert()
        alert.messageText = StopWaiting.confirmText
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue Waiting")
        let stopButton = alert.addButton(withTitle: "Stop Waiting")
        stopButton.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        actionLogger.log("stop-waiting confirmed")
        Task { [weak self] in await self?.mutationQueue.cancelCurrent() }
    }

    /// Runs one `add` per path, in order, through the mutation queue: a directory confirms
    /// first (Share File… and a drop both go through this). Awaiting each `performMutation`
    /// in turn (not firing them all at once) matters for the id diff: the next add's
    /// "ids before" must be read after the previous add's `state` re-read has landed, not
    /// from a snapshot captured before the whole batch started (edge case 24). `@MainActor`
    /// for the same reason as `performMutation`: it calls `confirmFolder` (`NSAlert`)
    /// directly, before any `await`, so the whole function must already be main-thread
    /// isolated, not just the parts after a suspension point.
    @MainActor
    private func addPaths(_ paths: [String]) async {
        for path in paths {
            if isDirectory(path) {
                let name = (path as NSString).lastPathComponent
                guard confirmFolder(name: name) else { continue }
            }
            actionLogger.log("add path=\(path, privacy: .public)")
            await performMutation(["add", path], warningShareID: nil, isAdd: true)
        }
    }

    /// Manual-verification-only entry point (`SHAREBAR_DEBUG_ADD_PATHS`, wired in
    /// `AppDelegate`): runs the exact same `addPaths` a real Share File… selection or a
    /// real drop would, so a check can exercise the add/warning/id-diff/checkmark path
    /// deterministically without driving `NSOpenPanel` or a real drag.
    func debugAddPaths(_ paths: [String]) {
        Task { [weak self] in await self?.addPaths(paths) }
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func confirmFolder(name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = FolderConfirm.text(name: name)
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Publish")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Runs one mutating verb through the shared queue: shows "Working…" and (after 60s)
    /// offers Stop Waiting while it runs, re-reads `state` when it finishes, and presents
    /// whatever alert the combined result calls for. `@MainActor` because every await here
    /// must resume back on the main thread (it drives `NSAlert`, `NSOpenPanel`, and the
    /// menu itself) and every caller is already on the main thread when it calls in.
    @MainActor
    private func performMutation(_ args: [String], warningShareID: String?, isAdd: Bool) async {
        let idsBefore: Set<String> = isAdd ? Set((currentSnapshot?.shares ?? []).map(\.id)) : []
        beginMutating()
        let result = await mutationQueue.run(args)
        let stateResult = await CLI.state()
        switch Snapshot.from(stateResult) {
        case .success(let snapshot):
            currentSnapshot = snapshot
            currentFailure = nil
        case .failure(let failure):
            currentSnapshot = nil
            currentFailure = failure
        }
        endMutating()
        handleOutcome(result: result, idsBefore: idsBefore, warningShareID: warningShareID, isAdd: isAdd)
    }

    private func beginMutating() {
        isMutating = true
        showStopWaitingItem = false
        rebuildModel()
        stopWaitingTimer?.invalidate()
        let timer = Timer(timeInterval: StopWaiting.delay, repeats: false) { [weak self] _ in
            self?.showStopWaitingItem = true
            self?.rebuildModel()
        }
        RunLoop.main.add(timer, forMode: .common)
        stopWaitingTimer = timer
    }

    private func endMutating() {
        isMutating = false
        showStopWaitingItem = false
        stopWaitingTimer?.invalidate()
        stopWaitingTimer = nil
        rebuildModel()
    }

    /// Decides (via `MutationOutcome`, in `ShareBarCore`) what alert this result calls for,
    /// finds an add's new share id by diffing against `idsBefore`, and, on a successful add,
    /// copies its url and flashes the checkmark icon (shared with the drop target).
    private func handleOutcome(result: CLIResult, idsBefore: Set<String>, warningShareID: String?, isAdd: Bool) {
        var effectiveWarningID = warningShareID
        if isAdd, result.status == 0, let snapshot = currentSnapshot,
           let newShare = MutationOutcome.newShare(before: idsBefore, after: snapshot.shares) {
            effectiveWarningID = newShare.id
            setPasteboard(newShare.url)
            flashCheckmark()
        }
        let notServingHere = isAdd && result.status == 0 && currentSnapshot?.servesHere == false
        if let alert = MutationOutcome.alert(for: result, warningShareID: effectiveWarningID, notServingHere: notServingHere) {
            present(alert)
        }
    }

    private func present(_ alert: MutationAlert) {
        let nsAlert = NSAlert()
        nsAlert.messageText = alert.message
        nsAlert.alertStyle = alert.kind == .failure ? .warning : .informational
        switch alert.kind {
        case .failure, .notServingHere:
            nsAlert.addButton(withTitle: "OK")
            nsAlert.runModal()
        case .privateWarning:
            nsAlert.addButton(withTitle: "OK")
            let removeButton = nsAlert.addButton(withTitle: "Remove")
            removeButton.hasDestructiveAction = true
            if nsAlert.runModal() == .alertSecondButtonReturn, let id = alert.removeShareID {
                actionLogger.log("remove-from-warning id=\(id, privacy: .public)")
                Task { [weak self] in await self?.performMutation(["rm", id], warningShareID: nil, isAdd: false) }
            }
        }
    }

    /// Swaps in a plain `checkmark` SF Symbol for 1.5s, then restores whatever icon the
    /// current model calls for. Shared by every successful add (TASK-017's Share File… and
    /// TASK-010's drop).
    private func flashCheckmark() {
        guard let button = statusItem.button else { return }
        if let image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Shared") {
            image.isTemplate = true
            button.image = image
            button.title = ""
        }
        checkmarkRevertTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self, let button = self.statusItem.button else { return }
            StatusIcon.apply(self.model.icon, to: button)
        }
        RunLoop.main.add(timer, forMode: .common)
        checkmarkRevertTimer = timer
    }

    // MARK: - Lazy hits

    /// Called once when a row's submenu is about to display. Serves a cached line
    /// instantly; otherwise cancels whatever hits call was in flight and starts a new one,
    /// with a 15s timeout enforced on top of `spawnCancellable`'s own cancel path.
    private func requestHits(rowID: String, hitsItem: NSMenuItem) {
        if let cached = hitsCache[rowID] {
            hitsItem.title = cached
            return
        }

        cancelHits()
        hitsGeneration += 1
        let generation = hitsGeneration
        currentHitsRowID = rowID

        actionLogger.log("hits spawn id=\(rowID, privacy: .public)")
        let job = CLI.spawnCancellable(["hits", rowID]) { _ in }
        currentHitsJob = job

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            job.cancel()
        }

        // Boxed so the Sendable check on the crossing into the detached Task below doesn't
        // complain about carrying an NSMenuItem; it is only ever read or written back on
        // the main thread, inside the RunLoop.main.perform block, same as `self`'s own
        // mutable state (see the class-level @unchecked Sendable note).
        let boxedHitsItem = UncheckedBox(hitsItem)

        Task { [weak self] in
            let result = await job.result
            timeoutTask.cancel()
            guard let self else { return }
            let line = StatusItemController.hitsLine(from: result)
            RunLoop.main.perform(inModes: [.common]) {
                // A superseded generation means this row's call was cancelled (the user
                // opened another submenu, or the top menu closed): the process was killed
                // mid-flight, so its output is not a real hits line and must not be cached
                // or shown.
                guard self.hitsGeneration == generation else { return }
                self.hitsCache[rowID] = line
                self.currentHitsJob = nil
                self.currentHitsRowID = nil
                boxedHitsItem.value.title = line
            }
        }
    }

    private func cancelHits() {
        guard let job = currentHitsJob else { return }
        if let rowID = currentHitsRowID {
            actionLogger.log("hits cancelled id=\(rowID, privacy: .public)")
        }
        job.cancel()
        currentHitsJob = nil
        currentHitsRowID = nil
    }

    private static func hitsLine(from result: CLIResult) -> String {
        if result.status != 0 {
            let lines = result.stderr.split(separator: "\n", omittingEmptySubsequences: false)
            if let line = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                return String(line)
            }
            return "share exited \(result.status)"
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Other actions

    @objc private func setUp() {
        actionLogger.log("set-up requested")
        SetupWindowController.show { [weak self] in
            self?.triggerRefresh()
        }
    }

    @objc private func copyInstallCommand() {
        actionLogger.log("copy-install-command")
        setPasteboard("brew install dwarvesf/tools/share")
    }

    @objc private func copyUpgradeCommand() {
        actionLogger.log("copy-upgrade-command")
        setPasteboard("brew upgrade dwarvesf/tools/share")
    }

    @objc private func toggleOpenAtLogin() {
        let status = SMAppService.mainApp.status
        actionLogger.log("open-at-login toggled; status=\(String(describing: status), privacy: .public)")
        if status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        do {
            if status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            actionLogger.error("open-at-login toggle failed: \(String(describing: error), privacy: .public)")
        }
        applyModel() // re-reads status immediately so the checkmark reflects the new state
    }

    @objc private func quit() {
        actionLogger.log("quit")
        NSApp.terminate(nil)
    }

    private func setPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

extension StatusItemController: NSMenuDelegate {
    /// Called right before the menu displays (every open); the menu already shows the
    /// cached snapshot instantly, this just kicks a fresh `state` call whose result replaces
    /// the items in place if it lands while the menu is still open. Row submenus get their
    /// own delegate callback (`menuWillOpen`, below), not this one.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        // Cleared on open as well because menuDidClose is not guaranteed to fire for every close path.
        cancelHits()
        hitsCache.removeAll()
        triggerRefresh()
    }

    /// Fires once per row submenu open; kicks the lazy `hits` call for that row.
    func menuWillOpen(_ menu: NSMenu) {
        guard let rowMenu = menu as? RowMenu else { return }
        requestHits(rowID: rowMenu.rowID, hitsItem: rowMenu.hitsItem)
    }

    /// The top-level menu closing is the cache boundary the spec names ("cached until the
    /// menu closes"); a row submenu closing on its own (the user hovering to another row)
    /// must not clear it.
    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        cancelHits()
        hitsCache.removeAll()
    }
}
