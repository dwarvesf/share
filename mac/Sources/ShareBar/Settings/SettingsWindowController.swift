import AppKit
import ShareBarCore
import SwiftUI

/// Owns the one Settings window (SPEC-009 `### Layout & structure`): 620 pt wide, icon tabs,
/// the surface painted on its root. `AppRouter` opens it.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    let store = SettingsStore()
    private var window: NSWindow?
    private var refreshTimer: Timer?

    var isShown: Bool { window?.isVisible ?? false }

    func show(pane: SettingsPane, member: String? = nil) {
        let window = ensureWindow()
        store.show(pane: pane)
        if let member { store.pointAtMember(member) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        startRefreshing()
    }

    func showAdd(_ kind: AddSheetKind) {
        show(pane: .tenants)
        store.presentAdd(kind)
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let hosting = NSHostingController(rootView: SettingsRootView(store: store))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Share Bar Settings"
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

    private func startRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShown, !(self.store.flow?.isActive ?? false) else { return }
                Task { await self.store.refresh() }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// The window number for the screenshot harness.
    var windowNumber: Int { window?.windowNumber ?? 0 }
}
