import Foundation

/// Runs one journaled verb with `SHARE_PROGRESS=1`, feeds its progress lines to a `FlowRun`,
/// and stops it with SIGTERM on request (SPEC-009 TASK-4b18). The journal keeps the step, so
/// the tenant shows the interrupted callout afterwards.
public final class FlowRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var current: FlowRun
    private var job: CLIJob?
    private var stream = ProgressStream()
    private let argv: [String]
    private let environment: [String: String]
    private let onChange: @Sendable (FlowRun) -> Void

    /// `environment` is the one place an asked key may go (`CLOUDFLARE_API_TOKEN`).
    public init(argv: [String], kind: FlowKind, title: String, environment: [String: String] = [:], onChange: @escaping @Sendable (FlowRun) -> Void) {
        self.argv = argv
        self.environment = environment
        self.onChange = onChange
        current = FlowRun(kind: kind, title: title)
    }

    public var run: FlowRun {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    private func mutate(_ change: (inout FlowRun) -> Void) {
        lock.lock()
        change(&current)
        let snapshot = current
        lock.unlock()
        onChange(snapshot)
    }

    public func start() {
        var env = MutationQueue.environment
        env["SHARE_PROGRESS"] = "1"
        env.merge(environment) { _, new in new }
        let spawned = CLI.spawnCancellable(argv, environment: env) { [weak self] chunk in
            guard let self else { return }
            self.lock.lock()
            let lines = self.stream.feed(chunk)
            self.lock.unlock()
            for line in lines { self.mutate { $0.apply(line) } }
        }
        lock.lock()
        job = spawned
        lock.unlock()
        Task { [weak self] in
            let result = await spawned.result
            self?.mutate { $0.exited(status: result.status, stderr: result.stderr) }
        }
    }

    /// Stop sends SIGTERM to the verb's process group (KILL 3 s later if it lingers).
    public func stop() {
        lock.lock()
        let running = job
        lock.unlock()
        mutate { $0.stopRequested() }
        running?.cancel()
    }
}

/// The sheets of the Settings window and whether Esc may close each (SPEC-009 TASK-4b16).
public enum SheetKind: String, Sendable, Equatable {
    case add, progress, confirm, refusal, code, invite, askKey, removeMember

    /// Esc closes every sheet but progress: a running verb has Stop, never a silent close.
    public var escCloses: Bool { self != .progress }
}
