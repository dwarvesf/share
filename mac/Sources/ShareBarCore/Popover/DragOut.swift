import Foundation

/// What a row carries when it is dragged out of the popover (SPEC-009 TASK-4b11): the link as a
/// URL and as plain text, so a text field and a rich editor both take it.
public struct DragPayload: Sendable, Equatable {
    public let url: URL
    public let text: String
    /// The footer sentence while this row is in the air.
    public let footerHint: String

    /// Nil for a row that must not drag: `expired` and `revoked` (DEC-52), or a url that is not one.
    public init?(row: RowModel) {
        guard row.canDrag, let url = URL(string: row.url), url.scheme != nil else { return nil }
        self.url = url
        text = row.url
        footerHint = "Drop to paste the link to \(row.title)"
    }

    /// The pasteboard items of the drag, URL first.
    public func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider(object: url as NSURL)
        provider.registerObject(text as NSString, visibility: .all)
        return provider
    }
}

extension PopoverState {
    /// The footer's drag hint, or nil when no row of this popover is being dragged.
    public func dragOutHint(rows: [RowModel]) -> String? {
        guard let id = draggingOut, let row = rows.first(where: { $0.id == id }) else { return nil }
        return DragPayload(row: row)?.footerHint
    }

    /// `reduce`, plus the focus the Quick Look spec asks for: leaving Quick Look hands focus back
    /// to the row it opened on (TASK-4b12), unless the event already named a focus (the hotkey).
    public func reduceRestoringFocus(_ event: PopoverEvent) -> (state: PopoverState, effects: [PopoverEffect]) {
        var result = reduce(event)
        if case .quickLook(let id, _) = mode, result.state.mode.kind != .quickLook {
            let named = result.effects.contains { if case .focus = $0 { return true } else { return false } }
            if !named { result.effects.append(.focus(id)) }
        }
        return result
    }
}
