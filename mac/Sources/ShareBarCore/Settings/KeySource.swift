import Foundation

/// The two Cloudflare keys Advanced configures: the admin key (`admin-token`, DEC-46) and
/// the minter key (`minter-token`, DEC-80).
public enum KeyKind: String, Sendable, Equatable, CaseIterable {
    case admin, minter

    public var verb: String { self == .admin ? "admin-token" : "minter-token" }
    public var title: String { self == .admin ? "Admin key" : "Minter key" }
    /// The variable a per-command key reaches its one child through.
    public var environmentName: String { self == .admin ? "CLOUDFLARE_API_TOKEN" : "SHARE_MINTER_TOKEN" }

    public var askNote: String {
        self == .admin
            ? "Handout Bar asks for the Cloudflare admin token before each admin action and forgets it right after."
            : "Handout Bar asks for the minter token before each member action and forgets it right after."
    }

    public var usedFor: String {
        self == .admin
            ? "Used only for admin actions such as inviting members or turning on cloud storage. The token is read when needed and never saved."
            : "Used only to mint member keys: invite, send a new code, rotate and renew. The token is read when needed and never saved."
    }
}

/// A picked 1Password item. Names are for display; the two ids are all that reaches argv.
public struct OnePasswordItem: Sendable, Equatable, Codable {
    public let itemID: String
    public let itemName: String
    public let vaultID: String
    public let vaultName: String

    public init(itemID: String, itemName: String, vaultID: String, vaultName: String) {
        self.itemID = itemID
        self.itemName = itemName
        self.vaultID = vaultID
        self.vaultName = vaultName
    }

    /// `Toolkit vault · credential` of the prototype's picked row.
    public var subtitle: String { "\(vaultName) vault · credential" }

    /// `op item list --format json`: an entry with an id that is not 26 characters of
    /// `[a-z0-9]` is dropped, so it can never reach a command.
    public static func decode(_ json: String) -> [OnePasswordItem] {
        struct Vault: Decodable { let id: String?; let name: String? }
        struct Entry: Decodable { let id: String?; let title: String?; let vault: Vault? }
        guard let data = json.data(using: .utf8),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.compactMap { entry in
            guard let id = entry.id, let title = entry.title, let vault = entry.vault,
                  let vaultID = vault.id, KeyArgv.isValidID(id), KeyArgv.isValidID(vaultID) else { return nil }
            return OnePasswordItem(itemID: id, itemName: title, vaultID: vaultID, vaultName: vault.name ?? "Vault")
        }
    }
}

/// Where a key comes from. `askEachTime` stores nothing: the key goes to one command.
public enum KeySource: Sendable, Equatable {
    case onePassword(OnePasswordItem?)
    case command(String)
    case askEachTime

    public var label: String {
        switch self {
        case .onePassword: return "From 1Password"
        case .command: return "From a command"
        case .askEachTime: return "Ask me each time"
        }
    }
}

public enum KeyArgv {
    private static let idPattern = #"^[a-z0-9]{26}\z"#

    /// Each 1Password id is 26 characters of `[a-z0-9]`; a name is never used, so a vault or
    /// item name cannot inject shell.
    public static func isValidID(_ id: String) -> Bool {
        id.range(of: idPattern, options: .regularExpression) != nil
    }

    /// `op read op://<vault id>/<item id>/credential`
    public static func onePasswordCommand(_ item: OnePasswordItem) -> String? {
        guard isValidID(item.vaultID), isValidID(item.itemID) else { return nil }
        return "op read op://\(item.vaultID)/\(item.itemID)/credential"
    }

    /// The argv that stores a source. Nil when the source cannot be written: a 1Password
    /// choice with no valid item, or an empty command.
    public static func write(_ kind: KeyKind, source: KeySource, profile: String) -> [String]? {
        switch source {
        case .onePassword(let item):
            guard let item, let command = onePasswordCommand(item) else { return nil }
            return ProfileArgs.argv(profile, [kind.verb, "--cmd", command])
        case .command(let text):
            let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty, command.count <= 4096, !command.contains("\n"), !command.contains("\0") else { return nil }
            return ProfileArgs.argv(profile, [kind.verb, "--cmd", command])
        case .askEachTime:
            return ProfileArgs.argv(profile, [kind.verb, "--clear"])
        }
    }

    public static func test(_ kind: KeyKind, profile: String) -> [String] {
        ProfileArgs.argv(profile, [kind.verb, "--test", "--json"])
    }
}

/// Anything shaped like a credential is replaced before it reaches the screen: 32 or more
/// characters of a token alphabet in one run.
public enum Redact {
    public static func tokenShaped(_ text: String) -> String {
        text.replacingOccurrences(of: #"[A-Za-z0-9_\-]{32,}"#, with: "…", options: .regularExpression)
    }
}

/// What `<kind>-token --test --json` reported: capability names and yes or no, never a token.
public struct KeyTestResult: Sendable, Equatable {
    public struct Capability: Sendable, Equatable {
        public let name: String
        public let label: String
        public let ok: Bool
    }

    public let source: String
    public let capabilities: [Capability]

    /// `{"source":"cmd","can":{"workers":true,"tunnels":true,...}}`. Only the capabilities this
    /// app names are read, in a fixed order, so no other key and no free text can pass.
    public static func decode(_ stdout: String, kind: KeyKind) -> KeyTestResult? {
        struct Flag: Decodable {
            let value: Bool?
            init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(Bool.self) }
        }
        struct Body: Decodable {
            let source: String?
            let can: [String: Flag]?
        }
        guard let data = stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let body = try? JSONDecoder().decode(Body.self, from: data), let can = body.can else { return nil }
        let order: [(String, String)] = kind == .admin
            ? [("tunnels", "tunnels"), ("dns", "DNS"), ("workers", "Workers"), ("r2", "R2"), ("connectivity", "Connectivity Directory")]
            : [("list_tokens", "listing API tokens")]
        let known = order.compactMap { key, label in can[key]?.value.map { Capability(name: key, label: label, ok: $0) } }
        let source: String
        switch body.source {
        case "cmd": source = "a command"
        case "env": source = "the environment"
        default: source = "a saved source"
        }
        return KeyTestResult(source: source, capabilities: known)
    }

    public var allOK: Bool { !capabilities.isEmpty && capabilities.allSatisfy(\.ok) }

    /// "Works for tunnels, DNS and Workers", or "Cannot use R2 and Connectivity Directory".
    public var summary: String {
        let good = capabilities.filter(\.ok).map(\.label)
        let bad = capabilities.filter { !$0.ok }.map(\.label)
        if capabilities.isEmpty { return "The CLI did not say what this key can do" }
        if bad.isEmpty { return "Works for \(KeyTestResult.join(good))" }
        if good.isEmpty { return "Cannot use \(KeyTestResult.join(bad))" }
        return "Works for \(KeyTestResult.join(good)). Cannot use \(KeyTestResult.join(bad))"
    }

    static func join(_ words: [String]) -> String {
        switch words.count {
        case 0: return ""
        case 1: return words[0]
        default: return words.dropLast().joined(separator: ", ") + " and " + words[words.count - 1]
        }
    }

    /// A failed test's sentence: the CLI's error line, else its last stderr line, with any
    /// credential-shaped run removed.
    public static func failureSentence(_ result: CLIResult) -> String {
        if let error = ErrorLine.last(inStderr: result.stderr) { return Redact.tokenShaped(error.message) }
        let line = result.lastErrorLine
        return Redact.tokenShaped(CLIPrefix.strip(line))
    }
}

/// What Advanced remembers (the CLI cannot read a stored command back, D10): the source kind
/// and, for 1Password, the item's names and ids, or the command text. Never a token.
public struct KeySourceStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ kind: KeyKind, _ field: String, profile: String) -> String { "Key.\(kind.rawValue).\(profile).\(field)" }

    public func load(_ kind: KeyKind, profile: String) -> KeySource {
        switch defaults.string(forKey: key(kind, "kind", profile: profile)) {
        case "1p":
            if let data = defaults.data(forKey: key(kind, "item", profile: profile)),
               let item = try? JSONDecoder().decode(OnePasswordItem.self, from: data) { return .onePassword(item) }
            return .onePassword(nil)
        case "cmd":
            return .command(defaults.string(forKey: key(kind, "cmd", profile: profile)) ?? "")
        default:
            return .askEachTime
        }
    }

    public func save(_ source: KeySource, kind: KeyKind, profile: String) {
        switch source {
        case .onePassword(let item):
            defaults.set("1p", forKey: key(kind, "kind", profile: profile))
            if let item, let data = try? JSONEncoder().encode(item) { defaults.set(data, forKey: key(kind, "item", profile: profile)) }
        case .command(let text):
            defaults.set("cmd", forKey: key(kind, "kind", profile: profile))
            defaults.set(text, forKey: key(kind, "cmd", profile: profile))
        case .askEachTime:
            defaults.set("ask", forKey: key(kind, "kind", profile: profile))
        }
    }

    /// The label the tenant detail's Key row shows for the admin key.
    public func adminKeyLabel(profile: String) -> String {
        switch load(.admin, profile: profile) {
        case .onePassword(let item?): return "1Password, \(item.itemName)"
        case .onePassword(nil): return "1Password"
        case .command: return "A command"
        case .askEachTime: return "Asks each time"
        }
    }
}
