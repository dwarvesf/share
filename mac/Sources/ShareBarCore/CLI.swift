import Foundation
import os
#if canImport(Darwin)
import Darwin
#endif

private let logger = Logger(subsystem: ShareBarIdentity.bundleID, category: "cli")

/// Locates, spawns, and runs the `share` CLI. This is the only place that knows how to find
/// or talk to the binary; everything else in the app goes through it.
public enum CLI {
    /// Fixed probe locations, checked in order after `SHARE_BIN`. `$HOME` is expanded here,
    /// not left for the shell.
    private static func probeCandidates(home: String) -> [String] {
        [
            "/opt/homebrew/bin/share",
            "/usr/local/bin/share",
            "\(home)/.local/bin/share",
            "/opt/local/bin/share",
        ]
    }

    /// `SHARE_BIN` is a trusted, explicit override (same convention as `SHARE_ROOT` and
    /// `SHARE_CONFIG_DIR` in `bin/share`): if set, it wins outright, no existence check.
    /// The fixed probe paths are guesses, so each is gated by `fileExists`.
    public static func locate(env: [String: String], fileExists: (String) -> Bool) -> URL? {
        if let bin = env["SHARE_BIN"], !bin.isEmpty {
            return URL(fileURLWithPath: bin)
        }
        let home = env["HOME"] ?? NSHomeDirectory()
        for candidate in probeCandidates(home: home) where fileExists(candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    /// Location overrides and the profile selection removed from every child's
    /// environment: the same six `profiles_child_env` unsets in `bin/share` (a
    /// tests/share.sh grep keeps the two lists equal), plus `SHARE_PROFILE`, so a leaked
    /// root or profile cannot point a verb at a setup the menu does not show.
    static let strippedEnvironmentKeys = [
        "SHARE_ROOT",
        "SHARE_CONFIG_DIR",
        "SHARE_PORT",
        "SHARE_HOSTNAME",
        "SHARE_HOSTS",
        "SHARE_SERVICE_LABEL",
        "SHARE_PROFILE",
    ]

    /// Child environment: the app's own environment, with `PATH` replaced by the resolved
    /// CLI directory followed by the spec's fixed fallback PATH, `LANG` filled in only when
    /// unset, `SHARE_CLIPBOARD` always forced off, and `strippedEnvironmentKeys` removed.
    static func childEnvironment(cliDirectory: String, inherited: [String: String]) -> [String: String] {
        var env = inherited
        let home = inherited["HOME"] ?? NSHomeDirectory()
        for key in strippedEnvironmentKeys {
            env[key] = nil
        }
        let fallbackPath = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "\(home)/.local/bin", "/opt/local/bin",
            "\(home)/.nix-profile/bin", "/nix/var/nix/profiles/default/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
        env["PATH"] = "\(cliDirectory):\(fallbackPath)"
        if env["LANG"] == nil {
            env["LANG"] = "en_US.UTF-8"
        }
        env["SHARE_CLIPBOARD"] = "0"
        return env
    }

    private static func locateForRun() -> URL? {
        locate(env: ProcessInfo.processInfo.environment) { FileManager.default.fileExists(atPath: $0) }
    }

    /// Runs one CLI verb to completion. `timeout` nil means the run is never killed
    /// automatically (mutating verbs); a set timeout TERMs the process group when it fires,
    /// then KILLs it 3s later if it is still alive.
    public static func run(_ args: [String], timeout: TimeInterval?) async -> CLIResult {
        guard let url = locateForRun() else {
            logger.error(
                "share CLI not found; verb=\(verbForLog(args), privacy: .public) args=\(args.joined(separator: " "), privacy: .private)"
            )
            return CLIResult(status: 127, stdout: "", stderr: "share: CLI not found", timedOut: false)
        }
        let env = childEnvironment(
            cliDirectory: url.deletingLastPathComponent().path,
            inherited: ProcessInfo.processInfo.environment
        )
        return await Task.detached(priority: .userInitiated) {
            runAndWait(executablePath: url.path, argv: args, environment: env, timeout: timeout)
        }.value
    }

    /// The verb for the public `verb=` log field: skips a leading `--profile <name>` pair
    /// so the field names the verb, never `--profile`.
    static func verbForLog(_ argv: [String]) -> String {
        if argv.first == "--profile", argv.count > 2 {
            return argv[2]
        }
        return argv.first ?? ""
    }

    /// Concurrent `profiles --json` calls share one in-flight run. A `fresh` call never
    /// joins a run that started before it: it waits for that run to end, then starts a new
    /// one, which later callers may join (the post-mutation re-read).
    public static func profiles(fresh: Bool = false, timeout: TimeInterval? = 20) async -> CLIResult {
        await profilesCoalescer.run(fresh: fresh, timeout: timeout)
    }

    private static let profilesCoalescer = ProfilesCoalescer()

    /// Spawns a long-running, cancellable verb (setup), streaming decoded output to
    /// `onOutput` as it arrives instead of buffering it until exit.
    public static func spawnCancellable(_ args: [String], onOutput: @escaping (String) -> Void) -> CLIJob {
        guard let url = locateForRun() else {
            logger.error(
                "share CLI not found; verb=\(verbForLog(args), privacy: .public) args=\(args.joined(separator: " "), privacy: .private)"
            )
            onOutput("share: CLI not found")
            return CLIJob.failed(CLIResult(status: 127, stdout: "", stderr: "share: CLI not found", timedOut: false))
        }
        let env = childEnvironment(
            cliDirectory: url.deletingLastPathComponent().path,
            inherited: ProcessInfo.processInfo.environment
        )
        let start = Date()
        let verb = verbForLog(args)
        let argvForLog = ([url.path] + args).joined(separator: " ")

        do {
            let handle = try Spawn.start(executablePath: url.path, argv: args, environment: env)
            var stdoutData = Data()
            var stderrData = Data()
            let group = DispatchGroup()

            func stream(fd: Int32, into accumulate: @escaping (Data) -> Void) {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, 4096) }
                        if n <= 0 { break }
                        let chunk = Data(buffer[0..<n])
                        accumulate(chunk)
                        onOutput(String(decoding: chunk, as: UTF8.self))
                    }
                    close(fd)
                    group.leave()
                }
            }
            stream(fd: handle.stdoutFD) { stdoutData.append($0) }
            stream(fd: handle.stderrFD) { stderrData.append($0) }

            // A plain sync function, not an async closure body: blocking calls (waitpid,
            // DispatchGroup.wait) inside an `async` closure are flagged under strict
            // concurrency, so the blocking work is isolated here and only its result
            // crosses into the detached task below.
            func waitAndDrain() -> Int32 {
                var status: Int32 = 0
                waitpid(handle.pid, &status, 0)
                group.wait()
                return Spawn.exitStatus(fromWaitStatus: status)
            }

            let resultTask = Task.detached(priority: .userInitiated) { () -> CLIResult in
                let exit = waitAndDrain()
                let duration = Date().timeIntervalSince(start)
                logger.log(
                    "verb=\(verb, privacy: .public) argv=\(argvForLog, privacy: .private) exit=\(exit, privacy: .public) duration=\(duration, privacy: .public) timedOut=false"
                )
                return CLIResult(
                    status: exit,
                    stdout: String(decoding: stdoutData, as: UTF8.self),
                    stderr: String(decoding: stderrData, as: UTF8.self),
                    timedOut: false
                )
            }
            return CLIJob(pid: handle.pid, resultTask: resultTask)
        } catch {
            logger.error(
                "spawn failed for verb=\(verb, privacy: .public) argv=\(argvForLog, privacy: .private): \(String(describing: error), privacy: .public)"
            )
            return CLIJob.failed(CLIResult(status: -1, stdout: "", stderr: "share: failed to spawn", timedOut: false))
        }
    }

    /// Blocking: spawns, drains both pipes while the process runs (never just after exit, so
    /// a child writing far more than one pipe buffer can't deadlock), waits for exit, and
    /// enforces the timeout (TERM the group, then KILL 3s later). Runs on a detached task's
    /// thread, never the caller's.
    private static func runAndWait(
        executablePath: String,
        argv: [String],
        environment: [String: String],
        timeout: TimeInterval?
    ) -> CLIResult {
        let start = Date()
        let verb = verbForLog(argv)
        let argvForLog = ([executablePath] + argv).joined(separator: " ")

        let handle: Spawn.Handle
        do {
            handle = try Spawn.start(executablePath: executablePath, argv: argv, environment: environment)
        } catch {
            logger.error(
                "spawn failed for verb=\(verb, privacy: .public) argv=\(argvForLog, privacy: .private): \(String(describing: error), privacy: .public)"
            )
            return CLIResult(status: -1, stdout: "", stderr: "share: failed to spawn", timedOut: false)
        }

        let drainGroup = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()
        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutData = Spawn.readAll(fd: handle.stdoutFD)
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrData = Spawn.readAll(fd: handle.stderrFD)
            drainGroup.leave()
        }

        var waitStatus: Int32 = 0
        let exitGroup = DispatchGroup()
        exitGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            waitpid(handle.pid, &waitStatus, 0)
            exitGroup.leave()
        }

        var timedOut = false
        if let timeout {
            if exitGroup.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                killpg(handle.pid, SIGTERM)
                if exitGroup.wait(timeout: .now() + 3) == .timedOut {
                    killpg(handle.pid, SIGKILL)
                    exitGroup.wait()
                }
            }
        } else {
            exitGroup.wait() // nil timeout: never killed, wait as long as it takes
        }

        drainGroup.wait()

        let exit = Spawn.exitStatus(fromWaitStatus: waitStatus)
        let duration = Date().timeIntervalSince(start)
        logger.log(
            "verb=\(verb, privacy: .public) argv=\(argvForLog, privacy: .private) exit=\(exit, privacy: .public) duration=\(duration, privacy: .public) timedOut=\(timedOut, privacy: .public)"
        )

        return CLIResult(
            status: exit,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            timedOut: timedOut
        )
    }
}

/// Coalesces `profiles --json` calls into one in-flight run.
private actor ProfilesCoalescer {
    private var generation = 0
    private var inFlight: (gen: Int, task: Task<CLIResult, Never>)?

    func run(fresh: Bool, timeout: TimeInterval?) async -> CLIResult {
        if let current = inFlight {
            if !fresh {
                return await current.task.value
            }
            _ = await current.task.value
            if let next = inFlight {
                if next.gen == current.gen {
                    // Still the run we just waited on (its starter has not cleared it
                    // yet); its result predates this call and must not be reused.
                    inFlight = nil
                } else {
                    // A run another waiter started after the old one ended did not start
                    // before this call, so a fresh caller may join it.
                    return await next.task.value
                }
            }
        }
        generation += 1
        let task = Task { await CLI.run(["profiles", "--json"], timeout: timeout) }
        inFlight = (generation, task)
        let result = await task.value
        if inFlight?.gen == generation {
            inFlight = nil
        }
        return result
    }
}

/// The `--profile <name>` prefix every per-profile verb carries, `default` included, so
/// no app call depends on an inherited SHARE_PROFILE.
public enum ProfileArgs {
    public static func argv(_ profile: String, _ verbArgs: [String]) -> [String] {
        ["--profile", profile] + verbArgs
    }

    /// The command the menu's hint lines and failure text name: `share` for the default
    /// profile, `share --profile <name>` otherwise.
    public static func commandName(_ profile: String) -> String {
        profile == "default" ? "share" : "share --profile \(profile)"
    }
}

/// A cancellable, streaming CLI invocation (used for `setup`). `cancel()` TERMs the
/// process group and KILLs it 3s later if it hasn't exited by then.
public final class CLIJob: @unchecked Sendable {
    private let pid: pid_t
    private let resultTask: Task<CLIResult, Never>

    init(pid: pid_t, resultTask: Task<CLIResult, Never>) {
        self.pid = pid
        self.resultTask = resultTask
    }

    static func failed(_ result: CLIResult) -> CLIJob {
        CLIJob(pid: -1, resultTask: Task { result })
    }

    public var result: CLIResult {
        get async { await resultTask.value }
    }

    public func cancel() {
        guard pid > 0 else { return }
        killpg(pid, SIGTERM)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3) { [pid] in
            killpg(pid, SIGKILL) // harmless (ESRCH) if the group is already gone
        }
    }
}
