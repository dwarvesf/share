import Foundation

/// Identifies one queued verb run, minted when it starts. `Stop Waiting` reads it before
/// its confirm opens, so a confirm answered after that job ended cancels nothing.
public struct JobToken: Sendable, Equatable {
    private let id: UUID

    init() {
        id = UUID()
    }
}

/// Serializes mutating CLI verbs (`add`, `rm`, `refresh`, `start`, `stop`) so only one runs
/// at a time, in the order they were queued.
///
/// A plain actor method is not enough here: actors are reentrant, so if `run` awaited
/// `CLI.run` directly, a second call could start its own CLI invocation while the first
/// is still suspended, and the two would run concurrently. Instead each call chains onto
/// the previous one's `Task`, so the previous run fully completes before the next starts.
public actor MutationQueue {
    private var lastTask: Task<CLIResult, Never>?
    /// The job currently running (if any), so `cancel(job:)` can reach it. `run`'s own
    /// verb is never auto-killed; this only exists for an explicit user action ("Stop
    /// Waiting", TASK-017).
    private var running: (token: JobToken, job: CLIJob)?

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
        let token = JobToken()
        let job = CLI.spawnCancellable(args) { _ in }
        running = (token, job)
        let result = await job.result
        running = nil
        return result
    }

    /// The token of the verb running right now, if any. `stopWaiting` reads it before
    /// `runModal` so a confirm answered after that job ended is a no-op.
    public func currentJob() -> JobToken? {
        running?.token
    }

    /// TERMs (then KILLs after 3s) the process group of the job `token` names, but only
    /// while it is still the running one. A confirm answered after that job ended does
    /// nothing, and never reaches the next job.
    public func cancel(job token: JobToken) {
        guard let current = running, current.token == token else { return }
        current.job.cancel()
    }
}
