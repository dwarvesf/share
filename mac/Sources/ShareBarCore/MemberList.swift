import Foundation

/// A held admin lease on `member ls --json`: who runs which verb, and whether it is alive.
public struct MemberLease: Decodable, Sendable, Equatable {
    public let holder: String?
    public let verb: String?
    public let step: Int?
    public let live: Bool

    enum CodingKeys: String, CodingKey { case holder, verb, step, live }

    public init(holder: String? = nil, verb: String? = nil, step: Int? = nil, live: Bool) {
        self.holder = holder
        self.verb = verb
        self.step = step
        self.live = live
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        holder = c.lenient(String.self, forKey: .holder)
        verb = c.lenient(String.self, forKey: .verb)
        step = c.lenient(Int.self, forKey: .step)
        live = c.lenient(Bool.self, forKey: .live) ?? false
    }
}

/// One member of `share member ls --json` (SPEC-009 TASK-1i). `can` is the list of verbs
/// the CLI's own `member_can` table allows the admin from this record's status, plus
/// `finish` for a verb whose lease went stale: the Share Bar's row menu lists exactly
/// these and never mirrors the table (DEC-53).
public struct MemberRecord: Decodable, Sendable, Equatable {
    public let memberID: String
    public let name: String
    public let mode: String?
    /// The stored status, or `invalid` for a record the CLI could not read.
    public let status: String
    /// True when an `invited` member's code is past its expiry (derived, never stored).
    public let expired: Bool
    public let step: Int?
    public let of: Int?
    public let stepName: String?
    public let lease: MemberLease?
    public let deployBound: Bool
    public let deployPaused: Bool
    public let tunnel: String?
    public let connectors: Int
    public let services: Int
    public let tokenExpires: String?
    public let inviteExpires: Int?
    public let prevStatus: String?
    /// Stable drift codes from the CLI's code table, never free text.
    public let drift: [String]
    public let can: [String]

    enum CodingKeys: String, CodingKey {
        case name, mode, status, expired, step, of, lease, deploy, account, drift, can
        case memberID = "member_id"
        case stepName = "step_name"
        case tokenExpires = "token_expires"
        case inviteExpires = "invite_expires"
        case prevStatus = "prev_status"
    }

    private struct Deploy: Decodable {
        let bound: Bool?
        let paused: Bool?
    }

    private struct Account: Decodable {
        let tunnel: String?
        let connectors: Int?
        let services: Int?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        memberID = try c.decode(String.self, forKey: .memberID)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decode(String.self, forKey: .status)
        mode = c.lenient(String.self, forKey: .mode)
        expired = c.lenient(Bool.self, forKey: .expired) ?? false
        step = c.lenient(Int.self, forKey: .step)
        of = c.lenient(Int.self, forKey: .of)
        stepName = c.lenient(String.self, forKey: .stepName)
        lease = c.lenient(MemberLease.self, forKey: .lease)
        let deploy = c.lenient(Deploy.self, forKey: .deploy)
        deployBound = deploy?.bound ?? false
        deployPaused = deploy?.paused ?? false
        let account = c.lenient(Account.self, forKey: .account)
        tunnel = account?.tunnel
        connectors = account?.connectors ?? 0
        services = account?.services ?? 0
        tokenExpires = c.lenient(String.self, forKey: .tokenExpires)
        inviteExpires = c.lenient(Int.self, forKey: .inviteExpires)
        prevStatus = c.lenient(String.self, forKey: .prevStatus)
        drift = c.lenient([String].self, forKey: .drift) ?? []
        can = c.lenient([String].self, forKey: .can) ?? []
    }

    public init(
        memberID: String, name: String, mode: String? = "machine", status: String, expired: Bool = false,
        step: Int? = nil, of: Int? = nil, stepName: String? = nil, lease: MemberLease? = nil,
        deployBound: Bool = false, deployPaused: Bool = false, tunnel: String? = nil,
        connectors: Int = 0, services: Int = 0, tokenExpires: String? = nil, inviteExpires: Int? = nil,
        prevStatus: String? = nil, drift: [String] = [], can: [String] = []
    ) {
        self.memberID = memberID
        self.name = name
        self.mode = mode
        self.status = status
        self.expired = expired
        self.step = step
        self.of = of
        self.stepName = stepName
        self.lease = lease
        self.deployBound = deployBound
        self.deployPaused = deployPaused
        self.tunnel = tunnel
        self.connectors = connectors
        self.services = services
        self.tokenExpires = tokenExpires
        self.inviteExpires = inviteExpires
        self.prevStatus = prevStatus
        self.drift = drift
        self.can = can
    }

    /// True for an `...ing` status: a verb is, or was, running on this record.
    public var isRunning: Bool { status.hasSuffix("ing") }

    /// Present only for a machine member: whether its connector is up.
    public var isOnline: Bool { mode == "machine" && connectors > 0 }
}

/// The decoded `share member ls --json` array. An entry that does not decode is dropped,
/// so one odd record never hides the rest of the team.
public struct MemberList: Sendable, Equatable {
    public let members: [MemberRecord]

    public init(members: [MemberRecord]) {
        self.members = members
    }

    /// Nil when `stdout` is not a JSON array at all (an older CLI with no `member`
    /// verb prints a usage line instead).
    public static func decode(_ stdout: String) -> MemberList? {
        guard let data = stdout.data(using: .utf8),
              let lossy = try? JSONDecoder().decode(LossyArray<MemberRecord>.self, from: data) else { return nil }
        return MemberList(members: lossy.elements)
    }
}

/// The line `SHARE_PROGRESS=1` makes a journaled verb print to stderr at each step
/// (SPEC-010 G2a): `{"progress":{"verb":"setup-r2","step":13,"of":16,"name":"route"}}`.
/// It never starts with `share: `, so the last-`share:`-line rule ignores it.
public struct Progress: Sendable, Equatable {
    public let verb: String
    public let step: Int
    public let of: Int
    public let name: String

    public init(verb: String, step: Int, of: Int, name: String) {
        self.verb = verb
        self.step = step
        self.of = of
        self.name = name
    }

    private struct Envelope: Decodable {
        struct Body: Decodable {
            let verb: String
            let step: Int
            let of: Int
            let name: String?
        }
        let progress: Body
    }

    /// Reads one stderr line; nil for anything that is not a progress line.
    public static func parse(line: String) -> Progress? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{\"progress\""), let data = trimmed.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        let body = envelope.progress
        return Progress(verb: body.verb, step: body.step, of: body.of, name: body.name ?? "")
    }

    /// The newest progress line in a stderr buffer (a verb prints one per step).
    public static func last(inStderr stderr: String) -> Progress? {
        stderr.split(separator: "\n", omittingEmptySubsequences: true).reversed().lazy
            .compactMap { parse(line: String($0)) }.first
    }
}
