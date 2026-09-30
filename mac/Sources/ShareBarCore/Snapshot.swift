import Foundation

/// One share row from `share state`'s `shares[]` array.
public struct Share: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let url: String
    public let kind: String // "snapshot" or "live"
    public let ownHost: String?
    public let expires: Int // epoch seconds; 0 means never
    /// The `--access` rule on a gated share; nil means public.
    public let access: String?

    enum CodingKeys: String, CodingKey {
        case id, name, url, kind, expires, access
        case ownHost = "own_host"
    }

    public init(id: String, name: String, url: String, kind: String, ownHost: String?, expires: Int, access: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.kind = kind
        self.ownHost = ownHost
        self.expires = expires
        self.access = access
    }
}

/// The decoded `share state` snapshot. Unknown top-level fields are ignored by
/// `JSONDecoder` automatically; removing or renaming a field bumps `schema`.
public struct Snapshot: Decodable, Sendable, Equatable {
    public let schema: Int
    public let state: String // "serving" | "stopped" | "not_setup"
    public let ready: Bool
    public let mode: String // "named" | "quick"
    public let host: String?
    public let hosts: String
    public let servesHere: Bool
    public let service: Bool
    public let shares: [Share]
    public let skipped: Int?
    /// Access apps waiting for deletion (`access_pending`); nil on a CLI that predates it.
    public let accessPending: Int?
    /// `"r2"` on a profile that serves from R2 through a Worker (nothing runs on this Mac,
    /// so start and stop do not apply); nil on a tunnel profile or an older CLI.
    public let backend: String?

    enum CodingKeys: String, CodingKey {
        case schema, state, ready, mode, host, hosts, service, shares, skipped, backend
        case servesHere = "serves_here"
        case accessPending = "access_pending"
    }

    public init(
        schema: Int,
        state: String,
        ready: Bool,
        mode: String,
        host: String?,
        hosts: String,
        servesHere: Bool,
        service: Bool,
        shares: [Share],
        skipped: Int?,
        accessPending: Int? = nil,
        backend: String? = nil
    ) {
        self.schema = schema
        self.state = state
        self.ready = ready
        self.mode = mode
        self.host = host
        self.hosts = hosts
        self.servesHere = servesHere
        self.service = service
        self.shares = shares
        self.skipped = skipped
        self.accessPending = accessPending
        self.backend = backend
    }
}

/// Why a `profiles --json` call did not yield a usable `ProfilesSnapshot`.
public enum Failure: Error, Equatable, Sendable {
    /// `CLI.locate` found nothing (the sentinel `CLIResult` `CLI.run` returns).
    case cliNotFound
    /// Exit 1 with the CLI's help banner on stdout, or exit 0 with stdout that is not JSON:
    /// an old CLI without the `--json` flag prints the TSV listing either way.
    case oldCLI
    /// Anything else (undecodable output, a non-zero exit for another reason). Carries the
    /// already-formatted header line: `share: <last non-empty stderr line>`, or
    /// `share exited <n>` when stderr is empty.
    case other(String)
}

/// One entry of `share profiles --json`: the profile's name, plus either its `state`
/// object or the error line the CLI put in its place.
public struct ProfileEntry: Sendable, Equatable {
    public let name: String
    public let state: Snapshot?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case name, state, error
    }

    /// Just the schema marker: probed before a full decode so a `state` the app cannot
    /// read is confined to its own entry instead of failing the whole listing.
    private struct SchemaProbe: Decodable {
        let schema: Int?
    }

    public init(name: String, state: Snapshot?, error: String?) {
        self.name = name
        self.state = state
        self.error = error
    }
}

extension ProfileEntry: Decodable {
    /// Hand-written decode: a `state` with `schema` > 1 becomes `error` "Update Share Bar",
    /// a `state` that does not decode becomes `error` "state not readable", and a plain
    /// `error` entry passes through. One bad profile therefore never fails the listing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        let entryError = try container.decodeIfPresent(String.self, forKey: .error)
        guard container.contains(.state),
              let probe = try? container.decode(SchemaProbe.self, forKey: .state),
              let schema = probe.schema else {
            state = nil
            error = entryError ?? "state not readable"
            return
        }
        if schema > 1 {
            state = nil
            error = "Update Share Bar"
            return
        }
        if let decoded = try? container.decode(Snapshot.self, forKey: .state) {
            state = decoded
            error = entryError
        } else {
            state = nil
            error = entryError ?? "state not readable"
        }
    }
}

/// The decoded `share profiles --json` listing: every profile's `state` object (or its
/// error line) in one read.
public struct ProfilesSnapshot: Decodable, Sendable, Equatable {
    public let schema: Int
    public let profiles: [ProfileEntry]

    public init(schema: Int, profiles: [ProfileEntry]) {
        self.schema = schema
        self.profiles = profiles
    }
}

extension ProfilesSnapshot {
    /// Folds one `profiles --json` result over the last good snapshot: a successful decode
    /// replaces it; `.other` (incl. timeout) keeps it and marks it stale; `.cliNotFound`
    /// and `.oldCLI` clear it because no verb would work.
    public static func fold(_ result: CLIResult, over previous: ProfilesSnapshot?) -> (profiles: ProfilesSnapshot?, failure: Failure?) {
        switch from(result) {
        case .success(let value):
            return (value, nil)
        case .failure(.other(let line)):
            return (previous, .other(line))
        case .failure(let failure):
            return (nil, failure)
        }
    }

    /// Maps one `profiles --json` `CLIResult` to a decoded `ProfilesSnapshot` or a
    /// `Failure`.
    ///
    /// Detection order: the runner's own "not found" sentinel; the old-CLI help banner
    /// (exit 1, stdout starts with the CLI's own usage banner line); exit 0 with stdout
    /// that does not start with `{` is `.oldCLI` too, because a CLI from before this spec
    /// prints the TSV listing and ignores `--json`; a clean decode on exit 0; else the
    /// generic failure line.
    public static func from(_ result: CLIResult) -> Result<ProfilesSnapshot, Failure> {
        if result.stderr == "share: CLI not found" {
            return .failure(.cliNotFound)
        }
        if result.status == 1 && result.stdout.hasPrefix("share: publish snapshots") {
            return .failure(.oldCLI)
        }
        if result.status == 0 {
            let trimmed = result.stdout.drop(while: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            guard trimmed.hasPrefix("{") else {
                return .failure(.oldCLI)
            }
            if let data = result.stdout.data(using: .utf8),
               let snapshot = try? JSONDecoder().decode(ProfilesSnapshot.self, from: data) {
                return .success(snapshot)
            }
        }
        return .failure(.other(result.lastErrorLine))
    }
}
