import AppKit

/// Runs the app with no Dock icon (`LSUIElement` already covers this; `.accessory` is set
/// explicitly too, matching the setup window's need to flip to `.regular` and back per the
/// spec's activation-policy rule).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItemController = StatusItemController()
    }

    /// Quitting while setup runs (TASK-011) must not leave the setup process group behind.
    func applicationWillTerminate(_ notification: Notification) {
        SetupWindowController.terminateActiveJob()
    }
}
