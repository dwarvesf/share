import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Low-level process spawning shared by `CLI.run` and `CLI.spawnCancellable`.
///
/// Uses `posix_spawn` directly (not Foundation's `Process`) because the app needs
/// `POSIX_SPAWN_SETPGROUP`: the child becomes the leader of its own process group, so a
/// `killpg` on its pid reaches anything it forked too (e.g. `sleep 30 &` inside a shell
/// wrapper). `Process.terminate()` only ever signals the direct child.
enum Spawn {
    struct Handle {
        let pid: pid_t
        let stdoutFD: Int32
        let stderrFD: Int32
    }

    enum SpawnError: Error {
        case pipeFailed(Int32)
        case spawnFailed(Int32)
    }

    /// Spawns `executablePath` with `argv` appended after argv[0], in its own process group,
    /// stdin attached to /dev/null, stdout/stderr each piped back to the caller.
    static func start(executablePath: String, argv: [String], environment: [String: String]) throws -> Handle {
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0 else { throw SpawnError.pipeFailed(errno) }
        guard pipe(&stderrPipe) == 0 else { throw SpawnError.pipeFailed(errno) }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)

        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], 1)
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0])

        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], 2)
        posix_spawn_file_actions_addclose(&fileActions, stderrPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0])

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attr, 0) // new group, led by the child itself

        // posix_spawn otherwise inherits the calling thread's signal mask into the child.
        // GCD and Swift-concurrency worker threads commonly block most signals (including
        // SIGTERM), so a child spawned from one of those threads would never receive a
        // `killpg(..., SIGTERM)` sent later: it stays blocked forever. SETSIGMASK clears the
        // child's mask outright; SETSIGDEF resets the disposition of the signals this app
        // relies on to their default action, in case the parent's disposition (rather than
        // its mask) was ever changed to ignore one of them.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)

        var defaultedSignals = sigset_t()
        sigemptyset(&defaultedSignals)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGPIPE, SIGQUIT] {
            sigaddset(&defaultedSignals, signal)
        }
        posix_spawnattr_setsigdefault(&attr, &defaultedSignals)

        let argvC = makeCArray([executablePath] + argv)
        let envC = makeCArray(environment.map { "\($0.key)=\($0.value)" })
        defer {
            freeCArray(argvC)
            freeCArray(envC)
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executablePath, &fileActions, &attr, argvC, envC)

        // The parent never writes to the child's stdout/stderr; close its copies of the
        // write ends so the read ends see EOF once the child (and any grandchildren sharing
        // the descriptor) close theirs.
        close(stdoutPipe[1])
        close(stderrPipe[1])

        guard rc == 0 else {
            close(stdoutPipe[0])
            close(stderrPipe[0])
            throw SpawnError.spawnFailed(rc)
        }

        return Handle(pid: pid, stdoutFD: stdoutPipe[0], stderrFD: stderrPipe[0])
    }

    /// Reads a pipe to EOF, closing it afterward. Loops on a fixed-size buffer so a child
    /// writing far more than one pipe buffer (e.g. 200KB) never blocks on a full pipe while
    /// nobody is draining it.
    static func readAll(fd: Int32) -> Data {
        var data = Data()
        let bufferSize = 65536
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let n = buffer.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress, bufferSize)
            }
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        close(fd)
        return data
    }

    /// Decodes a BSD `wait` status into a shell-style exit code: the exit code itself on a
    /// normal exit, or 128 + signal number when the process was killed by a signal.
    static func exitStatus(fromWaitStatus status: Int32) -> Int32 {
        let signaled = status & 0x7f
        if signaled == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + signaled
    }

    private static func makeCArray(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        var array = strings.map { strdup($0) }
        array.append(nil)
        return array
    }

    private static func freeCArray(_ array: [UnsafeMutablePointer<CChar>?]) {
        for pointer in array where pointer != nil {
            free(pointer)
        }
    }
}
