import Foundation

/// Serializes mutating CLI verbs (`add`, `rm`, `refresh`, `start`, `stop`) so only one runs
/// at a time, in the order they were queued.
///
/// A plain actor method is not enough here: actors are reentrant, so if `run` awaited
/// `CLI.run` directly, a second call could start its own CLI invocation while the first
/// is still suspended, and the two would run concurrently. Instead each call chains onto
/// the previous one's `Task`, so the previous run fully completes before the next starts.
public actor MutationQueue {
    private var lastTask: Task<CLIResult, Never>?
    /// The job currently running (if any), so `cancelCurrent()` can reach it. `run`'s own
    /// verb is never auto-killed; this only exists for an explicit user action ("Stop
    /// Waiting", TASK-017).
    private var currentJob: CLIJob?

    public init() {}

    public func run(_ args: [String]) async -> CLIResult {
        let previous = lastTask
        let task = Task {
            _ = await previous?.value
            return await self.runTracked(args)
        }
        lastTask = task
        return await task.value
    }

    /// Spawns via `CLI.spawnCancellable` instead of `CLI.run(timeout: nil)` so the run can
    /// be cancelled from outside (Stop Waiting); behaviorally identical otherwise (no
    /// automatic timeout, same locate/env rules), just with a `CLIJob` handle kept live for
    /// the run's duration.
    private func runTracked(_ args: [String]) async -> CLIResult {
        let job = CLI.spawnCancellable(args) { _ in }
        currentJob = job
        let result = await job.result
        currentJob = nil
        return result
    }

    /// TERMs (then KILLs after 3s) the process group of whichever verb is running right now,
    /// if any. Never called automatically; only from the user confirming Stop Waiting.
    public func cancelCurrent() {
        currentJob?.cancel()
    }
}
