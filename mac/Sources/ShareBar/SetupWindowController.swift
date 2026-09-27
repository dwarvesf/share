import AppKit
import SwiftUI
import ServiceManagement
import ShareBarCore
import os

private let setupWindowLogger = Logger(subsystem: ShareBarIdentity.bundleID, category: "setup")

/// Owns the setup window's lifecycle: activation policy, and the single shared instance
/// `AppDelegate.applicationWillTerminate` reaches to kill a running setup before the app
/// quits.
///
/// Deliberately its own file (TASK-011): another worker edits `StatusItemController` for
/// other menu actions at the same time, so everything setup-window-specific lives here and
/// `StatusItemController` only gets the one-line Set Up… handler that calls `show`.
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    /// The window currently open, if any. Read by `terminateActiveJob()` so
    /// `applicationWillTerminate` can kill a running setup without `StatusItemController`
    /// holding or forwarding a reference itself.
    private static var active: SetupWindowController?

    private let model = SetupWindowModel()
    private let onSuccess: () -> Void

    /// Shows the setup window, or brings the existing one forward if one is already open.
    static func show(onSuccess: @escaping () -> Void) {
        if let active {
            active.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = SetupWindowController(onSuccess: onSuccess)
        active = controller
        controller.showWindow(nil)
    }

    /// Called from `AppDelegate.applicationWillTerminate` while the app is quitting.
    /// Terminates a running setup's process group; never tries to close the window itself,
    /// since the app is already on its way out.
    static func terminateActiveJob() {
        active?.model.terminateRunningJob()
    }

    private init(onSuccess: @escaping () -> Void) {
        self.onSuccess = onSuccess

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up Share Bar"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SetupView(model: model))
        window.center()

        super.init(window: window)
        window.delegate = self

        model.onFinished = { [weak self] success in
            self?.handleFinished(success: success)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("SetupWindowController does not support NSCoding")
    }

    override func showWindow(_ sender: Any?) {
        // The app runs as an accessory (no Dock icon) the rest of the time; the setup
        // window is the one place it needs a Dock icon and Cmd-Tab entry, per the spec.
        NSApp.setActivationPolicy(.regular)
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleFinished(success: Bool) {
        guard success else { return } // failure keeps the window and log open
        if model.openAtLogin {
            do {
                try SMAppService.mainApp.register()
            } catch {
                setupWindowLogger.error(
                    "open-at-login register failed after setup: \(String(describing: error), privacy: .public)"
                )
            }
        }
        onSuccess()
        close()
    }

    /// Intercepts the window's own close (red button, Cmd-W) while setup is running: the
    /// spec pairs "Cancel and closing the window" as the same outcome (terminate the group,
    /// show the cancelled message), so a close attempt mid-run is treated as Cancel and the
    /// window itself stays open rather than vanishing silently. Once nothing is running the
    /// close proceeds normally.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.isRunning else { return true }
        model.cancel()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        SetupWindowController.active = nil
    }
}
