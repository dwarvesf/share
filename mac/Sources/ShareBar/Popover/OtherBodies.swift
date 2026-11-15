import ShareBarCore
import SwiftUI

/// The needs-a-look view: lines grouped by tenant, the current tenant first, one action each.
struct IssuesView: View {
    @ObservedObject var store: PopoverStore
    @Environment(\.colorScheme) private var scheme
    private var theme: Theme { Theme(scheme) }

    var body: some View {
        let list = store.issues
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                IconButton(theme: theme, symbol: "chevron.left", id: "back-button", label: "Back to links", action: store.back)
                Text("Needs a look").font(theme.titleFont).foregroundColor(theme.label)
                Spacer()
            }
            .padding(.leading, 8).padding(.trailing, 10).padding(.vertical, 8)
            Rectangle().fill(theme.separator).frame(height: 1)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if list.groups.isEmpty {
                        Text(IssueList.emptyText).font(theme.bodyFont).foregroundColor(theme.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 28)
                            .accessibilityIdentifier("issues-empty")
                    }
                    ForEach(list.groups) { group in
                        HStack(spacing: 6) {
                            Text(group.host).font(theme.monoFont).foregroundColor(theme.secondary)
                            if group.isCurrent {
                                Text("current").font(.system(size: 10, weight: .medium)).foregroundColor(theme.infoInk)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.info.opacity(0.16)))
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 2)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("issues-group-\(group.profile)")
                        ForEach(group.lines) { line in IssueRow(store: store, line: line) }
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            if let footer = store.state.footer {
                Rectangle().fill(theme.separator).frame(height: 1)
                Text(footer.text).font(theme.metaFont).foregroundColor(footer.kind == .failure ? theme.errorInk : theme.label)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .accessibilityIdentifier("footer-status")
            }
        }
    }
}

private struct IssueRow: View {
    @ObservedObject var store: PopoverStore
    let line: IssueLine
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    private var theme: Theme { Theme(scheme) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: line.symbol).font(.system(size: 14)).foregroundColor(theme.attentionInk).frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(line.title).font(theme.bodyFont).foregroundColor(theme.label).fixedSize(horizontal: false, vertical: true)
                Text(line.detail).font(theme.metaFont).foregroundColor(theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if let action = line.action {
                PanelButton(theme: theme, title: action.label, id: "issue-action-\(line.id)") { store.perform(action) }
            }
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: theme.rowRadius).fill(hovering ? theme.hover : .clear))
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(line.title). \(line.detail)")
        .accessibilityIdentifier("issue-\(line.id)")
    }
}

/// No tenant yet: the two ways to add one.
struct FirstRunView: View {
    @ObservedObject var store: PopoverStore
    @Environment(\.colorScheme) private var scheme
    private var theme: Theme { Theme(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Share Bar").font(theme.titleFont).foregroundColor(theme.label).padding(.horizontal, 6)
                Spacer()
                IconButton(theme: theme, symbol: "gearshape", id: "settings-button", label: "Settings") { store.openSettings(.general) }
            }
            .padding(.leading, 10).padding(.trailing, 8).padding(.top, 8).padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 10) {
                Text("Share files from your Mac at a link on a hostname you or your team own.")
                    .font(theme.bodyFont).foregroundColor(theme.secondary).fixedSize(horizontal: false, vertical: true)
                PanelButton(theme: theme, title: "Join a team with a code…", id: "first-join", prominent: true) { store.openAdd(.join) }
                PanelButton(theme: theme, title: "Set up my own hostname…", id: "first-setup") { store.openAdd(.setup) }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
        }
    }
}
