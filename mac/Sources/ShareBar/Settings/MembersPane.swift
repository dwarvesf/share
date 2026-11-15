import ShareBarCore
import SwiftUI

/// Settings > Members (SPEC-009 TASK-4b19): filters with counts, a search, Invite…, and a list
/// whose row menu offers exactly the verbs `member ls --json` reports in `can[]`.
struct MembersPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var members: MembersStore
    @Environment(\.colorScheme) private var scheme
    @State private var moreFrames: [String: CGRect] = [:]
    @State private var menuActive: String?

    init(store: SettingsStore) {
        self.store = store
        members = store.members
    }

    private var profile: ProfileEntry? { store.membersProfile }

    var body: some View {
        let t = SettingsTheme(scheme)
        let model = members.model(shares: profile?.state?.shares ?? [])
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 10) {
                topBar(model, t)
                list(model, t)
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 18)
            if let id = members.menuMember, let record = members.record(id) {
                menu(for: record, t)
            }
        }
        .coordinateSpace(name: "members")
        .frame(width: SettingsRootView.width, alignment: .topLeading)
        .frame(minHeight: 440, alignment: .top)
        .onPreferenceChange(MoreFramesKey.self) { moreFrames = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Members")
        .accessibilityIdentifier("members-pane")
    }

    // MARK: top bar

    private func topBar(_ model: MembersModel, _ t: SettingsTheme) -> some View {
        HStack(spacing: 8) {
            filterControl(model, t)
            Spacer(minLength: 0)
            searchField(t)
            Button("Invite…") {
                if let name = profile?.name { store.presentInvite(profile: name) }
            }
            .sbButton(.primary)
            .accessibilityIdentifier("m-new")
        }
    }

    private func filterControl(_ model: MembersModel, _ t: SettingsTheme) -> some View {
        HStack(spacing: 2) {
            ForEach(MemberFilter.allCases, id: \.self) { filter in
                let on = members.filter == filter
                Button { members.filter = filter } label: {
                    Text("\(filter.title) \(model.counts[filter] ?? 0)")
                        .font(.system(size: 11, weight: .medium)).foregroundColor(t.label)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(on ? t.field : .clear)
                            .shadow(color: .black.opacity(on ? 0.14 : 0), radius: 1, y: 1))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? t.separator : .clear, lineWidth: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mv-\(filter.rawValue)")
                .accessibilityLabel("\(filter.title), \(model.counts[filter] ?? 0)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(t.hover))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show")
    }

    private func searchField(_ t: SettingsTheme) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(t.tertiary).accessibilityHidden(true)
            ZStack(alignment: .leading) {
                if members.query.isEmpty {
                    Text("Search").font(t.bodyFont).foregroundColor(t.tertiary).allowsHitTesting(false).accessibilityHidden(true)
                }
                TextField("", text: Binding(get: { members.query }, set: { members.query = $0 }))
                    .textFieldStyle(.plain).font(t.bodyFont).foregroundColor(t.label)
                    .accessibilityLabel("Search members")
                    .accessibilityIdentifier("mf")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(width: 160)
        .background(RoundedRectangle(cornerRadius: 6).fill(t.field))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.softBorder, lineWidth: 1))
    }

    // MARK: list

    @ViewBuilder
    private func list(_ model: MembersModel, _ t: SettingsTheme) -> some View {
        VStack(spacing: 0) {
            if let failure = members.failure, members.list == nil {
                VStack(spacing: 0) {
                    notice(failure, symbol: "exclamationmark.triangle", ink: t.errorInk, t, id: "members-failure")
                    Button("Try again") { store.requestMembers() }.sbButton().padding(.bottom, 20)
                        .accessibilityIdentifier("members-retry")
                }
            } else if members.list == nil {
                notice("Reading the members…", symbol: "ellipsis.circle", ink: t.secondary, t, id: "members-loading")
            } else if let empty = model.emptyText {
                notice(empty, symbol: nil, ink: t.secondary, t, id: "members-empty")
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                            MemberRowView(row: row, open: members.menuMember == row.id, highlighted: members.highlighted == row.id) {
                                members.toggleMenu(row.id)
                            }
                            if index < model.rows.count - 1 { Rectangle().fill(t.separator).frame(height: 1) }
                        }
                    }
                }
                .frame(maxHeight: 330)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(t.field))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.separator, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Members list")
    }

    private func notice(_ text: String, symbol: String?, ink: Color, _ t: SettingsTheme, id: String) -> some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).foregroundColor(ink).accessibilityHidden(true) }
            Text(text).font(t.bodyFont).foregroundColor(symbol == nil ? t.secondary : t.label).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28).padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    // MARK: row menu

    private func menu(for record: MemberRecord, _ t: SettingsTheme) -> some View {
        let theme = Theme(scheme)
        let verbs = MembersModel.menu(for: record)
        let safe = verbs.filter { !$0.isDestructive }
        let danger = verbs.filter(\.isDestructive)
        let width: CGFloat = 200
        let height = CGFloat(verbs.count) * 28 + 8 + (safe.isEmpty || danger.isEmpty ? 0 : 9)
        let anchor = moreFrames[record.memberID] ?? CGRect(x: SettingsRootView.width - 60, y: 120, width: 26, height: 26)
        let x = max(8, min(anchor.maxX - width, SettingsRootView.width - width - 8))
        let y = anchor.maxY + 4
        let name = MembersModel.display(record.name)
        return ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).onTapGesture { members.closeMenu() }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(safe, id: \.self) { verb in
                    MenuRow(theme: theme, id: "mm-\(verb.rawValue)", title: verb.title(status: record.status), trailing: nil, checked: false, indent: false, active: $menuActive) {
                        store.memberVerb(verb, member: record)
                    }
                }
                if !safe.isEmpty, !danger.isEmpty { Divider().padding(.vertical, 4) }
                ForEach(danger, id: \.self) { verb in
                    MenuRow(theme: theme, id: "mm-\(verb.rawValue)", title: verb == .rm ? "Remove \(name)…" : verb.title(status: record.status),
                            trailing: nil, checked: false, indent: false, destructive: true, active: $menuActive) {
                        store.memberVerb(verb, member: record)
                    }
                }
                if verbs.isEmpty {
                    Text("Nothing to do for \(name) right now.").font(t.metaFont).foregroundColor(t.secondary).padding(8)
                }
            }
            .padding(4)
            .frame(width: width)
            .menuSurface(theme)
            .offset(x: x, y: y)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Actions for \(name)")
        }
        .onAppear { menuActive = (safe.first ?? danger.first).map { "mm-\($0.rawValue)" } }
    }
}

private struct MemberRowView: View {
    let row: MemberRowModel
    let open: Bool
    let highlighted: Bool
    let toggle: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let t = SettingsTheme(scheme)
        HStack(spacing: 10) {
            Text(row.initials).font(.system(size: 10.5, weight: .semibold)).foregroundColor(t.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(t.label.opacity(0.08)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.name).font(.system(size: 13, weight: .medium)).foregroundColor(t.label).lineLimit(1)
                Text(row.subLine).font(t.metaFont).foregroundColor(t.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            statusCell(t).frame(width: 92, alignment: .leading)
            Text(row.linkText).font(t.metaFont).foregroundColor(t.secondary).monospacedDigit()
                .frame(width: 52, alignment: .trailing)
            Button(action: toggle) {
                Image(systemName: "ellipsis").font(.system(size: 13)).foregroundColor(hovering || open ? t.secondary : t.secondary.opacity(0.0))
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mk-\(row.name.lowercased())")
            .accessibilityLabel("Actions for \(row.name)")
            .background(GeometryReader { proxy in
                Color.clear.preference(key: MoreFramesKey.self, value: [row.id: proxy.frame(in: .named("members"))])
            })
        }
        .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 7)
        .background(open || hovering ? t.hover : (highlighted ? t.selection : .clear))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityIdentifier("mr-\(row.name.lowercased())")
        .accessibilityAction(named: "Actions") { toggle() }
    }

    @ViewBuilder
    private func statusCell(_ t: SettingsTheme) -> some View {
        if let chip = row.chip {
            Chip(chip: chip)
        } else if let presence = row.presence {
            HStack(spacing: 5) {
                if row.isOnline || presence == "Online" {
                    Circle().fill(t.ok).frame(width: 7, height: 7)
                } else {
                    Circle().stroke(t.tertiary, lineWidth: 1.5).frame(width: 5, height: 5).padding(1)
                }
                Text(presence).font(t.metaFont).foregroundColor(t.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// A status chip: the state color at 14% (24% in dark) behind its ink (`chip-bg`, `chip-fg`).
private struct Chip: View {
    let chip: MemberChip
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = SettingsTheme(scheme)
        let palette = Tokens.palette(scheme == .dark ? .dark : .light)
        let base: RGB
        let ink: Color
        switch chip.tone {
        case .info: base = palette.semantic.info; ink = t.infoInk
        case .quiet: base = palette.semantic.quiet; ink = t.color(palette.semantic.quietInk)
        case .attention: base = palette.semantic.attention; ink = t.attentionInk
        }
        return Text(chip.text)
            .font(.system(size: 11, weight: .medium)).foregroundColor(ink)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(t.color(base, opacity: palette.semantic.chipOpacity)))
            .accessibilityLabel(chip.text)
    }
}
