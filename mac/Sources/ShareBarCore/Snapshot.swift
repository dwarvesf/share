import Foundation

/// One share row from `share state`'s `shares[]` array.
public struct Share: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let url: String
    public let kind: String // "snapshot" or "live"
    public let ownHost: String?
    public let expires: Int // epoch seconds; 0 means never

    enum CodingKeys: String, CodingKey {
        case id, name, url, kind, expires
        case ownHost = "own_host"
    }

    public init(id: String, name: String, url: String, kind: String, ownHost: String?, expires: Int) {
        self.id = id
        self.name = name
        self.url = url
        self.kind = kind
        self.ownHost = ownHost
        self.expires = expires
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

    enum CodingKeys: String, CodingKey {
        case schema, state, ready, mode, host, hosts, service, shares, skipped
        case servesHere = "serves_here"
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
        skipped: Int?
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
    }
}

/// Why a `state` call did not yield a usable `Snapshot`.
public enum Failure: Error, Equatable, Sendable {
    /// `CLI.locate` found nothing (the sentinel `CLIResult` `CLI.run` returns).
    case cliNotFound
    /// Exit 1 with the CLI's help banner on stdout: an old CLI without the `state` verb.
    case oldCLI
    /// Anything else (undecodable output, a non-zero exit for another reason). Carries the
    /// already-formatted header line: `share: <last non-empty stderr line>`, or
    /// `share exited <n>` when stderr is empty.
    case other(String)
}

extension Snapshot {
    /// Maps one `share state` `CLIResult` to a decoded `Snapshot` or a `Failure`.
    ///
    /// Detection order: the runner's own "not found" sentinel; the old-CLI help banner
    /// (exit 1, stdout starts with the CLI's own usage banner line); a clean decode of
    /// stdout on exit 0; else the generic failure line.
    public static func from(_ result: CLIResult) -> Result<Snapshot, Failure> {
        if result.stderr == "share: CLI not found" {
            return .failure(.cliNotFound)
        }
        if result.status == 1 && result.stdout.hasPrefix("share: publish snapshots") {
            return .failure(.oldCLI)
        }
        if result.status == 0,
           let data = result.stdout.data(using: .utf8),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            return .success(snapshot)
        }
        return .failure(.other(result.lastErrorLine))
    }
}
