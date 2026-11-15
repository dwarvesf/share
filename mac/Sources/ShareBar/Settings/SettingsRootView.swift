import ShareBarCore
import SwiftUI

/// The Settings window: a title, icon tabs, one pane, and the sheet overlay (D2).
struct SettingsRootView: View {
    @ObservedObject var store: SettingsStore
    @Environment(\.colorScheme) private var scheme

    static let width: CGFloat = 620

    var body: some View {
        let t = SettingsTheme(scheme)
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                header(t)
                Rectangle().fill(t.separator).frame(height: 1)
                paneBody
                if let notice = store.notice {
                    noticeBar(notice, t)
                }
            }
            if let sheet = store.sheet {
                SheetOverlay(store: store, content: sheet)
            }
        }
        .frame(width: Self.width)
        .windowSurface()
        .onExitCommand { store.escape() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Share Bar Settings")
    }

    private func header(_ t: SettingsTheme) -> some View {
        VStack(spacing: 4) {
            Text(store.pane.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(t.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 7)
                .accessibilityIdentifier("settings-title")
            HStack(spacing: 2) {
                ForEach(store.visibleTabs, id: \.self) { pane in
                    TabButton(pane: pane, selected: store.pane == pane) { store.pane = pane }
                }
            }
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var paneBody: some View {
        switch store.pane {
        case .general: GeneralPane(store: store)
        case .tenants: TenantsPane(store: store)
        case .members: MembersPane(store: store)
        case .advanced: AdvancedPane(store: store)
        }
    }

    private func noticeBar(_ notice: Notice, _ t: SettingsTheme) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(t.separator).frame(height: 1)
            HStack(spacing: 6) {
                Image(systemName: notice.tone == .ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(notice.tone == .ok ? t.ok : t.attentionInk)
                Text(notice.text).font(t.bodyFont).foregroundColor(t.label)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings-notice")
        }
    }
}

private struct TabButton: View {
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = SettingsTheme(scheme)
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: pane.symbol).font(.system(size: 16)).frame(height: 20)
                Text(pane.title).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(selected ? t.infoInk : t.secondary)
            .frame(minWidth: 66)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? t.selection : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab-\(pane.rawValue)")
        .accessibilityLabel(pane.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A two-column settings form row: the label right-aligned, the controls beside it.
struct FormRow<Content: View>: View {
    let label: String
    var topAligned = true
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = SettingsTheme(scheme)
        HStack(alignment: topAligned ? .firstTextBaseline : .center, spacing: 14) {
            Text(label).font(t.bodyFont).foregroundColor(t.label)
                .frame(width: 132, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) { content }
                .frame(width: 360, alignment: .leading)
        }
    }
}

struct FormRule: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Rectangle().fill(SettingsTheme(scheme).separator).frame(width: 506, height: 1).padding(.vertical, 2)
    }
}

struct SmallText: View {
    let text: String
    init(_ text: String) { self.text = text }
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text(text).font(SettingsTheme(scheme).metaFont).foregroundColor(SettingsTheme(scheme).secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The Members tab is built by the next sub-goal (SPEC-009 TASK-4b19); the tab itself shows
/// for an admin so the Settings shape is complete.
struct MembersPane: View {
    @ObservedObject var store: SettingsStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = SettingsTheme(scheme)
        VStack(spacing: 8) {
            Text("Members").font(t.titleFont).foregroundColor(t.label)
            Text("Your team's people and their machines.").font(t.bodyFont).foregroundColor(t.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 420)
        .accessibilityIdentifier("members-pane")
    }
}
