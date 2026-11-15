import AppKit
import ShareBarCore
import SwiftUI

/// The scrim and the card of whichever sheet is open (D2). The card hangs from the top, like
/// the prototype's `.sheet`.
struct SheetOverlay: View {
    @ObservedObject var store: SettingsStore
    let content: SheetContent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = SettingsTheme(scheme)
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture {}
                .accessibilityHidden(true)
            card
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 14)
                .frame(width: 440)
                .background(EdgeRounded(edge: .bottom, radius: 10).fill(t.surface)
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 8))
                .overlay(EdgeRounded(edge: .bottom, radius: 10).stroke(Color.black.opacity(0.2), lineWidth: 0.5))
                .padding(.top, 44)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
                .accessibilityIdentifier("sheet")
        }
    }

    @ViewBuilder
    private var card: some View {
        switch content {
        case .add: AddSheetView(store: store)
        case .progress: ProgressSheetView(store: store)
        case .confirm(let sheet, let action): ConfirmSheetView(store: store, sheet: sheet, action: action)
        case .refusal(let sheet): RefusalSheetView(store: store, sheet: sheet)
        case .code(let sheet): CodeSheetView(store: store, sheet: sheet)
        case .invite(let profile): InviteSheetView(store: store, profile: profile)
        case .askKey(let request): AskKeySheetView(store: store, request: request)
        case .picker(let kind): PickerSheetView(store: store, kind: kind)
        }
    }
}

private struct SheetTitle: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text(text).font(SettingsTheme(scheme).titleFont).foregroundColor(SettingsTheme(scheme).label)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct Buttons<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 6) { Spacer(); content }.padding(.top, 8)
    }
}

// MARK: add

struct AddSheetView: View {
    @ObservedObject var store: SettingsStore
    @Environment(\.colorScheme) private var scheme

    private var form: AddForm {
        get { store.addForm }
        nonmutating set { store.addForm = newValue }
    }
    private var formBinding: Binding<AddForm> { Binding(get: { store.addForm }, set: { store.addForm = $0 }) }

    private var parsed: (host: String, code: String) { JoinInput.parse(codeField: form.code, hostField: form.host) }

    private var canSubmit: Bool {
        switch form.path {
        case .join: return FlowArgv.join(host: parsed.host, code: parsed.code) != nil
        case .setup: return HostnameValidation.isValid(form.host.trimmingCharacters(in: .whitespaces))
        }
    }

    var body: some View {
        let t = SettingsTheme(scheme)
        VStack(alignment: .leading, spacing: 12) {
            SheetTitle(text: "Add a tenant")
            SBSegmented(options: [(AddForm.Path.join, "Join a team"), (.setup, "Set up a hostname")], selection: formBinding.path, idPrefix: "sp")
            if form.path == .join {
                field("Hostname", placeholder: "s.example.com", text: formBinding.host, id: "sh-host-join", mono: true)
                field("Invite code", placeholder: "SHR-7Q4K-M2XD-9PLA-3VTB", text: formBinding.code, id: "sh-code", mono: true)
                SmallText("Your admin sends this code. It works once. Joining takes about a minute and sets up this Mac to serve your links.")
            } else {
                field("Hostname", placeholder: "s.example.com", text: formBinding.host, id: "sh-host", mono: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cloudflare admin key").font(t.metaFont).foregroundColor(t.secondary)
                    SBPopup(options: [(true, "Ask me now (not saved)"), (false, "Run the admin key command from Advanced")],
                            selection: formBinding.askKey, id: "sh-tok")
                }
                Toggle(isOn: formBinding.alsoCloud) { Text("Also turn on cloud storage").font(t.bodyFont).foregroundColor(t.label) }
                    .toggleStyle(.checkbox).accessibilityIdentifier("sh-r2")
                SmallText("Creates a tunnel and a DNS record in your Cloudflare account. Links are served from this Mac.")
            }
            Buttons {
                Button("Cancel") { store.dismissSheet() }.sbButton().keyboardShortcut(.cancelAction).accessibilityIdentifier("sh-cancel")
                Button(form.path == .join ? "Join" : "Set up") { store.submitAdd() }
                    .sbButton(.primary).disabled(!canSubmit).keyboardShortcut(.defaultAction).accessibilityIdentifier("sh-go")
            }
        }
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>, id: String, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(SettingsTheme(scheme).metaFont).foregroundColor(SettingsTheme(scheme).secondary)
            SBField(placeholder: placeholder, text: text, mono: mono, id: id)
        }
    }
}

// MARK: progress

struct ProgressSheetView: View {
    @ObservedObject var store: SettingsStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = SettingsTheme(scheme)
        if let run = store.flow {
            VStack(alignment: .leading, spacing: 12) {
                SheetTitle(text: run.title)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<run.steps.count, id: \.self) { index in
                        StepLine(title: run.title(of: index), mark: run.mark(of: index), halted: !run.isActive)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("progress-steps")
                statusLine(run, t)
                Buttons {
                    if run.isActive {
                        Button("Stop") { store.stopFlow() }.sbButton()
                            .disabled({ if case .stopping = run.phase { return true } else { return false } }())
                            .accessibilityIdentifier("sh-stop")
                    } else {
                        Button("Close") { store.closeProgress() }.sbButton().keyboardShortcut(.defaultAction).accessibilityIdentifier("sh-close")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statusLine(_ run: FlowRun, _ t: SettingsTheme) -> some View {
        switch run.phase {
        case .running, .stopping:
            Text(run.statusLine).font(t.metaFont).foregroundColor(t.secondary).accessibilityIdentifier("progress-status")
        case .stopped(let at):
            Text("Stopped at step \(at). Resume continues from there.").font(t.metaFont).foregroundColor(t.secondary)
                .accessibilityIdentifier("progress-status")
        case .done:
            Text("Done.").font(t.metaFont).foregroundColor(t.secondary)
        case .failed(let sentence, let next):
            VStack(alignment: .leading, spacing: 2) {
                Text(sentence).font(t.bodyFont).foregroundColor(t.errorInk).fixedSize(horizontal: false, vertical: true)
                if let next { Text(next).font(t.monoFont).foregroundColor(t.secondary).textSelection(.enabled) }
            }
            .accessibilityIdentifier("progress-status")
        }
    }
}

private struct StepLine: View {
    let title: String
    let mark: FlowRun.StepMark
    let halted: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = SettingsTheme(scheme)
        HStack(spacing: 8) {
            ZStack {
                switch mark {
                case .done: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(t.ok)
                case .now:
                    if halted { Circle().fill(t.attention).frame(width: 7, height: 7) } else { SBSpinner(size: 12) }
                case .pending: Circle().stroke(t.tertiary, lineWidth: 1.5).frame(width: 7, height: 7)
                }
            }
            .frame(width: 14, height: 14)
            Text(title)
                .font(.system(size: 13, weight: mark == .now ? .semibold : .regular))
                .foregroundColor(mark == .now ? t.label : (mark == .done ? t.secondary : t.tertiary))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(mark == .done ? "done" : mark == .now ? "now" : "pending")")
    }
}

// MARK: confirm and refusal

struct ConfirmSheetView: View {
    @ObservedObject var store: SettingsStore
    let sheet: ImpactSheet
    let action: ConfirmAction
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = SettingsTheme(scheme)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SheetTitle(text: sheet.title)
                if let body = sheet.body { SmallText(body) }
            }
            if !sheet.lines.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(sheet.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: line.kind == .stops ? "xmark" : "checkmark").font(.system(size: 11, weight: .bold))
                                .foregroundColor(line.kind == .stops ? t.errorInk : t.ok).frame(width: 14)
                            Text(line.text).font(t.bodyFont).foregroundColor(t.label).fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(t.field))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.separator, lineWidth: 1))
                .accessibilityIdentifier("impact-lines")
            }
            if let choice = sheet.choice {
                VStack(alignment: .leading, spacing: 4) {
                    Text(choice.label).font(t.metaFont).foregroundColor(t.secondary)
                    SBPopup(options: choice.options.enumerated().map { ($0.offset, $0.element) },
                            selection: Binding(get: { store.impactChoice }, set: { store.impactChoice = $0 }), id: "sh-cl")
                }
            }
            Buttons {
                Button("Cancel") { store.dismissSheet() }.sbButton().keyboardShortcut(.cancelAction).accessibilityIdentifier("sh-cancel")
                Button(sheet.actionTitle) { store.confirm(action) }
                    .sbButton(sheet.destructive ? .destructiveFill : .primary)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("sh-ok")
            }
        }
    }
}

struct RefusalSheetView: View {
    @ObservedObject var store: SettingsStore
    let sheet: RefusalSheet
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetTitle(text: sheet.title)
            Text(sheet.sentence).font(SettingsTheme(scheme).bodyFont).foregroundColor(SettingsTheme(scheme).label)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("refusal-sentence")
            if case .copyCommand(let command) = sheet.action {
                Text(command).font(SettingsTheme(scheme).monoFont).foregroundColor(SettingsTheme(scheme).secondary).textSelection(.enabled)
            }
            Buttons {
                Button("Close") { store.dismissSheet() }.sbButton().keyboardShortcut(.cancelAction).accessibilityIdentifier("sh-cancel")
                if let next = sheet.next {
                    Button(next) { perform() }.sbButton(.primary).keyboardShortcut(.defaultAction).accessibilityIdentifier("sh-next")
                }
            }
        }
    }

    private func perform() {
        switch sheet.action {
        case .openMembers: store.openMembers()
        case .copyCommand(let command):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            store.dismissSheet()
            store.announce("Copied the command.")
        case .none: store.dismissSheet()
        }
    }
}

// MARK: code and invite

struct CodeSheetView: View {
    @ObservedObject var store: SettingsStore
    let sheet: CodeSheet
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = SettingsTheme(scheme)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SheetTitle(text: sheet.title)
                SmallText(sheet.body)
            }
            Text(sheet.code).font(.system(size: 15, design: .monospaced)).tracking(0.6).foregroundColor(t.label)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity).padding(10)
                .background(RoundedRectangle(cornerRadius: 7).fill(t.field))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(t.separator, lineWidth: 1))
                .accessibilityIdentifier("code-value")
            SmallText(sheet.note)
            Buttons {
                Button("Copy code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sheet.code, forType: .string)
                    store.announce("Invite code copied.")
                }
                .sbButton().accessibilityIdentifier("sh-copy")
                Button("Done") { store.dismissSheet() }.sbButton(.primary).keyboardShortcut(.defaultAction).accessibilityIdentifier("sh-done")
            }
        }
    }
}

struct InviteSheetView: View {
    @ObservedObject var store: SettingsStore
    let profile: String
    @Environment(\.colorScheme) private var scheme

    private var form: InviteForm { store.inviteForm }
    private var formBinding: Binding<InviteForm> { Binding(get: { store.inviteForm }, set: { store.inviteForm = $0 }) }

    var body: some View {
        let t = SettingsTheme(scheme)
        let host = store.entry(profile)?.state?.host ?? profile
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                SheetTitle(text: "Invite to \(host)")
                SmallText("You get a one-time code to send them. Nothing is sent from here.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(t.metaFont).foregroundColor(t.secondary)
                SBField(placeholder: "As the team will see it", text: formBinding.name, id: "sh-name")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Where their links live").font(t.metaFont).foregroundColor(t.secondary)
                ForEach(InviteForm.Mode.allCases, id: \.self) { mode in
                    modeOption(mode, t)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Code expires after").font(t.metaFont).foregroundColor(t.secondary)
                SBSegmented(options: InviteForm.ttlChoices.map { ($0, $0 == 1 ? "1 day" : "\($0) days") },
                            selection: formBinding.ttlDays, small: true, idPrefix: "it")
            }
            Buttons {
                Button("Cancel") { store.dismissSheet() }.sbButton().keyboardShortcut(.cancelAction).accessibilityIdentifier("sh-cancel")
                Button("Create code") { store.submitInvite(profile: profile) }
                    .sbButton(.primary).disabled(!form.isValid).keyboardShortcut(.defaultAction).accessibilityIdentifier("sh-go")
            }
        }
    }

    private func modeOption(_ mode: InviteForm.Mode, _ t: SettingsTheme) -> some View {
        let on = form.mode == mode
        return Button { store.inviteForm.mode = mode } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().fill(on ? t.info : t.field).frame(width: 14, height: 14)
                    Circle().stroke(on ? t.info : t.border, lineWidth: 1).frame(width: 14, height: 14)
                    if on { Circle().fill(.white).frame(width: 5, height: 5) }
                }
                .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.title).font(.system(size: 13, weight: .semibold)).foregroundColor(t.label)
                    Text(mode.detail).font(t.metaFont).foregroundColor(t.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(t.field))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? t.info : t.softBorder, lineWidth: on ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("im-\(mode.rawValue)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: ask for a key

struct AskKeySheetView: View {
    @ObservedObject var store: SettingsStore
    let request: AskKeyRequest
    @State private var key = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SheetTitle(text: request.kind == .admin ? "Cloudflare admin key" : "Cloudflare minter key")
                SmallText(request.purpose)
            }
            SBSecureField(placeholder: "Paste the token", text: $key, id: "ask-key", onSubmit: submit)
            SmallText("It goes to this one command and is dropped when the command ends. Nothing is saved.")
            Buttons {
                Button("Cancel") { key = ""; store.dismissSheet() }.sbButton().keyboardShortcut(.cancelAction).accessibilityIdentifier("sh-cancel")
                Button("Use once") { submit() }.sbButton(.primary).disabled(key.isEmpty).keyboardShortcut(.defaultAction).accessibilityIdentifier("sh-go")
            }
        }
    }

    private func submit() {
        guard !key.isEmpty else { return }
        let value = key
        key = ""
        request.onSubmit(value)
    }
}

// MARK: 1Password picker

struct PickerSheetView: View {
    @ObservedObject var store: SettingsStore
    let kind: KeyKind
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = SettingsTheme(scheme)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SheetTitle(text: "Choose a 1Password item")
                SmallText("Share Bar keeps the item's name and ids. The token itself is read only when an action needs it.")
            }
            Group {
                if let error = store.pickerError {
                    Text(error).font(t.bodyFont).foregroundColor(t.errorInk).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("picker-error")
                } else if let items = store.pickerItems {
                    if items.isEmpty {
                        Text("No items found.").font(t.bodyFont).foregroundColor(t.secondary)
                    } else {
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(items, id: \.itemID) { item in
                                    Button { store.pickItem(kind, item) } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "key").font(.system(size: 12)).foregroundColor(t.secondary)
                                            VStack(alignment: .leading, spacing: 0) {
                                                Text(item.itemName).font(.system(size: 13, weight: .medium)).foregroundColor(t.label)
                                                Text(item.subtitle).font(t.metaFont).foregroundColor(t.secondary)
                                            }
                                            Spacer()
                                        }
                                        .padding(.horizontal, 8).padding(.vertical, 5)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("pick-\(item.itemName)")
                                }
                            }
                        }
                        .frame(maxHeight: 200)
                    }
                } else {
                    HStack(spacing: 6) { SBSpinner(size: 10); Text("Reading your vaults…").font(t.bodyFont).foregroundColor(t.secondary) }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(t.field))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.separator, lineWidth: 1))
            Buttons {
                Button("Cancel") { store.dismissSheet() }.sbButton().keyboardShortcut(.cancelAction).accessibilityIdentifier("sh-cancel")
            }
        }
    }
}
