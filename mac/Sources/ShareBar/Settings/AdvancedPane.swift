import ShareBarCore
import SwiftUI

/// Settings > Advanced: the CLI path, the admin key and the minter key sources with Test,
/// the serve log, the classic menu for one release, and Copy share state as JSON.
struct AdvancedPane: View {
    @ObservedObject var store: SettingsStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = SettingsTheme(scheme)
        VStack(alignment: .leading, spacing: 12) {
            FormRow(label: "share CLI") {
                Text(store.cliPath).font(t.monoFont).foregroundColor(t.label)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.field))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.softBorder, lineWidth: 1))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("a-cli")
                SmallText("\(store.cliVersion.map { "Version \($0). " } ?? "")Every action runs this command.")
            }
            if store.keyTargets.count > 1 {
                FormRow(label: "Keys for") {
                    SBPopup(options: store.keyTargets.map { ($0.name, $0.state?.host ?? $0.name) },
                            selection: Binding(get: { store.configTarget?.name ?? "" }, set: { store.keyProfileOverride = $0; store.loadKeysAgain() }),
                            id: "a-tenant", label: "Keys for")
                }
            }
            KeyRows(store: store, kind: .admin)
            KeyRows(store: store, kind: .minter)
            FormRow(label: "Logs") {
                Button("Show serve log in Finder") { store.showServeLog() }.sbButton().accessibilityIdentifier("a-logs")
            }
            FormRow(label: "Menu style") {
                Toggle(isOn: Binding(get: { store.legacyMenu }, set: store.setLegacyMenu)) {
                    Text("Use the classic menu (one release only)").font(t.bodyFont).foregroundColor(t.label)
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("a-legacy")
            }
            FormRow(label: "Diagnostics") {
                Button("Copy share state as JSON") { store.copyShareState() }.sbButton().accessibilityIdentifier("a-copy")
                SmallText("For bug reports and agents.")
            }
        }
        .frame(width: 506, alignment: .topLeading)
        .padding(.top, 22).padding(.bottom, 22)
        .frame(maxWidth: .infinity, minHeight: 360, alignment: .top)
    }
}

/// One key's rows: the source pop-up, its detail, Test, and the note under them.
private struct KeyRows: View {
    @ObservedObject var store: SettingsStore
    let kind: KeyKind
    @Environment(\.colorScheme) private var scheme

    private var prefix: String { kind == .admin ? "a-admin" : "a-minter" }

    var body: some View {
        let t = SettingsTheme(scheme)
        let panel = store.panel(kind)
        let choice = store.sourceChoice(kind)
        FormRow(label: kind.title) {
            SBPopup(
                options: [(SettingsStore.SourceChoice.onePassword, "From 1Password"), (.command, "From a command"), (.ask, "Ask me each time")],
                selection: Binding(get: { choice }, set: { store.chooseSourceKind(kind, $0) }),
                id: "\(prefix)-src", label: kind.title
            )
            if choice == .ask {
                SmallText(kind.askNote)
            } else {
                if choice == .onePassword {
                    HStack(spacing: 8) {
                        pickedRow(panel, t)
                        Button("Choose…") { store.openPicker(kind) }.sbButton().accessibilityIdentifier("\(prefix)-choose")
                    }
                } else {
                    SBField(placeholder: "Command that prints the token", text: Binding(get: { panel.commandText }, set: { store.setCommandText(kind, $0) }),
                            mono: true, id: "\(prefix)-cmd", onSubmit: { store.commitCommand(kind) })
                }
                HStack(spacing: 8) {
                    Button { store.runTest(kind) } label: {
                        HStack(spacing: 5) {
                            if panel.test == .running { SBSpinner(size: 10) }
                            Text(panel.test == .running ? "Testing" : "Test")
                        }
                    }
                    .sbButton()
                    .disabled(panel.test == .running)
                    .accessibilityIdentifier("\(prefix)-test")
                    testLine(panel.test, t)
                }
                SmallText(kind.usedFor)
            }
            if choice == .ask, case .idle = panel.test {} else if choice == .ask {
                testLine(panel.test, t)
            }
        }
    }

    private func pickedRow(_ panel: KeyPanel, _ t: SettingsTheme) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "key").font(.system(size: 12)).foregroundColor(t.secondary)
            if case .onePassword(let item?) = panel.source {
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.itemName).font(.system(size: 13, weight: .medium)).foregroundColor(t.label).lineLimit(1).truncationMode(.tail)
                    Text(item.subtitle).font(t.metaFont).foregroundColor(t.secondary)
                }
            } else {
                Text("No item chosen").font(t.bodyFont).foregroundColor(t.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(t.field))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.softBorder, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(prefix)-picked")
    }

    @ViewBuilder
    private func testLine(_ state: KeyTestState, _ t: SettingsTheme) -> some View {
        switch state {
        case .idle, .running:
            EmptyView()
        case .passed(let result):
            HStack(spacing: 5) {
                Image(systemName: result.allOK ? "checkmark" : "exclamationmark.triangle").font(.system(size: 11, weight: .semibold))
                    .foregroundColor(result.allOK ? t.ok : t.attentionInk)
                Text(result.summary).font(t.metaFont).foregroundColor(t.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(prefix)-result")
        case .failed(let sentence):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundColor(t.errorInk)
                Text(sentence).font(t.metaFont).foregroundColor(t.errorInk).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(prefix)-result")
        }
    }
}
