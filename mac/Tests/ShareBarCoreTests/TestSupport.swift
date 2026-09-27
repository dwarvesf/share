import Foundation

/// Writes an executable shell script to a throwaway temp directory and returns its path.
/// Used to stand in for `share` so tests never depend on the real CLI.
func writeStubScript(_ contents: String) throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("stub.sh").path
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return path
}

/// A fresh empty temp directory, for tests that just need a place to write a marker/log file.
func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A plain (non-async) thread-safe string accumulator for tests that collect output streamed
/// from a background queue via `onOutput`. Kept as ordinary synchronous methods, not an actor,
/// so the lock calls are never made directly from an async context.
final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ text: String) {
        lock.lock()
        storage += text
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
