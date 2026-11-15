import ShareBarCore
import SwiftUI

/// The popover's root (SPEC-009 `### Layout & structure`): 340 pt wide, one of three bodies
/// (first run, needs a look, the link list), with the tenant menu and the row menu drawn
/// inside it as overlays so there is one window to capture and one tree to drive.
struct ShareBarView: View {
    @ObservedObject var store: PopoverStore
    @Environment(\.colorScheme) private var scheme
    @State private var moreFrames: [String: CGRect] = [:]
    /// The highlighted row-menu item: the first one on open, then whichever the pointer is over.
    @State private var menuActive: String?

    private var theme: Theme { Theme(scheme) }
    static let width: CGFloat = 340
    static let menuWidth: CGFloat = 208

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if store.isFirstRun {
                    FirstRunView(store: store)
                } else if store.showsIssues {
                    IssuesView(store: store)
                } else {
                    ListBody(store: store)
                }
            }
            if store.tenantMenuOpen { tenantMenu }
            if let id = store.menuRowID, let row = store.row(id) {
                GeometryReader { proxy in rowMenu(for: row, bottom: proxy.size.height) }
            }
        }
        .frame(width: Self.width, alignment: .topLeading)
        .frame(minHeight: menuMinHeight, alignment: .top)
        .background(theme.surface)
        .coordinateSpace(name: "pop")
        .onPreferenceChange(MoreFramesKey.self) { moreFrames = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Share Bar")
    }

    /// The popover grows to hold the row menu under its More button, as the design does, so
    /// the menu never has to flip up over the header and the search.
    private var menuMinHeight: CGFloat? {
        guard let id = store.menuRowID, let row = store.row(id) else { return nil }
        let anchor = moreFrames[id]?.maxY ?? 100
        return max(230, anchor + 4 + Self.menuHeight(for: row) + 8)
    }

    private static func menuHeight(for row: RowModel) -> CGFloat {
        let items = RowMenu.items(for: row)
        let danger = items.filter(\.isDestructive)
        return CGFloat(items.count) * 28 + 8 + (danger.isEmpty || danger.count == items.count ? 0 : 9)
    }

    // MARK: tenant menu

    private var tenantMenu: some View {
        let model = store.viewModel
        return ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).onTapGesture { store.tenantMenuOpen = false }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.header.tenants) { tenant in
                    MenuRow(theme: theme, id: "tenant-\(tenant.profile)", title: tenant.host, trailing: tenant.roleLabel, checked: tenant.isCurrent) {
                        store.selectTenant(tenant.profile)
                    }
                }
                Divider().padding(.vertical, 4)
                MenuRow(theme: theme, id: "manage-tenants", title: model.header.manageTitle, trailing: nil, checked: false) {
                    store.openSettings(.tenants)
                }
            }
            .padding(4)
            .frame(width: 236)
            .menuSurface(theme)
            .padding(.leading, 10)
            .padding(.top, 40)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tenants")
        }
    }

    // MARK: row menu

    private func rowMenu(for row: RowModel, bottom listBottom: CGFloat) -> some View {
        let items = RowMenu.items(for: row)
        let safe = items.filter { !$0.isDestructive }
        let danger = items.filter(\.isDestructive)
        let height = CGFloat(items.count) * 28 + 8 + (danger.isEmpty || safe.isEmpty ? 0 : 9)
        let anchor = moreFrames[row.id] ?? CGRect(x: Self.width - 40, y: 100, width: 26, height: 26)
        let x = max(8, min(anchor.maxX - Self.menuWidth, Self.width - Self.menuWidth - 8))
        let bottom = max(listBottom, height + 16)
        var y = anchor.maxY + 4
        if y + height > bottom - 8 { y = anchor.minY - height - 4 }
        y = max(8, min(y, bottom - height - 8))
        return ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).onTapGesture { store.closeMenu() }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(safe, id: \.self) { action in
                    MenuRow(theme: theme, id: "menu-\(action.rawValue)", title: action.title, trailing: nil, checked: false, indent: false, active: $menuActive) {
                        store.choose(action, for: row)
                    }
                }
                if !safe.isEmpty, !danger.isEmpty { Divider().padding(.vertical, 4) }
                ForEach(danger, id: \.self) { action in
                    MenuRow(theme: theme, id: "menu-\(action.rawValue)", title: action.title, trailing: nil, checked: false, indent: false, destructive: true, active: $menuActive) {
                        store.choose(action, for: row)
                    }
                }
            }
            .padding(4)
            .frame(width: Self.menuWidth)
            .menuSurface(theme)
            .offset(x: x, y: y)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Actions for \(row.title)")
        }
        .onAppear { menuActive = (safe.first ?? danger.first).map { "menu-\($0.rawValue)" } }
    }
}

struct MoreFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func menuSurface(_ theme: Theme) -> some View {
        background(
            RoundedRectangle(cornerRadius: 8).fill(.regularMaterial)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.separator, lineWidth: 0.5))
    }
}

/// One item of a menu overlay: hover fills it with the info hue and turns its text white, like a menu.
struct MenuRow: View {
    let theme: Theme
    let id: String
    let title: String
    let trailing: String?
    let checked: Bool
    var indent = true
    var destructive = false
    /// A menu that shares one highlight (the first item is lit on open); nil keeps a per-row hover.
    var active: Binding<String?>?
    let action: () -> Void
    @State private var hoverOnly = false
    private var hovering: Bool { active.map { $0.wrappedValue == id } ?? hoverOnly }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if indent {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).frame(width: 14).opacity(checked ? 1 : 0)
                        .accessibilityHidden(true)
                }
                Text(title).font(theme.bodyFont)
                Spacer(minLength: 8)
                if let trailing { Text(trailing).font(theme.metaFont).foregroundColor(hovering ? .white : theme.secondary) }
            }
            .foregroundColor(hovering ? .white : (destructive ? theme.errorInk : theme.label))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? theme.info : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if let active { if inside { active.wrappedValue = id } } else { hoverOnly = inside }
        }
        .accessibilityIdentifier(id)
        .accessibilityLabel(title)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

/// A 26 pt icon button of the header.
struct IconButton: View {
    let theme: Theme
    let symbol: String
    let id: String
    let label: String
    var visible = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(theme.secondary)
                .frame(width: theme.iconButton, height: theme.iconButton)
                .background(RoundedRectangle(cornerRadius: theme.buttonRadius).fill(hovering ? theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .opacity(visible ? 1 : 0)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// A small bordered button, for the needs-a-look actions and the first-run choices.
struct PanelButton: View {
    let theme: Theme
    let title: String
    let id: String
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.bodyFont)
                .foregroundColor(prominent ? .white : theme.label)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .frame(minWidth: prominent ? 0 : 0)
                .background(
                    RoundedRectangle(cornerRadius: theme.buttonRadius)
                        .fill(prominent ? theme.info : (hovering ? theme.pressed : theme.hover))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier(id)
        .accessibilityLabel(title)
    }
}
