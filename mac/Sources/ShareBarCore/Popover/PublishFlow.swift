import Foundation

/// The add journal's progress line and the placeholder row it drives (SPEC-009 TASK-4b10,
/// SPEC-010 G9). Pure: the app only streams text in and draws the row model out.
public enum PublishProgress {
    public struct Line: Sendable, Equatable {
        public let verb: String
        public let step: Int
        public let of: Int
        public let name: String
    }

    private struct Wire: Decodable {
        struct Body: Decodable {
            let verb: String
            let step: Int
            let of: Int
            let name: String?
        }
        let progress: Body
    }

    /// Reads one stderr line; nil for anything that is not a progress line.
    public static func parse(_ text: String) -> Line? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{\"progress\""), let data = trimmed.data(using: .utf8),
              let body = (try? JSONDecoder().decode(Wire.self, from: data))?.progress else { return nil }
        return Line(verb: body.verb, step: body.step, of: body.of, name: body.name ?? "")
    }

    /// The reducer event one line of the `add` journal means for `file`; other verbs' lines move nothing.
    public static func event(file: String, line: String) -> PopoverEvent? {
        guard let parsed = parse(line), parsed.verb == "add", parsed.of > 0 else { return nil }
        return .publishStep(file: file, step: parsed.step, of: parsed.of)
    }

    /// The journal's step name as a word for the row (`op_steps_add` of the CLI, plus the fake CLI's).
    public static func word(for name: String) -> String {
        switch name {
        case "pointer": return "Preparing"
        case "publish", "upload": return "Uploading"
        case "stage": return "Staging"
        case "access": return "Setting access"
        case "host": return "Checking the host"
        case "gate": return "Checking the gate"
        case "row": return "Adding the row"
        case "": return "Working"
        default: return name.prefix(1).uppercased() + name.dropFirst()
        }
    }
}

/// Splits a streamed chunk into whole lines: a chunk may end inside a line.
public struct LineBuffer: Sendable {
    private var pending = ""

    public init() {}

    public mutating func feed(_ chunk: String) -> [String] {
        pending += chunk
        var lines = pending.components(separatedBy: "\n")
        pending = lines.removeLast()
        return lines
    }
}

/// The placeholder row of a file being published: its name, the step, a progress bar.
public struct UploadRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let meta: String
    /// 0 to 1; nil before the first step, when the bar has nothing to say.
    public let fraction: Double?

    public init(publish: Publish, stepName: String?) {
        id = publish.file
        title = (publish.file as NSString).lastPathComponent
        if publish.step > 0, publish.of > 0 {
            meta = "Step \(publish.step) of \(publish.of) · \(PublishProgress.word(for: stepName ?? ""))"
            fraction = min(1, Double(publish.step) / Double(publish.of))
        } else {
            meta = "Starting…"
            fraction = nil
        }
    }
}

/// How a finished `add` reads: the link to copy, or the CLI's sentence and its next step.
public enum PublishOutcome {
    public static func result(status: Int32, stdout: String, stderr: String, fallbackURL: String?) -> PublishResult {
        if status == 0 {
            let printed = stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .last { $0.hasPrefix("https://") || $0.hasPrefix("http://") }
            return .copied(url: printed ?? fallbackURL ?? "")
        }
        if let error = ErrorLine.last(inStderr: stderr) {
            var sentence = "Couldn't publish: \(error.message)"
            if let next = error.next { sentence += " Next: \(next)" }
            return .failed(sentence: sentence)
        }
        let line = stderr.split(separator: "\n").map(String.init)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("{") }
        let plain = line.map { $0.hasPrefix("share: ") ? String($0.dropFirst(7)) : $0 } ?? "share exited \(status)"
        return .failed(sentence: "Couldn't publish: \(plain)")
    }
}

/// The drop overlay's words: where the link will live and where its bytes go.
public struct DropOverlayModel: Sendable, Equatable {
    public let headline: String
    public let detail: String

    /// `storedOn` is `this Mac` for a tenant with no cloud storage or a machine default, else `the cloud`.
    public init(host: String, storedOn: String) {
        headline = "Release to share on \(host)"
        detail = "Stored on \(storedOn). Copies the link when done."
    }

    /// General's default storage for a tenant: the CLI's `storage_default` on a tenant with R2, else this Mac.
    public static func storedOn(_ state: Snapshot?) -> String {
        if state?.r2 == true, state?.storageDefault == "cloud" { return "the cloud" }
        return "this Mac"
    }
}
