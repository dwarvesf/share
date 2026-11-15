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
        // Quitting while an undo is pending commits it at once (SPEC-009 `### Components & states`).
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.closed(commitSynchronously: true) }
        }
    }

    deinit {
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
    }

    func attach(to button: NSStatusBarButton) {
        self.button = button
    }

    var appearance: NSAppearance? {
        get { popover.appearance }
        set { popover.appearance = newValue }
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
    func debugRender(to path: String, menuRow: String?, appearance: NSAppearance?, done: @escaping () -> Void) {
        let hosting = NSHostingView(rootView: ShareBarView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: ShareBarView.width, height: 600),
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: capture)
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
        guard event.window === popover.contentViewController?.view.window else { return event }
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
