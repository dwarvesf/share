import AppKit
import ShareBarCore

/// Renders a `MenuModel.Icon` onto the status item's button. Each SF Symbol is verified to
/// resolve via `NSImage(systemSymbolName:)` (both ship on macOS 13, the package's minimum,
/// but the spec asks for the check rather than assuming); a symbol that fails to resolve
/// falls back to a plain text title so the status item is never blank.
enum StatusIcon {
    private static func symbolName(for icon: Icon) -> String {
        switch icon {
        case .connected: return "antenna.radiowaves.left.and.right"
        case .disconnected: return "antenna.radiowaves.left.and.right.slash"
        }
    }

    static func apply(_ icon: Icon, to button: NSStatusBarButton) {
        let name = symbolName(for: icon)
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "Share Bar"
        }
    }
}
