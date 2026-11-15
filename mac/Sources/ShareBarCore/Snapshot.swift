import Foundation

extension KeyedDecodingContainer {
    /// A key the app reads only when it is well formed: absent, null or of the wrong type
    /// all read as nil, so one odd new key can never turn a readable `state` into an error
    /// (SB-02: an unknown value falls back to today's derivation).
    func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

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
    /// `machine` or `cloud`; nil on a CLI that predates per-link storage.
    public let storage: String?
    /// The file type (`pdf`, `image`, `folder`, ...); nil on an older CLI.
    public let type: String?
    /// The machine that published the link; nil on an older CLI.
    public let by: String?
    /// The member's full id (`m-<name>-<8hex>`) on a v:3 machine-member row; nil elsewhere.
    public let origin: String?
    /// SPEC-010 and SPEC-009 `link_state` as the CLI printed it (`live`, `expired`,
    /// `shadowed`, `gate_missing`, `revoked`, `paused`, `offline`); nil on an older CLI.
    /// An unknown value stays a string here and reads as `live` in `LinkState`.
    public let linkState: String?
    /// Why a non-live state holds (`revoked_by=<by>`), when the CLI said.
    public let reason: String?
    /// View count on a cloud row, when the CLI reported one.
    public let views: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, url, kind, expires, access, storage, type, by, origin, reason, views
        case ownHost = "own_host"
        case linkState = "link_state"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        kind = try c.decode(String.self, forKey: .kind)
        ownHost = try c.decodeIfPresent(String.self, forKey: .ownHost)
        expires = try c.decode(Int.self, forKey: .expires)
        access = try c.decodeIfPresent(String.self, forKey: .access)
        storage = try c.decodeIfPresent(String.self, forKey: .storage)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        by = try c.decodeIfPresent(String.self, forKey: .by)
        origin = c.lenient(String.self, forKey: .origin)
        linkState = c.lenient(String.self, forKey: .linkState)
        reason = c.lenient(String.self, forKey: .reason)
        views = c.lenient(Int.self, forKey: .views)
    }

    public init(
        id: String, name: String, url: String, kind: String, ownHost: String?, expires: Int,
        access: String? = nil, storage: String? = nil, type: String? = nil, by: String? = nil,
        origin: String? = nil, linkState: String? = nil, reason: String? = nil, views: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.kind = kind
        self.ownHost = ownHost
        self.expires = expires
        self.access = access
        self.storage = storage
        self.type = type
        self.by = by
        self.origin = origin
        self.linkState = linkState
        self.reason = reason
        self.views = views
    }
}

/// `state.serve`: the reasoned serving state behind the old `state`/`ready` pair (G6).
public struct ServeInfo: Decodable, Sendable, Equatable {
    /// `not_setup`, `elsewhere`, `failed`, `stopped`, `starting`, `tunnel_down`,
    /// `worker_down` or `serving`; any other value is unknown and never shown.
    public let phase: String
    /// The `.serve-exit` code for `failed`, else the phase name (`ok` for `serving`).
    public let reason: String?

    public init(phase: String, reason: String? = nil) {
        self.phase = phase
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey { case phase, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try c.decode(String.self, forKey: .phase)
        reason = c.lenient(String.self, forKey: .reason)
    }
}

/// One entry of `state.ops`: a journaled command, running or stopped (G2a). The CLI also
/// prints `{"verb":"?","alive":false}` for a journal file it cannot read, so every field
/// but `verb` and `alive` is optional.
public struct OpInfo: Decodable, Sendable, Equatable {
    public let verb: String
    public let step: Int?
    public let of: Int?
    public let name: String?
    public let alive: Bool
    /// False when the entry carried no readable `alive` boolean. `JournalRun` then refuses:
    /// an op whose liveness is unknown is never rerun or rolled back.
    public let aliveKnown: Bool
    /// The share id an `add` journal belongs to (null for every other verb).
    public let id: String?
    /// The display string (`printf %q` per argument). Text only: never parsed, never run.
    public let rerun: String?
    /// The arguments after `share` (DEC-21). Run only through `JournalRun`.
    public let rerunArgv: [String]?
    public let rollback: String?
    public let rollbackArgv: [String]?

    enum CodingKeys: String, CodingKey {
        case verb, step, of, name, alive, rerun, rollback, id
        case rerunArgv = "rerun_argv"
        case rollbackArgv = "rollback_argv"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verb = try c.decode(String.self, forKey: .verb)
        let aliveValue = c.lenient(Bool.self, forKey: .alive)
        alive = aliveValue ?? false
        aliveKnown = aliveValue != nil
        id = c.lenient(String.self, forKey: .id)
        step = c.lenient(Int.self, forKey: .step)
        of = c.lenient(Int.self, forKey: .of)
        name = c.lenient(String.self, forKey: .name)
        rerun = c.lenient(String.self, forKey: .rerun)
        rerunArgv = c.lenient([String].self, forKey: .rerunArgv)
        rollback = c.lenient(String.self, forKey: .rollback)
        rollbackArgv = c.lenient([String].self, forKey: .rollbackArgv)
    }

    public init(
        verb: String, step: Int? = nil, of: Int? = nil, name: String? = nil, alive: Bool, id: String? = nil,
        rerun: String? = nil, rerunArgv: [String]? = nil, rollback: String? = nil, rollbackArgv: [String]? = nil
    ) {
        self.verb = verb
        self.step = step
        self.of = of
        self.name = name
        self.alive = alive
        self.aliveKnown = true
        self.id = id
        self.rerun = rerun
        self.rerunArgv = rerunArgv
        self.rollback = rollback
        self.rollbackArgv = rollbackArgv
    }
}

/// `state.token` (G10): the key this profile adds with.
public struct TokenInfo: Decodable, Sendable, Equatable {
    public let source: String?
    /// `missing`, `unchecked`, `invalid`, `expired`, `expiring` or `ok`.
    public let status: String
    public let expiresOn: String?

    enum CodingKeys: String, CodingKey {
        case source, status
        case expiresOn = "expires_on"
    }

    public init(source: String? = nil, status: String, expiresOn: String? = nil) {
        self.source = source
        self.status = status
        self.expiresOn = expiresOn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        source = c.lenient(String.self, forKey: .source)
        expiresOn = c.lenient(String.self, forKey: .expiresOn)
    }
}

/// `state.compat` (G10): this share against the Worker at the hostname.
public struct CompatInfo: Decodable, Sendable, Equatable {
    public let cli: String?
    public let worker: String?
    /// `ok`, `worker_older`, `worker_newer`, `cli_below_min` or `unknown`.
    public let status: String
    public let minCLI: String?

    enum CodingKeys: String, CodingKey {
        case cli, worker, status
        case minCLI = "min_cli"
    }

    public init(cli: String? = nil, worker: String? = nil, status: String, minCLI: String? = nil) {
        self.cli = cli
        self.worker = worker
        self.status = status
        self.minCLI = minCLI
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        cli = c.lenient(String.self, forKey: .cli)
        worker = c.lenient(String.self, forKey: .worker)
        minCLI = c.lenient(String.self, forKey: .minCLI)
    }
}

/// `state.member` on a member profile (SPEC-009 R7): this machine's own record.
public struct MemberInfo: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String?
    public let mode: String?
    /// The record's status from the `.health` cache; nil before the first read.
    public let status: String?
    public let step: Int?
    public let tokenExpires: String?

    enum CodingKeys: String, CodingKey {
        case id, name, mode, status, step
        case tokenExpires = "token_expires"
    }

    public init(id: String, name: String? = nil, mode: String? = nil, status: String? = nil, step: Int? = nil, tokenExpires: String? = nil) {
        self.id = id
        self.name = name
        self.mode = mode
        self.status = status
        self.step = step
        self.tokenExpires = tokenExpires
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.lenient(String.self, forKey: .name)
        mode = c.lenient(String.self, forKey: .mode)
        status = c.lenient(String.self, forKey: .status)
        step = c.lenient(Int.self, forKey: .step)
        tokenExpires = c.lenient(String.self, forKey: .tokenExpires)
    }
}

/// Decodes an array one element at a time and drops the elements that do not decode, so
/// one odd entry never hides the others.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var out: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                out.append(element)
            } else {
                _ = try? container.decode(Discard.self)
            }
        }
        elements = out
    }

    private struct Discard: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

/// The decoded `share state` snapshot. Unknown top-level fields are ignored by
/// `JSONDecoder` automatically; removing or renaming a field bumps `schema`. Every key
/// added after v0.9.0 is optional and lenient: absent or malformed reads as nil and the
/// app falls back to today's derivation (SPEC-009 TASK-4b1, SPEC-010 G11a).
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
    /// True when the profile reads a bucket; nil on an older CLI.
    public let r2: Bool?
    /// `local` or `cloud` on an origin with R2 on; nil elsewhere and on an older CLI.
    public let storageDefault: String?
    /// Why cloud rows are missing from `shares` when they are (the reason line `state`
    /// prints instead of failing); nil when the bucket read worked or there is none.
    public let cloudError: String?
    /// Cloud rows `state` did not fetch (it caps its bucket reads at 25); the section
    /// adds it to the `more` line.
    public let cloudMore: Int?
    /// `none`, `quick`, `origin`, `tenant_origin`, `r2_profile`, `member` or `migrated`;
    /// nil on an older CLI. An unknown value reads as no role.
    public let role: String?
    /// `t0`, `t1` or `t2` on an origin role; nil elsewhere.
    public let tier: String?
    public let serve: ServeInfo?
    /// Journaled commands, running or stopped; nil on an older CLI, `[]` when none.
    public let ops: [OpInfo]?
    public let token: TokenInfo?
    public let compat: CompatInfo?
    public let member: MemberInfo?

    enum CodingKeys: String, CodingKey {
        case schema, state, ready, mode, host, hosts, service, shares, skipped, backend, r2
        case role, tier, serve, ops, token, compat, member
        case servesHere = "serves_here"
        case accessPending = "access_pending"
        case storageDefault = "storage_default"
        case cloudError = "cloud_error"
        case cloudMore = "cloud_more"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        state = try c.decode(String.self, forKey: .state)
        ready = try c.decode(Bool.self, forKey: .ready)
        mode = try c.decode(String.self, forKey: .mode)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        hosts = try c.decode(String.self, forKey: .hosts)
        servesHere = try c.decode(Bool.self, forKey: .servesHere)
        service = try c.decode(Bool.self, forKey: .service)
        shares = try c.decode([Share].self, forKey: .shares)
        skipped = try c.decodeIfPresent(Int.self, forKey: .skipped)
        accessPending = try c.decodeIfPresent(Int.self, forKey: .accessPending)
        backend = try c.decodeIfPresent(String.self, forKey: .backend)
        r2 = try c.decodeIfPresent(Bool.self, forKey: .r2)
        storageDefault = try c.decodeIfPresent(String.self, forKey: .storageDefault)
        cloudError = try c.decodeIfPresent(String.self, forKey: .cloudError)
        cloudMore = try c.decodeIfPresent(Int.self, forKey: .cloudMore)
        role = c.lenient(String.self, forKey: .role)
        tier = c.lenient(String.self, forKey: .tier)
        serve = c.lenient(ServeInfo.self, forKey: .serve)
        ops = c.lenient(LossyArray<OpInfo>.self, forKey: .ops)?.elements
        token = c.lenient(TokenInfo.self, forKey: .token)
        compat = c.lenient(CompatInfo.self, forKey: .compat)
        member = c.lenient(MemberInfo.self, forKey: .member)
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
        backend: String? = nil,
        r2: Bool? = nil,
        storageDefault: String? = nil,
        cloudError: String? = nil,
        cloudMore: Int? = nil,
        role: String? = nil,
        tier: String? = nil,
        serve: ServeInfo? = nil,
        ops: [OpInfo]? = nil,
        token: TokenInfo? = nil,
        compat: CompatInfo? = nil,
        member: MemberInfo? = nil
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
        self.r2 = r2
        self.storageDefault = storageDefault
        self.cloudError = cloudError
        self.cloudMore = cloudMore
        self.role = role
        self.tier = tier
        self.serve = serve
        self.ops = ops
        self.token = token
        self.compat = compat
        self.member = member
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
