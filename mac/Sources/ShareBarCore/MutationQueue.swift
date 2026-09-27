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

    public init() {}

    public func run(_ args: [String]) async -> CLIResult {
        let previous = lastTask
        let task = Task {
            _ = await previous?.value
            return await CLI.run(args, timeout: nil) // mutating verbs are never killed
        }
        lastTask = task
        return await task.value
    }
}
