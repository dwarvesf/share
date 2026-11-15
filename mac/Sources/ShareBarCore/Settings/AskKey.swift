import Foundation

/// A command that runs with a key the person typed once (gap G3). The key is a value of this
/// struct's environment only: it never enters argv, the app's defaults or a log, and the
/// struct is dropped when the command exits.
public struct AskedKeyCommand: Sendable {
    public let argv: [String]
    public let environment: [String: String]

    public init(argv: [String], variable: String, key: String) {
        self.argv = argv
        environment = [variable: key]
    }

    /// One command that needs several keys (a member verb: the admin key and the minter key).
    public init(argv: [String], environment: [String: String]) {
        self.argv = argv
        self.environment = environment
    }

    /// Runs the command; the key reaches the child through its environment and nowhere else.
    public func spawn(onOutput: @escaping (String) -> Void = { _ in }) -> CLIJob {
        CLI.spawnCancellable(argv, environment: MutationQueue.environment.merging(environment) { _, new in new }, onOutput: onOutput)
    }
}

/// The stages of a command that may need the admin key first.
public enum AdminKeyNeed: Sendable, Equatable {
    /// The profile has a stored source (a command), or the person chose to run it: run now.
    case none
    /// "Ask me each time": the ask-for-key sheet opens before the command runs.
    case ask
}
