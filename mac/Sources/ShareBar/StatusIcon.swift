import AppKit
import ShareBarCore

/// Renders a `MenuModel.Icon` onto the status item's button: the Share mark drawn in code
/// (`StatusGlyph`), an open ring with a dot while serving and a closed ring otherwise. A
/// glyph that fails to draw falls back to a plain text title so the status item is never
/// blank.
enum StatusIcon {
    static func apply(_ icon: Icon, to button: NSStatusBarButton) {
        if let image = StatusGlyph.image(serving: icon == .connected) {
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "Handout Bar"
        }
    }
}
