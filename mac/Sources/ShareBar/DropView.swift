import AppKit

/// The status item button's drop target (TASK-010).
///
/// Spike finding: a subview whose `hitTest(_:)` returns nil is invisible to drag delivery
/// too, not only to clicks. AppKit resolves which view a window hands a drag to with the
/// same `hitTest(_:)` recursion it uses for mouse routing: `NSView`'s default
/// implementation, when a subview's own `hitTest` returns nil for the point, treats that
/// subview as absent and falls through to returning the SUPERVIEW itself, it never walks
/// back down into the rejected subview for either a click or a drag. That is exactly why
/// the plain "subview with `hitTest` -> nil" shape lets clicks reach the button (the
/// button, as the superview, is what hitTest falls through to), and exactly why the same
/// shape can never receive a `draggingEntered` callback: the window's drag-destination
/// search finds the button, not the subview, at that point, and the button (a sealed
/// `NSStatusBarButton` we cannot subclass or register) was never registered for any
/// dragged type. Neither literal spec option is viable without subclassing a private
/// AppKit class (the status bar button, or its window), so this view instead stays fully
/// hit-testable (default `hitTest`, no override) and forwards plain clicks to the button
/// itself via `performClick`, which keeps the button's normal "click opens the menu"
/// behavior while making the view a real, supported `NSDraggingDestination`.
final class DropView: NSView {
    /// `NSFilePromiseReceiver.readableDraggedTypes` comes back as `[String]`; every pasteboard
    /// API here wants `[NSPasteboard.PasteboardType]`, so it is converted once and reused.
    private static let filePromiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    var onFiles: (([URL]) -> Void)?
    var onFilePromise: (() -> Void)?
    private weak var forwardTarget: NSStatusBarButton?

    init(forwarding button: NSStatusBarButton) {
        forwardTarget = button
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL] + Self.filePromiseTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DropView does not support NSCoding")
    }

    override func mouseDown(with event: NSEvent) {
        forwardTarget?.performClick(nil)
    }

    // NSView already conforms to NSDraggingDestination (default no-op implementations), so
    // these are overrides, not a fresh protocol conformance.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if isFilePromise(sender) {
            onFilePromise?()
            return false
        }
        guard let urls = fileURLs(from: sender), !urls.isEmpty else { return false }
        onFiles?(urls)
        return true
    }

    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        // A file promise is accepted into draggingEntered/Updated (so performDragOperation
        // gets a chance to show the refusal alert instead of AppKit silently rejecting the
        // drag before it ever reaches app code) but offers no visible drop operation.
        if isFilePromise(sender) { return [] }
        return fileURLs(from: sender) != nil ? .copy : []
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL]? {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
    }

    private func isFilePromise(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.availableType(from: Self.filePromiseTypes) != nil
    }
}
