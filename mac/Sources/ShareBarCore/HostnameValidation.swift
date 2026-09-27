import Foundation

/// Validates a setup hostname exactly as `bin/share`'s `cmd_setup` guard does
/// (`[[ $host_name =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]]`), so the setup window
/// only enables Set Up for a hostname the CLI itself would accept, not a looser or stricter
/// Swift-side guess.
public enum HostnameValidation {
    private static let pattern = #"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$"#

    public static func isValid(_ hostname: String) -> Bool {
        hostname.range(of: pattern, options: .regularExpression) != nil
    }
}
