import Foundation

/// The four journaled flows the Settings window starts (SPEC-009 TASK-4b18). Each runs with
/// `SHARE_PROGRESS=1`; its journal verb names the steps.
public enum FlowKind: String, Sendable, Equatable {
    case join
    case setupTunnel = "setup-tunnel"
    case setupR2 = "setup-r2"
    case setupMembers = "setup-members"

    /// The step names of this verb's journal, from `op_steps_*` in `bin/share`. The sheet
    /// lists them all, each done, now or pending; a CLI that reports another total falls
    /// back to the names it has printed so far.
    public var stepNames: [String] {
        switch self {
        case .join: return ["redeem", "keys", "record", "service", "probe", "active"]
        case .setupTunnel: return ["auth", "tunnel", "route", "dns", "token", "config", "service", "live"]
        case .setupR2:
            return ["alias", "worker", "bucket", "alias-domain", "routes", "snapshot", "alias-apps", "deploy",
                    "pointers", "access", "config", "marker", "route", "alias-bind", "probe", "handoff"]
        case .setupMembers: return ["lease", "deploy", "marker", "config", "release"]
        }
    }
}

/// Step names shown to people: a copy table for the known journal names, the raw name for
/// any other (a newer CLI may add steps).
public enum StepCopy {
    public static func title(verb: String, name: String) -> String {
        table[verb]?[name] ?? name
    }

    /// The lower-case noun form used inside a sentence ("The route step did not finish").
    public static func short(verb: String, name: String) -> String { name }

    private static let table: [String: [String: String]] = [
        "join": [
            "redeem": "Check the code",
            "keys": "Save your keys in Keychain",
            "record": "Tell the team you are joining",
            "service": "Start the server on this Mac",
            "probe": "Test a link through the hostname",
            "active": "Done",
        ],
        "setup-tunnel": [
            "auth": "Check your Cloudflare login",
            "tunnel": "Create the tunnel",
            "route": "Pick the route",
            "dns": "Add the DNS record",
            "token": "Store the tunnel key",
            "config": "Save the settings",
            "service": "Start the server",
            "live": "Check the hostname answers",
        ],
        "setup-r2": [
            "alias": "Check the admin key",
            "worker": "Check the Worker",
            "bucket": "Create the bucket",
            "alias-domain": "Check old hostnames",
            "routes": "Check the routes",
            "snapshot": "Take a snapshot of the settings",
            "alias-apps": "Check old apps",
            "deploy": "Deploy the Worker",
            "pointers": "Register existing links",
            "access": "Check the login gates",
            "config": "Save the settings",
            "marker": "Mark the bucket for this hostname",
            "route": "Route the hostname to the Worker",
            "alias-bind": "Bind old hostnames",
            "probe": "Check three good answers",
            "handoff": "Done",
        ],
        "setup-members": [
            "lease": "Check the admin key and Workers VPC",
            "deploy": "Deploy the Worker with member routing",
            "marker": "Mark the bucket: members on",
            "config": "Save the settings",
            "release": "Done",
        ],
    ]
}

/// The state of one running flow: the sheet reads it, and each progress line moves it.
public struct FlowRun: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case running
        /// SIGTERM sent; the process has not exited yet.
        case stopping
        /// Stopped by the person: the journal keeps the step (`at` is 1-based).
        case stopped(at: Int)
        case done
        case failed(sentence: String, next: String?)
    }

    public let kind: FlowKind
    public let title: String
    public private(set) var steps: [String]
    /// 1-based step now running (0 before the first progress line).
    public private(set) var step: Int
    public private(set) var phase: Phase
    private var printed: [Int: String] = [:]

    public init(kind: FlowKind, title: String) {
        self.kind = kind
        self.title = title
        steps = kind.stepNames
        step = 0
        phase = .running
    }

    /// One `{"progress":...}` line. A line of another verb is not this flow's.
    public mutating func apply(_ progress: Progress) {
        guard progress.verb == kind.rawValue || (kind == .setupTunnel && progress.verb == "setup") else { return }
        guard case .running = phase else { return }
        step = max(step, progress.step)
        if !progress.name.isEmpty { printed[progress.step] = progress.name }
        if progress.of != kind.stepNames.count, progress.of > 0 {
            // The CLI reports another total than the table: show the names it printed.
            steps = (1...progress.of).map { printed[$0] ?? "Step \($0)" }
        }
    }

    public mutating func stopRequested() {
        guard case .running = phase else { return }
        phase = .stopping
    }

    /// The process exited.
    public mutating func exited(status: Int32, stderr: String) {
        switch phase {
        case .stopping:
            phase = .stopped(at: max(step, 1))
        case .running:
            if status == 0 {
                step = steps.count
                phase = .done
            } else {
                let error = ErrorLine.last(inStderr: stderr)
                let line = error?.message ?? CLIResult(status: status, stdout: "", stderr: stderr, timedOut: false).lastErrorLine
                phase = .failed(sentence: line.hasPrefix("share: ") ? String(line.dropFirst(7)) : line, next: error?.next)
            }
        default: break
        }
    }

    /// The display title of step `index` (0-based).
    public func title(of index: Int) -> String {
        StepCopy.title(verb: kind.rawValue, name: steps.indices.contains(index) ? steps[index] : "")
    }

    public enum StepMark: Sendable, Equatable { case done, now, pending }

    public func mark(of index: Int) -> StepMark {
        let current = max(step, 1)
        if case .done = phase { return .done }
        if index + 1 < current { return .done }
        if index + 1 == current { return .now }
        return .pending
    }

    /// "Step n of m. Stopping keeps your place; Resume continues from this step."
    public var statusLine: String {
        "Step \(max(step, 1)) of \(steps.count). Stopping keeps your place; Resume continues from this step."
    }

    public var isActive: Bool {
        switch phase {
        case .running, .stopping: return true
        default: return false
        }
    }
}

/// The two profile-name and bucket conventions of a new tenant (D7, D9).
public enum ProfileName {
    /// `s.example.com` becomes `s-example-com`, within the CLI's 32-character profile pattern.
    public static func slug(host: String) -> String {
        var out = ""
        var lastDash = true
        for scalar in host.lowercased().unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 32 { out = String(out.prefix(32)) }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "tenant" : out
    }

    public static func bucket(host: String) -> String { "share-" + slug(host: host) }
}

/// What the join form's code field may hold: a code, or the whole `share join <host> <code>`
/// line `member add` prints, which fills both fields.
public enum JoinInput {
    public static func parse(codeField: String, hostField: String) -> (host: String, code: String) {
        let words = codeField.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        if words.count >= 4, words[0] == "share", words[1] == "join" { return (words[2], words[3]) }
        if words.count == 3, words[0] == "join" { return (words[1], words[2]) }
        return (hostField.trimmingCharacters(in: .whitespaces), codeField.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A code is one token with no leading dash and no whitespace (it reaches argv).
    public static func isValidCode(_ code: String) -> Bool {
        !code.isEmpty && code.count <= 128 && !code.hasPrefix("-")
            && code.unicodeScalars.allSatisfy { $0.value > 32 && $0.value < 127 }
    }
}

/// The argv each flow runs.
public enum FlowArgv {
    public static func join(host: String, code: String) -> [String]? {
        guard HostnameValidation.isValid(host), JoinInput.isValidCode(code) else { return nil }
        return ProfileArgs.argv(ProfileName.slug(host: host), ["join", host, code])
    }

    public static func setup(host: String) -> [String]? {
        guard HostnameValidation.isValid(host) else { return nil }
        return ProfileArgs.argv(ProfileName.slug(host: host), ["setup", host])
    }

    /// `setup <host> --r2 --bucket share-<host>`, run after the tunnel setup when "Also turn
    /// on cloud storage" is on, and by the tier button of an owner or admin (T0 to T1).
    public static func turnOnCloud(profile: String, host: String) -> [String]? {
        guard HostnameValidation.isValid(host) else { return nil }
        return ProfileArgs.argv(profile, ["setup", host, "--r2", "--bucket", ProfileName.bucket(host: host)])
    }

    /// The T1 to T2 button of an admin.
    public static func turnOnMembers(profile: String, host: String) -> [String]? {
        guard HostnameValidation.isValid(host) else { return nil }
        return ProfileArgs.argv(profile, ["setup", host, "--r2", "--bucket", ProfileName.bucket(host: host), "--members"])
    }
}

/// Reads progress lines out of a streamed stderr, which arrives in arbitrary chunks.
public struct ProgressStream: Sendable {
    private var buffer = ""

    public init() {}

    /// Feed one chunk; returns the progress lines it completed.
    public mutating func feed(_ chunk: String) -> [Progress] {
        buffer += chunk
        var found: [Progress] = []
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if let progress = Progress.parse(line: line) { found.append(progress) }
        }
        return found
    }
}
