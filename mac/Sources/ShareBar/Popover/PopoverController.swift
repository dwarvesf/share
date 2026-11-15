import AppKit
import ShareBarCore
import SwiftUI

/// Owns the `NSPopover` of the status item: shows and hides it, keeps its keyboard and
/// scroll monitors only while it is open, and ticks the store's clock for the Undo window.
@MainActor
final class PopoverController: NSObject, NSPopoverDelegate {
    let store: PopoverStore
    private let popover = NSPopover()
    private weak var button: NSStatusBarButton?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var clock: Timer?
    private var terminateObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private let hotkeys = HotkeyCenter(registrar: CarbonHotkeyRegistrar())
    private var quickLook: QuickLookPanelController!
    /// Called right before the popover shows: the controller re-reads `profiles`.
    var onWillShow: () -> Void = {}

    init(store: PopoverStore) {
        self.store = store
        super.init()
        let hosting = NSHostingController(rootView: ShareBarView(store: store))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        store.onDismiss = { [weak self] in self?.close() }
        store.onReveal = { [weak self] in self?.show() }
        quickLook = QuickLookPanelController(store: store)
        quickLook.anchorWindow = { [weak self] in self?.popover.contentViewController?.view.window }
        // A click on the Quick Look panel must not dismiss the popover under it (decision D19).
        quickLook.onVisibilityChange = { [weak self] up in self?.popover.behavior = up ? .applicationDefined : .transient }
        // While Quick Look holds the popover open, losing the app's focus must still dismiss both.
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.store.quickLook != nil else { return }
                self.store.send(.closeQuickLook)
                self.close()
            }
        }
        store.hotkeyStatus = hotkeys.register { [weak self] in
            MainActor.assumeIsolated { self?.hotkeyPressed() }
        }
        // Quitting while an undo is pending commits it at once (SPEC-009 `### Components & states`).
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.closed(commitSynchronously: true) }
        }
    }

    deinit {
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    func attach(to button: NSStatusBarButton) {
        self.button = button
    }

    var appearance: NSAppearance? {
        get { popover.appearance }
        set {
            popover.appearance = newValue
            quickLook.appearance = newValue
        }
    }

    /// ⌃⌥S, from any app: opens the popover in `list` with the search focused, from `issues`
    /// too, closing an open menu or Quick Look (TASK-4b13).
    func hotkeyPressed() {
        if !popover.isShown { show() }
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        openForHotkey()
    }

    func openForHotkey() {
        store.tenantMenuOpen = false
        store.send(.hotkey)
    }

    var isShown: Bool { popover.isShown }

    func toggle() {
        if popover.isShown { close() } else { show() }
    }

    func show() {
        guard let button, !popover.isShown else { return }
        onWillShow()
        store.opened()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        installMonitors()
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    #if DEBUG
    /// Screenshot hook (DEBUG only, read by AppDelegate from `-ShareBarShotsRender <png>`): draws the
    /// popover's SwiftUI tree in an offscreen window, optionally with one row's menu open, and writes
    /// a PNG. It takes no pointer or key input, so it runs on a live desktop without touching it.
    ///
    /// `-ShareBarShotsScene <name>` (read here, so the frozen AppDelegate stays as it is) puts the
    /// popover in one state of TASK-4b10 to TASK-4b13 through the same reducer events a real drag, key
    /// or hotkey sends: `drop`, `uploading`, `flashed`, `dragout`, `hotkey`, and `ql-pdf`, `ql-folder`,
    /// `ql-port`, `ql-cloud` for the Quick Look view. The app states and the keyboard and error screens
    /// of TASK-4b21 to TASK-4b23: `loading`, `cli-missing`, `cli-old`, `focus-third`, `menu-shift-f10`,
    /// `publish-failure`; `first-run` and `working-line` come from the scenario the fake CLI answers with.
    func debugRender(to path: String, menuRow: String?, appearance: NSAppearance?, done: @escaping () -> Void) {
        let scene = UserDefaults.standard.string(forKey: "ShareBarShotsScene")
        let quickLookRow = ["ql-pdf": "pd0001", "ql-folder": "d4e5f6", "ql-port": "lv0001", "ql-cloud": "cl0001"][scene ?? ""]
        let root: AnyView = quickLookRow == nil ? AnyView(ShareBarView(store: store)) : AnyView(EmptyView())
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: quickLookRow == nil ? ShareBarView.width : QuickLookModel.width, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        func capture() {
            let size = hosting.fittingSize
            window.setContentSize(size)
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { done(); return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
            done()
        }
        store.opened()
        window.orderBack(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let menuRow { self.store.openMenu(menuRow) }
            if let quickLookRow {
                let home = ProcessInfo.processInfo.environment["SHARE_SHOTS_HOME"] ?? NSHomeDirectory()
                guard let row = self.store.row(quickLookRow) ?? self.store.allRowsForShots().first(where: { $0.id == quickLookRow }) else { done(); return }
                hosting.rootView = AnyView(QuickLookView(model: QuickLookModel(row: row, home: home), onClose: {}, onOpen: {}, onCopy: {}, thumbnail: true))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: capture)
                return
            }
            self.applyShotsScene(scene)
            DispatchQueue.main.asyncAfter(deadline: .now() + (scene == "publish-live" ? 1.3 : 0.6), execute: capture)
        }
    }

    private func applyShotsScene(_ scene: String?) {
        let first = store.viewModel.rows.first?.id
        switch scene {
        case "drop":
            store.send(.dragEnter)
        case "uploading":
            let file = "/Users/demo/Q4-plan.pdf"
            store.send(.publishStarted(file: file))
            store.send(.publishStep(file: file, step: 2, of: 6))
            store.stepNames[file] = "publish"
        case "flashed":
            store.send(.publishFinished(file: "/Users/demo/Q4-plan.pdf", result: .copied(url: "https://s.han.ws/a1b2c3/posture-routine.html"), now: Date()))
            if let first { store.flash(first) }
        case "publish-live":
            // The real path: a drop on the popover runs `add` through the queue with SHARE_PROGRESS=1 and the fake
            // CLI's journal lines move the placeholder row. The capture lands while step 2 is the latest line.
            store.send(.dragEnter)
            store.publish(paths: [ProcessInfo.processInfo.environment["SHARE_SHOTS_DROP_FILE"] ?? "/tmp/Q4-plan.pdf"], dropped: true)
        case "dragout":
            if let first { store.send(.dragOutBegan(id: first)) }
        case "hotkey":
            store.showIssues()
            openForHotkey()
        case "loading":
            store.freezeForShots(profiles: nil, failure: nil)
        case "cli-missing":
            store.freezeForShots(profiles: nil, failure: .cliNotFound)
        case "cli-old":
            store.freezeForShots(profiles: nil, failure: .oldCLI)
        case "focus-third":
            // The popover opens with search focused, so the first Down enters row 1: the third row takes three.
            for _ in 0..<3 { store.moveFocus(1) }
        case "menu-shift-f10":
            store.moveFocus(1)
            store.openMenuOnFocused()
        case "publish-failure":
            let file = "/Users/demo/Q4-plan.pdf"
            store.send(.publishStarted(file: file))
            let stderr = "share: the bucket refused the upload\n{\"error\":{\"code\":\"upload_refused\",\"message\":\"the bucket refused the upload\",\"next\":\"share status\"}}\n"
            store.send(.publishFinished(file: file, result: PublishOutcome.result(status: 1, stdout: "", stderr: stderr, fallbackURL: nil), now: Date()))
        default:
            break
        }
    }
    #endif

    // MARK: NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        removeMonitors()
        store.closed()
    }

    // MARK: monitors

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(key: event) ?? event }
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                // A scroll closes the row menu (the menu is an overlay, so it never scrolls itself).
                if let self, self.store.menuRowID != nil { self.store.closeMenu() }
                return event
            }
        }
        clock = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.store.needsClock else { return }
                self.store.tick()
            }
        }
        RunLoop.main.add(clock!, forMode: .common)
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        keyMonitor = nil
        scrollMonitor = nil
        clock?.invalidate()
        clock = nil
    }

    /// The keyboard of `### Accessibility targets`: Esc steps back, arrows move rows, Return
    /// copies, Delete removes through the undo window, the ContextMenu key or Shift-F10 opens
    /// the row menu, Command-Z undoes.
    private func handle(key event: NSEvent) -> NSEvent? {
        guard event.window === popover.contentViewController?.view.window || event.window === quickLook.window else { return event }
        if let look = store.quickLook {
            switch event.keyCode {
            case 53, 49: // Esc, Space
                store.send(.closeQuickLook)
                return nil
            case 36, 76: // Return: the default button, Copy link
                store.copyFromQuickLook(rowID: look.rowID)
                return nil
            default:
                return nil
            }
        }
        let typing = event.window?.firstResponder is NSText
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53: // Esc
            if store.tenantMenuOpen {
                store.tenantMenuOpen = false
            } else if store.menuRowID != nil {
                store.closeMenu()
            } else if store.showsIssues {
                store.send(.escape)
            } else {
                close()
            }
            return nil
        case 6 where command: // Command-Z
            guard store.undoVisible else { return event }
            store.undo()
            return nil
        case 125, 126: // down, up
            if store.menuRowID != nil || store.tenantMenuOpen { return event }
            if typing, event.keyCode == 126 { return event }
            if typing { event.window?.makeFirstResponder(nil) }
            store.moveFocus(event.keyCode == 125 ? 1 : -1)
            return nil
        case 36, 76: // Return, keypad Enter
            if typing || store.menuRowID != nil || store.showsIssues { return event }
            store.returnOnFocused()
            return nil
        case 51, 117: // Delete, forward delete
            if typing || store.menuRowID != nil || store.showsIssues { return event }
            store.deleteFocused()
            return nil
        case 49 where !typing: // Space: Quick Look on the focused row
            guard store.focusedRow != nil, store.menuRowID == nil, !store.showsIssues else { return event }
            store.toggleQuickLookOnFocused()
            return nil
        case 110: // the ContextMenu key
            if typing { return event }
            store.openMenuOnFocused()
            return nil
        case 109 where event.modifierFlags.contains(.shift): // Shift-F10
            store.openMenuOnFocused()
            return nil
        default:
            return event
        }
    }
}
