import Foundation

extension Failure {
    /// The sentence the Settings window shows when `profiles` could not be read.
    public var sentence: String {
        switch self {
        case .cliNotFound: return "The share command was not found. Install it, then try again."
        case .oldCLI: return "This share command is too old. Update share to 0.10."
        case .other(let line): return Redact.tokenShaped(line.hasPrefix("share: ") ? String(line.dropFirst(7)) : line)
        }
    }
}
