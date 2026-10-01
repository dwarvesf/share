import Foundation
@testable import ShareBarCore

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

/// Builds a `Snapshot` with sensible defaults so each `MenuModel` test states only the
/// field(s) it is actually exercising.
func makeSnapshot(
    schema: Int = 1,
    state: String = "serving",
    ready: Bool = true,
    mode: String = "named",
    host: String? = "s.han.ws",
    hosts: String = "hans-air-m4",
    servesHere: Bool = true,
    service: Bool = true,
    shares: [Share] = [],
    skipped: Int? = nil,
    accessPending: Int? = nil,
    backend: String? = nil,
    r2: Bool? = nil,
    storageDefault: String? = nil,
    cloudError: String? = nil,
    cloudMore: Int? = nil
) -> Snapshot {
    Snapshot(
        schema: schema, state: state, ready: ready, mode: mode, host: host, hosts: hosts,
        servesHere: servesHere, service: service, shares: shares, skipped: skipped,
        accessPending: accessPending, backend: backend, r2: r2,
        storageDefault: storageDefault, cloudError: cloudError, cloudMore: cloudMore
    )
}

/// Builds a `Share` with sensible defaults so each `Row` test states only the field(s) it
/// is actually exercising.
func makeShare(
    id: String = "abc123",
    name: String = "notes.txt",
    url: String = "https://s.han.ws/abc123/notes.txt",
    kind: String = "snapshot",
    ownHost: String? = nil,
    expires: Int = 0,
    access: String? = nil,
    storage: String? = nil,
    type: String? = nil,
    by: String? = nil
) -> Share {
    Share(id: id, name: name, url: url, kind: kind, ownHost: ownHost, expires: expires, access: access, storage: storage, type: type, by: by)
}

/// One profile entry: its `state`, or its `error` line (the JSON shape the CLI emits is
/// one or the other; tests build both with `init` since the decode path is covered in
/// SnapshotDecodeTests).
func makeEntry(name: String, state: Snapshot? = nil, error: String? = nil) -> ProfileEntry {
    ProfileEntry(name: name, state: state, error: error)
}

/// A `profiles --json` listing over the given entries.
func makeProfiles(_ entries: [ProfileEntry], schema: Int = 1) -> ProfilesSnapshot {
    ProfilesSnapshot(schema: schema, profiles: entries)
}

/// One-entry-per-name convenience wrapper.
func makeProfiles(_ named: [(String, Snapshot)]) -> ProfilesSnapshot {
    ProfilesSnapshot(schema: 1, profiles: named.map { ProfileEntry(name: $0.0, state: $0.1, error: nil) })
}

/// Loads the `share state` fixture.
func loadFixtureSnapshot() throws -> Snapshot {
    guard let url = Bundle.module.url(forResource: "state", withExtension: "json") else {
        throw NSError(domain: "TestSupport", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture not found"])
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(Snapshot.self, from: data)
}

/// Loads the `share profiles --json` fixture, saved from a real run on the Mini (default
/// `not_setup`, `dfoundation` serving a gated share).
func loadFixtureProfiles() throws -> ProfilesSnapshot {
    guard let url = Bundle.module.url(forResource: "profiles", withExtension: "json") else {
        throw NSError(domain: "TestSupport", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture not found"])
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(ProfilesSnapshot.self, from: data)
}

/// Loads the tenant-era `share profiles --json` fixture: an R2-on origin, an r2 member
/// carrying `cloud_error`, and an older-CLI-shaped tunnel profile with no new fields.
func loadFixtureTenantProfiles() throws -> ProfilesSnapshot {
    guard let url = Bundle.module.url(forResource: "profiles-tenant", withExtension: "json") else {
        throw NSError(domain: "TestSupport", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture not found"])
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(ProfilesSnapshot.self, from: data)
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
