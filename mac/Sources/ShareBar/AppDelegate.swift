import AppKit

/// Runs the app with no Dock icon (`LSUIElement` already covers this; `.accessory` is set
/// explicitly too, matching the setup window's need to flip to `.regular` and back per the
/// spec's activation-policy rule).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItemController = StatusItemController()

        // Manual-verification-only debug entry (TASK-017/TASK-010): a colon-separated list
        // of paths in `SHAREBAR_DEBUG_ADD_PATHS` runs through the same `addPaths` a real
        // Share File… selection or drop would, without driving `NSOpenPanel` or a real
        // drag. Never set by a normal launch; exists so manual checks can hit the add path
        // deterministically instead of navigating a picker via synthetic keystrokes.
        // #if DEBUG: this read (and `debugAddPaths` itself) must not compile into a release
        // build, or any process could set the env var before launching the notarized app
        // and trigger an unattended `add`.
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["SHAREBAR_DEBUG_ADD_PATHS"], !raw.isEmpty {
            statusItemController?.debugAddPaths(raw.split(separator: ":").map(String.init))
        }
        #endif
    }

    /// Quitting while setup runs (TASK-011) must not leave the setup process group behind.
    func applicationWillTerminate(_ notification: Notification) {
        SetupWindowController.terminateActiveJob()
    }
}
