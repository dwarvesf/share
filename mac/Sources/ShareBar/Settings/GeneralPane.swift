import ShareBarCore
import SwiftUI

/// Settings > General (interactions doc 7): Share Bar preferences, plus the two CLI defaults
/// (`ttl` and `storage_default`) written through `share config`.
struct GeneralPane: View {
    @ObservedObject var store: SettingsStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = SettingsTheme(scheme)
        VStack(alignment: .leading, spacing: 12) {
            FormRow(label: "Startup") {
                check("Open Share Bar at login", isOn: store.openAtLogin, id: "g-login", action: store.setOpenAtLogin)
            }
            FormRow(label: "Menu shows") {
                SBPopup(options: [(LinkScope.mine, "My links"), (LinkScope.team, "Team links")],
                        selection: Binding(get: { store.menuShows }, set: store.setMenuShows), id: "g-scope", label: "Menu shows")
                SmallText("You can switch in the menu at any time.")
            }
            FormRow(label: "Recent links") {
                SBPopup(options: PopoverPrefs.recentChoices.map { ($0, "\($0)") },
                        selection: Binding(get: { store.recentCount }, set: store.setRecent), id: "g-count", label: "Recent links")
            }
            FormRule()
            FormRow(label: "New links expire") {
                SBPopup(options: ExpiryChoice.allCases.map { ($0, $0.label) },
                        selection: Binding(get: { store.ttl ?? .sevenDays }, set: store.setExpiry), id: "g-exp", label: "New links expire")
                SmallText("Saved as ttl= in the share config, so the command line uses it too.")
            }
            if store.offersStorage {
                FormRow(label: "Store new links") {
                    ForEach(StorageChoice.allCases, id: \.self) { choice in
                        radio(choice.label, on: store.storage == choice, id: "g-st-\(choice.rawValue)") { store.setStorage(choice) }
                    }
                    SmallText("Cloud links answer while this Mac sleeps. Only on tenants with cloud storage.")
                }
            }
            FormRow(label: "After sharing") {
                check("Copy the link", isOn: store.copyAfter, id: "g-copy", action: store.setCopyAfter)
                check("Show a notification", isOn: store.notifyAfter, id: "g-notify", action: store.setNotifyAfter)
            }
            FormRule()
            FormRow(label: "Notify me when") {
                check("A machine serving my links goes offline", isOn: store.notifyOffline, id: "g-n1", action: store.setNotifyOffline)
                check("A link is about to expire", isOn: store.notifyExpiry, id: "g-n2", action: store.setNotifyExpiry)
                if SettingsTabs.showsMembers(store.profiles) {
                    check("A member needs a look", isOn: store.notifyMember, id: "g-n3", action: store.setNotifyMember)
                }
            }
            FormRow(label: "Shortcut") {
                Text("⌃⌥S").font(t.monoFont).foregroundColor(t.label)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.field))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.border, lineWidth: 1))
                    .accessibilityIdentifier("g-shortcut")
                SmallText("Opens the menu from anywhere.")
            }
        }
        .frame(width: 506, alignment: .topLeading)
        .padding(.top, 22).padding(.bottom, 22)
        .frame(maxWidth: .infinity, minHeight: 360, alignment: .top)
    }

    private func check(_ title: String, isOn: Bool, id: String, action: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: action)) {
            Text(title).font(SettingsTheme(scheme).bodyFont).foregroundColor(SettingsTheme(scheme).label)
        }
        .toggleStyle(.checkbox)
        .tint(SettingsTheme(scheme).info)
        .accessibilityIdentifier(id)
    }

    private func radio(_ title: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        let t = SettingsTheme(scheme)
        return Button(action: action) {
            HStack(spacing: 7) {
                ZStack {
                    Circle().fill(on ? t.info : t.field).frame(width: 14, height: 14)
                    Circle().stroke(on ? t.info : t.border, lineWidth: 1).frame(width: 14, height: 14)
                    if on { Circle().fill(.white).frame(width: 5, height: 5) }
                }
                Text(title).font(t.bodyFont).foregroundColor(t.label)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
