import AppKit
import ShareBarCore
import SwiftUI

/// Owns the one All links window: 620 pt wide, the surface painted on its root like Settings.
/// `AppRouter.openAllLinks()` opens it; the status item controller hands it the popover's store.
@MainActor
final class AllLinksWindowController: NSObject, NSWindowDelegate {
    static let shared = AllLinksWindowController()

    private(set) var store: AllLinksStore?
    private var window: NSWindow?
    private var clock: Timer?

    var isShown: Bool { window?.isVisible ?? false }
    var windowNumber: Int { window?.windowNumber ?? 0 }

    /// Called once by the status item controller, with the store the popover reads.
    func attach(_ popover: PopoverStore) {
        guard store == nil else { return }
        store = AllLinksStore(popover: popover)
    }

    func show() {
        guard let store else { return }
        store.opened()
        let window = ensureWindow(store)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak store] _ in
            MainActor.assumeIsolated { store?.tick() }
        }
    }

    private func ensureWindow(_ store: AllLinksStore) -> NSWindow {
        if let window { return window }
        let hosting = NSHostingController(rootView: AllLinksView(store: store))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "All links"
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = dark ? SettingsTheme.surfaceDark : SettingsTheme.surfaceLight
            return NSColor(srgbRed: rgb.red / 255, green: rgb.green / 255, blue: rgb.blue / 255, alpha: 1)
        }
        window.delegate = self
        window.center()
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        clock?.invalidate()
        clock = nil
        // A pending removal commits when its window closes, as it does when the popover closes.
        store?.popover.send(.close)
    }
}
