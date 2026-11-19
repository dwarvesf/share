import Foundation

extension Failure {
    /// The sentence the Settings window shows when `profiles` could not be read.
    public var sentence: String {
        switch self {
        case .cliNotFound: return "The handout command was not found. Install it, then try again."
        case .oldCLI: return "This handout command is too old. Update handout to 0.10."
        case .other(let line): return Redact.tokenShaped(CLIPrefix.strip(line))
        }
    }
}
