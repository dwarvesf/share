import AppKit
import Combine
import Network
import Quartz
import ShareBarCore
import SwiftUI

/// The Quick Look body (SPEC-009 TASK-4b12, interactions doc 3a): Close, the name, Open in
/// browser, Copy link (the default button), a preview, the URL in SF Mono and the meta line.
struct QuickLookView: View {
    let model: QuickLookModel
    let onClose: () -> Void
    let onOpen: () -> Void
    let onCopy: () -> Void
    /// Screenshot hook only: `QLPreviewView` draws out of process, so an offscreen capture of it is
    /// blank; the capture composes the same file through `QLThumbnailGenerator` instead.
    var thumbnail = false
    @Environment(\.colorScheme) private var scheme
    @State private var portAnswers: Bool?
    private var theme: Theme { Theme(scheme) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                IconButton(theme: theme, symbol: "xmark", id: "ql-close", label: model.closeLabel, action: onClose)
                Text(model.title).font(.system(size: 13, weight: .semibold)).foregroundColor(theme.label)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity)
                PanelButton(theme: theme, title: model.openTitle, id: "ql-open", action: onOpen)
                    .overlay(RoundedRectangle(cornerRadius: theme.buttonRadius).stroke(theme.label.opacity(0.2), lineWidth: 1))
                // Copy link is the default button, so it carries the focus ring, as in the design.
                PanelButton(theme: theme, title: model.copyTitle, id: "ql-copy", prominent: true, action: onCopy)
                    .overlay(RoundedRectangle(cornerRadius: theme.buttonRadius + 2).stroke(theme.focus.opacity(0.55), lineWidth: 2).padding(-2))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Rectangle().fill(theme.separator).frame(height: 1)
            preview
                .frame(maxWidth: .infinity).frame(height: 300)
                .background(theme.label.opacity(0.04))
                .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(model.url).font(theme.monoFont).foregroundColor(theme.label).lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("ql-url")
                Text(model.meta).font(theme.metaFont).foregroundColor(theme.secondary).lineLimit(1)
                    .accessibilityIdentifier("ql-meta")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: QuickLookModel.width)
        .background(theme.windowSurface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick Look: \(model.title)")
    }

    @ViewBuilder
    private var preview: some View {
        switch model.source {
        case .file(let path):
            Group {
                if thumbnail { ThumbnailPreview(path: path) } else { LocalPreview(path: path) }
            }
            .accessibilityIdentifier("ql-preview-file")
        case .folder(let path):
            FolderPreview(theme: theme, path: path)
                .accessibilityIdentifier("ql-preview-folder")
        case .liveServer(let port):
            VStack(spacing: 6) {
                Image(systemName: "bolt.horizontal").font(.system(size: 34)).foregroundColor(theme.info).accessibilityHidden(true)
                Text("Live server").font(.system(size: 15, weight: .semibold)).foregroundColor(theme.label)
                Text(model.liveDetail).font(theme.metaFont).foregroundColor(theme.secondary).multilineTextAlignment(.center)
                if let port, let answers = portAnswers {
                    Text(answers ? "Something answers on :\(port) now." : "Nothing answers on :\(port) right now.")
                        .font(theme.metaFont).foregroundColor(answers ? theme.ok : theme.attentionInk)
                }
            }
            .padding(24)
            .task { if let port { portAnswers = await PortProbe.answers(port: port) } }
            .accessibilityIdentifier("ql-preview-live")
        case .glyph(let name):
            VStack(spacing: 8) {
                Image(systemName: name).font(.system(size: 46, weight: .light)).foregroundColor(theme.secondary).accessibilityHidden(true)
                Text(model.meta).font(theme.metaFont).foregroundColor(theme.secondary)
            }
            .accessibilityIdentifier("ql-preview-glyph")
        }
    }
}

/// A connect to localhost: is anything listening. No request, no bytes, nothing leaves the Mac.
enum PortProbe {
    static func answers(port: String) async -> Bool {
        guard let value = UInt16(port), let nwPort = NWEndpoint.Port(rawValue: value) else { return false }
        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            @Sendable func finish(_ result: Bool) {
                guard !once.done else { return }
                once.done = true
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                case .waiting: finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { finish(false) }
        }
    }
}

/// `QLPreviewView` on the file in `pub/<id>`.
struct LocalPreview: NSViewRepresentable {
    let path: String

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = URL(fileURLWithPath: path) as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL)?.path != path { view.previewItem = URL(fileURLWithPath: path) as NSURL }
    }
}

import QuickLookThumbnailing

/// The file's Quick Look thumbnail, for the offscreen screenshot hook.
struct ThumbnailPreview: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() } else { Color.clear }
        }
        .task {
            let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 560, height: 300),
                                                       scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = NSImage(cgImage: rep.cgImage, size: rep.cgImage.size)
            }
        }
    }
}

private extension CGImage {
    var size: NSSize { NSSize(width: CGFloat(width) / 2, height: CGFloat(height) / 2) }
}

/// The entries of a shared folder, as the prototype lists them.
struct FolderPreview: View {
    let theme: Theme
    let path: String

    private var entries: [(name: String, isDir: Bool)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().prefix(8).map { name in
            var dir: ObjCBool = false
            FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(name), isDirectory: &dir)
            return (name, dir.boolValue)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries, id: \.name) { entry in
                HStack(spacing: 8) {
                    Image(systemName: entry.isDir ? "folder" : (entry.name.hasSuffix(".mp4") || entry.name.hasSuffix(".mov") ? "film" : "doc")).font(.system(size: 13)).foregroundColor(theme.secondary).frame(width: 16)
                    Text(entry.isDir ? entry.name + "/" : entry.name).font(theme.bodyFont).foregroundColor(theme.label)
                    Spacer()
                }
                .padding(.horizontal, 6).padding(.vertical, 5)
            }
        }
        .padding(6)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.separator, lineWidth: 1))
    }
}

/// The panel that shows the Quick Look view without taking the app's focus: non-activating,
/// floating, up to 560 pt wide.
@MainActor
final class QuickLookPanelController: NSObject {
    private let store: PopoverStore
    private var panel: NSPanel?
    private var cancellable: AnyCancellable?
    private(set) var shownRowID: String?
    /// The window the panel centers on (the popover's), set by the popover controller.
    var anchorWindow: () -> NSWindow? = { nil }
    var appearance: NSAppearance?
    /// Told when the panel appears or goes, so the popover can hold still while it is up.
    var onVisibilityChange: (Bool) -> Void = { _ in }

    init(store: PopoverStore) {
        self.store = store
        super.init()
        cancellable = store.$state.map { state -> String? in
            if case .quickLook(let id, _) = state.mode { return id }
            return nil
        }
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] id in MainActor.assumeIsolated { self?.sync(to: id) } }
    }

    var window: NSWindow? { panel }

    private func sync(to id: String?) {
        guard id != shownRowID else { return }
        shownRowID = id
        if id == nil { hide() } else { show() }
    }

    func show() {
        guard let model = store.quickLook else { return }
        let hosting = NSHostingController(rootView: QuickLookView(
            model: model,
            onClose: { [store] in store.send(.closeQuickLook) },
            onOpen: { [store] in store.send(.quickLookOpen(url: model.url)) },
            onCopy: { [store] in store.copyFromQuickLook(rowID: model.rowID) }
        ))
        hosting.sizingOptions = [.preferredContentSize]
        let panel = self.panel ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: QuickLookModel.width, height: 400),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = appearance
        panel.contentViewController = hosting
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 12
        panel.contentView?.layer?.masksToBounds = true
        panel.setContentSize(hosting.view.fittingSize)
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel
        onVisibilityChange(true)
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        onVisibilityChange(false)
    }

    private func position(_ panel: NSPanel) {
        let anchor = anchorWindow()
        let screen = anchor?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        let midX = anchor?.frame.midX ?? visible.midX
        let x = max(visible.minX + 16, min(midX - size.width / 2, visible.maxX - size.width - 16))
        let top = anchor.map { $0.frame.maxY - 24 } ?? visible.maxY - 40
        panel.setFrameOrigin(NSPoint(x: x, y: max(visible.minY + 16, top - size.height)))
    }
}
