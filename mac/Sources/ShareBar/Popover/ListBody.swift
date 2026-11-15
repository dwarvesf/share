import ShareBarCore
import SwiftUI

/// Header, search, scope, the recent list, "Show all N links…" and the footer.
struct ListBody: View {
    @ObservedObject var store: PopoverStore
    @Environment(\.colorScheme) private var scheme
    @FocusState private var searchField: Bool
    private var theme: Theme { Theme(scheme) }
    static let maxListHeight: CGFloat = 360

    var body: some View {
        let model = store.viewModel
        VStack(spacing: 0) {
            header(model)
            search(model)
            if let scope = model.scope { scopeControl(scope) }
            list(model)
            if let title = model.showAllTitle {
                Button(action: store.openAllLinks) {
                    Text(title).font(theme.metaFont).foregroundColor(theme.secondary)
                        .padding(.leading, 16).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("show-all")
                .accessibilityLabel(title)
            }
            FooterBar(store: store, footer: model.footer)
        }
    }

    // MARK: header

    private func header(_ model: PopoverViewModel) -> some View {
        HStack(spacing: 4) {
            Button { store.tenantMenuOpen = true } label: {
                HStack(spacing: 4) {
                    Text(model.header.title).font(theme.titleFont).foregroundColor(theme.label).lineLimit(1).truncationMode(.middle)
                    if model.header.hasChevron {
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundColor(theme.secondary)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tenant-button")
            .accessibilityLabel(model.header.hasChevron ? "\(model.header.title), choose a tenant" : model.header.title)
            Spacer(minLength: 8)
            IconButton(theme: theme, symbol: "plus", id: "add-button", label: "Share a file", action: store.onAddFile)
            IconButton(theme: theme, symbol: "gearshape", id: "settings-button", label: "Settings") { store.openSettings(.general) }
        }
        .padding(.leading, 10).padding(.trailing, 8).padding(.top, 8).padding(.bottom, 6)
    }

    // MARK: search

    private func search(_ model: PopoverViewModel) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(theme.secondary).accessibilityHidden(true)
            // SwiftUI ignores a color on `prompt:`, so the placeholder is drawn here in the tertiary ink.
            TextField("", text: Binding(get: { store.query }, set: { store.setQuery($0) }))
                .textFieldStyle(.plain)
                .font(theme.bodyFont)
                .foregroundColor(theme.label)
                .overlay(alignment: .leading) {
                    if store.query.isEmpty {
                        Text(model.search.placeholder).font(theme.bodyFont).foregroundColor(theme.tertiary)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .focused($searchField)
                .onAppear { if store.searchFocused { searchField = true } }
                .onChange(of: store.searchFocused) { searchField = $0 }
                .onChange(of: searchField) { if !$0 { store.searchFocused = false } }
                .accessibilityIdentifier("search")
                .accessibilityLabel("Search links")
            if store.query.isEmpty {
                Text(model.search.hint).font(.system(size: 10.5, weight: .medium)).foregroundColor(theme.tertiary)
                    .padding(.horizontal, 4)
                    .overlay(RoundedRectangle(cornerRadius: theme.chipRadius).stroke(theme.keycapBorder, lineWidth: 1))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.hover))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.focus, lineWidth: store.searchFocused ? 2 : 0))
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    // MARK: scope

    private func scopeControl(_ scope: ScopeModel) -> some View {
        HStack(spacing: 2) {
            scopeButton(scope.mineTitle, id: "scope-mine", selected: scope.selected == .mine) { store.setScope(.mine) }
            scopeButton(scope.teamTitle, id: "scope-team", selected: scope.selected == .team) { store.setScope(.team) }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.hover))
        .padding(.horizontal, 10).padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Whose links")
    }

    private func scopeButton(_ title: String, id: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundColor(theme.label)
                .frame(maxWidth: .infinity).padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(selected ? (scheme == .dark ? Color.white.opacity(0.16) : Color.white) : .clear)
                        .shadow(color: .black.opacity(selected && scheme == .light ? 0.14 : 0), radius: 1, y: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: list

    private func list(_ model: PopoverViewModel) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                ForEach(store.uploadRows) { upload in UploadRowView(theme: theme, upload: upload) }
                if let empty = model.emptyText, store.uploadRows.isEmpty {
                    Text(empty).font(theme.bodyFont).foregroundColor(theme.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 28).padding(.horizontal, 20)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("empty")
                }
                ForEach(model.rows) { row in
                    RowView(store: store, row: row, scope: model.scopeValue)
                }
            }
            .padding(.top, 2).padding(.bottom, 6)
        }
        .frame(maxHeight: Self.maxListHeight)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent links")
    }
}

/// One link row: type glyph, name, meta line, More on hover and focus.
struct RowView: View {
    @ObservedObject var store: PopoverStore
    let row: RowModel
    let scope: LinkScope
    @Environment(\.colorScheme) private var scheme
    private var theme: Theme { Theme(scheme) }

    var body: some View {
        let hovering = store.hoveredRow == row.id
        let focused = store.focusedRow == row.id && store.keyboardFocus
        let menuOpen = store.menuRowID == row.id
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(theme.hover).frame(width: 28, height: 28)
                .overlay(Image(systemName: row.glyph).font(.system(size: 13)).foregroundColor(row.dimmed ? theme.dimmed : theme.secondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(theme.bodyFont).foregroundColor(row.dimmed ? theme.dimmed : theme.label)
                    .lineLimit(1).truncationMode(.middle)
                Text(row.meta).font(theme.metaFont).foregroundColor(theme.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if let age = row.age {
                Text(age).font(theme.metaFont).foregroundColor(theme.tertiary)
                    .frame(minWidth: 46, alignment: .trailing)
                    .accessibilityLabel(age == "today" ? "added today" : "added \(age) ago")
            }
            Button { store.openMenu(row.id) } label: {
                Image(systemName: "ellipsis").font(.system(size: 13)).foregroundColor(hovering || focused || menuOpen ? theme.secondary : .clear)
                    .frame(width: theme.iconButton, height: theme.iconButton)
                    .background(RoundedRectangle(cornerRadius: theme.buttonRadius).fill(menuOpen ? theme.hover : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("more-\(row.id)")
            .accessibilityLabel("More for \(row.title)")
            .background(GeometryReader { proxy in
                Color.clear.preference(key: MoreFramesKey.self, value: [row.id: proxy.frame(in: .named("pop"))])
            })
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 4)
        .frame(minHeight: theme.minRowHeight)
        .overlay(alignment: .trailing) {
            // The design's `.row.flash::after`: laid over the age, not between the name and it.
            if store.flashRow == row.id {
                Text("Copied").font(.system(size: 11, weight: .semibold)).foregroundColor(theme.ok)
                    .padding(.horizontal, 4).background(theme.surface).padding(.trailing, 40)
            }
        }
        .background(RoundedRectangle(cornerRadius: theme.rowRadius).fill(menuOpen ? theme.pressed : (hovering ? theme.hover : .clear)))
        .overlay(RoundedRectangle(cornerRadius: theme.rowRadius).stroke(theme.focus, lineWidth: focused && !menuOpen ? 2 : 0))
        .contentShape(Rectangle())
        .padding(.horizontal, 6)
        .onHover { store.hover($0 ? row.id : (store.hoveredRow == row.id ? nil : store.hoveredRow)) }
        .onTapGesture { store.click(row) }
        .modifier(DragOutModifier(store: store, row: row))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityIdentifier("row-\(row.id)")
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            // The same items the row menu offers, so VoiceOver reaches every one of them.
            ForEach(RowAccessibility.actions(for: row), id: \.self) { action in
                Button(action.title) { store.choose(action, for: row) }
            }
            Button("More actions") { store.openMenu(row.id) }
        }
    }
}

/// The footer status line: "All links answer", "N need a look", or the toast and the Undo
/// that replace them.
struct FooterBar: View {
    @ObservedObject var store: PopoverStore
    let footer: FooterModel
    @Environment(\.colorScheme) private var scheme
    @FocusState private var undoFocused: Bool
    private var theme: Theme { Theme(scheme) }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(theme.separator).frame(height: 1)
            HStack(spacing: 6) {
                if let hint = store.dragOutHint {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 12)).foregroundColor(theme.secondary).accessibilityHidden(true)
                        Text(hint).font(theme.metaFont).foregroundColor(theme.label).lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("footer-drag-hint")
                    Spacer(minLength: 8)
                } else if let toast = store.state.footer {
                    status(toast)
                    Spacer(minLength: 8)
                    if store.undoVisible { undoButton }
                } else if let working = store.workingLine {
                    HStack(spacing: 6) {
                        SBWorkingDot(theme: theme)
                        Text(working).font(theme.metaFont).foregroundColor(theme.label)
                    }
                    .padding(.vertical, 4).padding(.horizontal, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("footer-working")
                    .accessibilityAddTraits(.updatesFrequently)
                    Spacer()
                } else {
                    baseline
                    Spacer()
                }
            }
            .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 6)
            .frame(minHeight: 36)
        }
    }

    private func status(_ footer: Footer) -> some View {
        let failed = footer.kind == .failure
        let line = failed ? FailureLine.split(footer.text) : (sentence: footer.text, next: nil as String?)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: failed ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.system(size: 12)).foregroundColor(failed ? theme.errorInk : theme.secondary)
                    .accessibilityHidden(true)
                Text(line.sentence).font(theme.metaFont).foregroundColor(failed ? theme.errorInk : theme.label)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("footer-status")
            .accessibilityAddTraits(.updatesFrequently)
            if let next = line.next {
                HStack(spacing: 6) {
                    Text(next).font(theme.monoFont).foregroundColor(theme.label).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(theme.hover))
                        .accessibilityIdentifier("footer-next")
                    PanelButton(theme: theme, title: "Copy", id: "footer-next-copy") { store.copyCommand(next) }
                }
                .padding(.leading, 18)
            }
        }
    }

    private var undoButton: some View {
        PanelButton(theme: theme, title: "Undo", id: "undo-button") { store.undo() }
            .focused($undoFocused)
            .onChange(of: undoFocused) { store.holdUndo($0) }
    }

    @ViewBuilder
    private var baseline: some View {
        switch footer {
        case .allAnswer:
            HStack(spacing: 6) {
                Circle().fill(theme.ok).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(footer.text).font(theme.metaFont).foregroundColor(theme.secondary)
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("footer-ok")
        case .needLook:
            Button(action: store.showIssues) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 12))
                    Text(footer.text).font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(theme.attentionInk)
                .padding(.vertical, 4).padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("footer-issues")
            .accessibilityLabel(footer.text)
        }
    }
}

/// A row that may drag out carries its link as a URL and as text; one that may not has no drag at all.
struct DragOutModifier: ViewModifier {
    let store: PopoverStore
    let row: RowModel

    func body(content: Content) -> some View {
        if row.canDrag {
            content.onDrag { store.beginDragOut(row) }
        } else {
            content
        }
    }
}

/// The placeholder row of a file being published: its step and a progress bar.
struct UploadRowView: View {
    let theme: Theme
    let upload: UploadRow

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(theme.hover).frame(width: 28, height: 28)
                .overlay(Image(systemName: "arrow.up.doc").font(.system(size: 13)).foregroundColor(theme.secondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(upload.title).font(theme.bodyFont).foregroundColor(theme.label).lineLimit(1).truncationMode(.middle)
                Text(upload.meta).font(theme.metaFont).foregroundColor(theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            ZStack(alignment: .leading) {
                Capsule().fill(theme.hover)
                GeometryReader { proxy in
                    Capsule().fill(theme.info).frame(width: proxy.size.width * (upload.fraction ?? 0))
                }
            }
            .frame(width: 44, height: 4)
            .padding(.trailing, 8)
            .accessibilityHidden(true)
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 4)
        .frame(minHeight: theme.minRowHeight)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Publishing \(upload.title), \(upload.meta)")
        .accessibilityIdentifier("upload-\((upload.title))")
    }
}

/// A small steady ring beside "Working:": motion is never the only sign, and Reduce Motion needs none.
struct SBWorkingDot: View {
    let theme: Theme
    var body: some View {
        Circle().stroke(theme.info, lineWidth: 1.5).frame(width: 9, height: 9).accessibilityHidden(true)
    }
}
