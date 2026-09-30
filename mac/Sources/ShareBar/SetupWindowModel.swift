import Foundation
import ShareBarCore
import os

private let setupLogger = Logger(subsystem: ShareBarIdentity.bundleID, category: "setup")

/// Drives the setup window's SwiftUI view: field state, the running `CLIJob`, and the
/// streamed log. `onFinished` fires once when the run completes (success or failure); the
/// window controller reacts to it (close and refresh on success, keep the log on failure).
/// Cancel and a running-window close both go through `cancel()`/`terminateRunningJob()`
/// instead, since neither of those ends the run by letting the CLI exit on its own.
// @unchecked Sendable: every mutable property is only ever touched on the main thread (init,
// a SwiftUI button action, or a block scheduled through `DispatchQueue.main.async`), same
// convention and reasoning as `StatusItemController`'s own `@unchecked Sendable`.
final class SetupWindowModel: ObservableObject, @unchecked Sendable {
    /// The profile this setup runs against; its argv is always `--profile <name> setup`,
    /// `default` included.
    let profile: String
    @Published var hostname: String
    @Published var quickMode: Bool = false
    @Published var openAtLogin: Bool = true
    @Published var log: String = ""
    @Published var isRunning: Bool = false
    @Published var statusLine: String = ""

    private var job: CLIJob?
    var onFinished: ((Bool) -> Void)?

    /// `host` prefills the hostname field: rerunning `share setup <host>` is the recovery
    /// for a setup cancelled or failed halfway, and the section passes in the host it
    /// already knows (empty when the profile is `not_setup`).
    init(profile: String, host: String?) {
        self.profile = profile
        hostname = host ?? ""
    }

    /// Set Up is enabled once a hostname the CLI would accept is typed, or immediately in
    /// quick mode (which ignores the field). Never enabled while a run is already in flight.
    var canSetUp: Bool {
        guard !isRunning else { return false }
        return quickMode || HostnameValidation.isValid(hostname)
    }

    /// Runs `share --profile <p> setup <host>` or `share --profile <p> setup --quick`
    /// through `spawnCancellable`, streaming its output into `log` as it arrives.
    func setUp() {
        guard canSetUp else { return }
        isRunning = true
        statusLine = "Working…"
        log = ""
        let args = ProfileArgs.argv(profile, quickMode ? ["setup", "--quick"] : ["setup", hostname])
        setupLogger.log("setup start args=\(args.joined(separator: " "), privacy: .private)")

        let job = CLI.spawnCancellable(args) { [weak self] chunk in
            DispatchQueue.main.async {
                self?.log += chunk
            }
        }
        self.job = job

        Task { [weak self] in
            let result = await job.result
            guard let self else { return }
            DispatchQueue.main.async {
                // A job that was already cancelled has cleared `self.job` and flipped
                // `isRunning` back to false; its result still arrives here asynchronously
                // and must not overwrite the cancelled-state message with a stale exit code.
                guard self.isRunning else { return }
                self.isRunning = false
                self.job = nil
                let success = result.status == 0
                setupLogger.log("setup finished exit=\(result.status, privacy: .public) success=\(success, privacy: .public)")
                self.statusLine = success ? "Setup complete." : "Setup failed (exit \(result.status))."
                self.onFinished?(success)
            }
        }
    }

    /// Cancel button: terminates the process group, keeps the window open, and lets the
    /// user retry without reopening it.
    func cancel() {
        guard isRunning else { return }
        setupLogger.log("setup cancelled")
        terminateRunningJob()
        statusLine = "Setup cancelled; Set Up again to finish."
    }

    /// Kills the running job's process group, if any, without touching `statusLine` (the
    /// app-quit path has no window left to show it in). Called from `cancel()` and from
    /// `SetupWindowController.terminateActiveJob()` during `applicationWillTerminate`.
    func terminateRunningJob() {
        guard isRunning, let job else { return }
        job.cancel()
        isRunning = false
        self.job = nil
    }
}
