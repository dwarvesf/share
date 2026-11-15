import ShareBarCore
import SwiftUI

/// The All links window (SPEC-009 TASK-4b20, interactions doc 3a): counted tabs, a search that
/// has focus on open, a table with checkboxes, and a bar for the selection.
struct AllLinksView: View {
    @ObservedObject var store: AllLinksStore
    @Environment(\.colorScheme) private var scheme
    @FocusState private var searchFocused: Bool

    static let width: CGFloat = 620
    private static let nameWidth: CGFloat = 196

    var body: some View {
        let t = SettingsTheme(scheme)
        let model = store.model
        VStack(spacing: 0) {
            Text("All links on \(model.host)")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(t.secondary)
                .frame(maxWidth: .infinity).padding(.top, 7).padding(.bottom, 10)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("all-links-title")
            Rectangle().fill(t.separator).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                topBar(model, t)
                if !model.state.selection.isEmpty { bulkBar(model, t) }
                table(model, t)
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
            footer(model, t)
        }
        .frame(width: Self.width)
        .ignoresSafeArea(.container, edges: .top)
        .windowSurface()
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("All links")
    }

    // MARK: top bar

    private func topBar(_ model: AllLinksModel, _ t: SettingsTheme) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(AllLinksTab.allCases, id: \.self) { tab in
                    let on = model.state.tab == tab
                    Button { store.state.show(tab) } label: {
                        Text("\(tab.title) \(model.counts[tab] ?? 0)")
                            .font(.system(size: 11, weight: .medium)).foregroundColor(t.label)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 5).fill(on ? t.field : .clear)
                                .shadow(color: .black.opacity(on ? 0.14 : 0), radius: 1, y: 1))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? t.separator : .clear, lineWidth: 0.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("lf-\(tab.rawValue)")
                    .accessibilityLabel("\(tab.title), \(model.counts[tab] ?? 0)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(t.hover))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Show")
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(t.tertiary).accessibilityHidden(true)
                ZStack(alignment: .leading) {
                    if model.state.query.isEmpty {
                        Text("Search").font(t.bodyFont).foregroundColor(t.tertiary).allowsHitTesting(false).accessibilityHidden(true)
                    }
                    TextField("", text: Binding(get: { store.state.query }, set: { store.setQuery($0) }))
                        .textFieldStyle(.plain).font(t.bodyFont).foregroundColor(t.label)
                        .focused($searchFocused)
                        .accessibilityLabel("Search links")
                        .accessibilityIdentifier("lq")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(width: 180)
            .background(RoundedRectangle(cornerRadius: 6).fill(t.field))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(searchFocused ? t.focus : t.softBorder, lineWidth: searchFocused ? 2 : 1))
        }
    }

    // MARK: bulk bar

    private func bulkBar(_ model: AllLinksModel, _ t: SettingsTheme) -> some View {
        HStack(spacing: 8) {
            Text(model.selectedText).font(.system(size: 13, weight: .medium)).foregroundColor(t.label)
                .accessibilityIdentifier("bulk-count")
            Spacer(minLength: 0)
            Button("Copy links") { store.bulkCopy() }.sbButton()
                .disabled(model.bulkCopyCount == 0).accessibilityIdentifier("lb-copy")
            Button("Remove…") { store.bulkRemove() }.sbButton(.destructiveText)
                .disabled(model.bulkRemoveArgv == nil).accessibilityIdentifier("lb-rm")
            Button { store.state.clear() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundColor(t.secondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Clear selection").accessibilityIdentifier("lb-x")
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(t.info.opacity(0.10)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selection")
    }

    // MARK: table

    private func table(_ model: AllLinksModel, _ t: SettingsTheme) -> some View {
        VStack(spacing: 0) {
            header(model, t)
            Rectangle().fill(t.separator).frame(height: 1)
            if let empty = model.emptyText {
                Text(empty).font(t.bodyFont).foregroundColor(t.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 36)
                    .accessibilityIdentifier("links-empty")
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                            LinkTableRow(store: store, row: row, selected: model.state.selection.contains(row.id))
                            if index < model.rows.count - 1 { Rectangle().fill(t.separator).frame(height: 1) }
                        }
                    }
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(t.field))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.separator, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Links")
    }

    private func header(_ model: AllLinksModel, _ t: SettingsTheme) -> some View {
        let all = !model.rows.isEmpty && model.rows.allSatisfy { model.state.selection.contains($0.id) }
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { all }, set: { _ in store.state.selectAll(model.rows) }))
                .toggleStyle(.checkbox).labelsHidden().frame(width: 18)
                .accessibilityLabel("Select all").accessibilityIdentifier("l-all")
            Text("Name").frame(width: Self.nameWidth, alignment: .leading)
            Text("Owner").frame(width: 62, alignment: .leading)
            Text("Lives on").frame(maxWidth: .infinity, alignment: .leading)
            Text("Expires").frame(width: 58, alignment: .trailing)
            Text("Views").frame(width: 44, alignment: .trailing)
            Color.clear.frame(width: 26)
        }
        .font(.system(size: 11, weight: .medium)).foregroundColor(t.secondary)
        .padding(.horizontal, 10).frame(height: 28)
        .background(t.hover.opacity(0.5))
    }

    // MARK: footer

    private func footer(_ model: AllLinksModel, _ t: SettingsTheme) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(t.separator).frame(height: 1)
            HStack(spacing: 8) {
                if let pending = store.pendingToast {
                    Image(systemName: "checkmark.circle").foregroundColor(t.secondary).accessibilityHidden(true)
                    Text(pending).font(t.metaFont).foregroundColor(t.label).lineLimit(2)
                        .accessibilityIdentifier("links-toast")
                        .accessibilityAddTraits(.updatesFrequently)
                    Spacer(minLength: 8)
                    Button("Undo") { store.undo() }.sbButton().accessibilityIdentifier("undo-button")
                } else if let toast = store.toast {
                    Image(systemName: "checkmark.circle").foregroundColor(t.ok).accessibilityHidden(true)
                    Text(toast).font(t.metaFont).foregroundColor(t.label).lineLimit(2)
                        .accessibilityIdentifier("links-toast")
                        .accessibilityAddTraits(.updatesFrequently)
                    Spacer()
                } else {
                    Text(model.footer).font(t.metaFont).foregroundColor(t.secondary)
                        .accessibilityIdentifier("links-footer")
                    Spacer()
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 9)
            .frame(minHeight: 38)
        }
    }
}

private struct LinkTableRow: View {
    @ObservedObject var store: AllLinksStore
    let row: AllLinksRow
    let selected: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = SettingsTheme(scheme)
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { selected }, set: { _ in store.state.toggle(row.id) }))
                .toggleStyle(.checkbox).labelsHidden().frame(width: 18)
                .accessibilityLabel("Select \(row.row.title)").accessibilityIdentifier("lc-\(row.id)")
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6).fill(t.hover).frame(width: 24, height: 24)
                    .overlay(Image(systemName: row.row.glyph).font(.system(size: 11)).foregroundColor(row.dimmed ? t.tertiary : t.secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.row.title).font(.system(size: 13, weight: .medium))
                        .foregroundColor(row.dimmed ? t.secondary : t.label).lineLimit(1).truncationMode(.middle)
                    metaLine(t)
                }
            }
            .frame(width: 196, alignment: .leading)
            Text(row.owner).frame(width: 62, alignment: .leading)
            Text(row.livesOn).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            Text(row.expires).monospacedDigit().frame(width: 58, alignment: .trailing)
            Text(row.views.map(String.init) ?? "").monospacedDigit().frame(width: 44, alignment: .trailing)
            Button { store.copy(row) } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 12))
                    .foregroundColor(t.secondary).frame(width: 26, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!row.canCopy)
            .opacity(row.canCopy ? 1 : 0.35)
            .accessibilityLabel("Copy link to \(row.row.title)")
            .accessibilityIdentifier("lcopy-\(row.id)")
        }
        .font(t.metaFont).foregroundColor(row.dimmed ? t.tertiary : t.secondary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? t.info.opacity(0.10) : .clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityIdentifier("lr-\(row.id)")
    }

    @ViewBuilder
    private func metaLine(_ t: SettingsTheme) -> some View {
        let parts: [String] = [row.stateWord, row.created].compactMap { $0 }
        if !parts.isEmpty {
            HStack(spacing: 0) {
                if let word = row.stateWord {
                    Text(word).foregroundColor(row.tab == .expired ? t.secondary : t.attentionInk)
                    if row.created != nil { Text(" · ") }
                }
                if let created = row.created { Text(created) }
            }
            .font(t.metaFont).foregroundColor(t.secondary).lineLimit(1)
        }
    }
}
