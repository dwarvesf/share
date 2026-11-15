#if DEBUG
import AppKit
import ShareBarCore
import SwiftUI

/// The screenshot harness's in-app test hooks (owner decision 2026-11-15: no pointer or key
/// input on the live desktop). `-ShareBarShotsScreen "<step>,<step>,..."` runs the steps in
/// order through the store's own methods, the ones a click calls, then writes
/// `$SHARE_FAKE_DIR/shots-ready` so `Tests/fixtures/settings/run-shots.sh` can capture the
/// window. A release build never compiles this file.
///
/// Steps: `tab:<pane>`, `select:<profile>`, `add:<join|setup>`, `join-host=<h>`, `code=<c>`,
/// `host=<h>`, `r2=<on|off>`, `submit`, `stop`, `close`, `button:<action>`, `remove`, `ok`
/// (the confirm sheet's action), `cancel`, `choose:ttl=<v>`, `choose:storage=<v>`,
/// `source:<admin|minter>:<1p|cmd|ask>`, `pick:<kind>:<item name>`, `cmd:<kind>=<text>`,
/// `commit:<kind>`, `test:<kind>`, `askkey=<value>`, `invite:<profile>`, `name=<n>`,
/// `invite-mode=<machine|cloud>`, `invite-ttl=<n>`, `create-code`, `pause:<profile>:<member>`,
/// `remove-member:<profile>:<member>`, `wait:<seconds>`. Members tab: `keys` (both key sources as stored commands), `mload` (wait for the roster),
/// `mfilter:<all|needsLook|removed>`, `mquery=<text>`, `mmenu:<member>`, `mverb:<member>:<verb>`.
/// All links window (the capture then takes that window): `links`, `ltab:<all|live|needsLook|expired>`,
/// `lq=<text>`, `lselect:<id>+<id>`, `lbulkcopy`, `lbulkremove`.
@MainActor
enum ShotsHooks {
    /// Set by `links`: the capture then takes the All links window, not Settings.
    private static var captureAllLinks = false

    static func installIfRequested() {
        guard let script = UserDefaults.standard.string(forKey: "ShareBarShotsScreen"), !script.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Task { @MainActor in await run(script) }
        }
    }

    private static func run(_ script: String) async {
        let controller = SettingsWindowController.shared
        let store = controller.store
        store.openAtLoginProvider = { true }
        for raw in script.split(separator: ",").map(String.init) {
            await step(raw.trimmingCharacters(in: .whitespaces), store: store, controller: controller)
            try? await Task.sleep(nanoseconds: 450_000_000)
        }
        try? await Task.sleep(nanoseconds: 600_000_000)
        if let dir = ProcessInfo.processInfo.environment["SHARE_FAKE_DIR"] {
            let number = captureAllLinks ? AllLinksWindowController.shared.windowNumber : controller.windowNumber
            let info = "\(number)\n"
            try? info.write(toFile: dir + "/shots-ready", atomically: true, encoding: .utf8)
        }
    }

    private static func step(_ raw: String, store: SettingsStore, controller: SettingsWindowController) async {
        let cut = raw.firstIndex(where: { $0 == ":" || $0 == "=" })
        let name = cut.map { String(raw[..<$0]) } ?? raw
        let rest = cut.map { String(raw[raw.index(after: $0)...]) } ?? ""
        switch name {
        case "tab":
            controller.show(pane: SettingsPane(rawValue: rest) ?? .general)
            await store.refresh()
        case "select": store.select(rest)
        case "add": controller.showAdd(rest == "setup" ? .setup : .join)
        case "join-host", "host": store.addForm.host = rest
        case "code": store.addForm.code = rest
        case "r2": store.addForm.alsoCloud = rest == "on"
        case "submit": store.submitAdd()
        case "stop": store.stopFlow()
        case "close": store.closeProgress()
        case "button":
            if let action = TenantAction(rawValue: rest), let detail = store.selectedDetail { store.perform(action, on: detail) }
        case "remove": if let detail = store.selectedDetail { store.confirmRemoval(detail) }
        case "ok":
            if case .confirm(_, let action)? = store.sheet { store.confirm(action) }
        case "cancel": store.dismissSheet()
        case "choose":
            let (key, val) = split(rest, "=")
            if key == "ttl", let choice = ExpiryChoice(rawValue: val) { store.setExpiry(choice) }
            if key == "storage", let choice = StorageChoice(rawValue: val) { store.setStorage(choice) }
            if key == "scope" { store.setMenuShows(val == "team" ? .team : .mine) }
        case "source":
            let parts = rest.split(separator: ":").map(String.init)
            guard parts.count == 2, let kind = KeyKind(rawValue: parts[0]) else { return }
            switch parts[1] {
            case "1p": store.chooseSourceKind(kind, .onePassword)
            case "cmd": store.chooseSourceKind(kind, .command)
            default: store.chooseSourceKind(kind, .ask)
            }
        case "pick":
            let parts = rest.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let kind = KeyKind(rawValue: parts[0]) else { return }
            store.openPicker(kind)
            for _ in 0..<40 where store.pickerItems == nil && store.pickerError == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            if let item = store.pickerItems?.first(where: { $0.itemName == parts[1] }) { store.pickItem(kind, item) }
        case "picker":
            if let kind = KeyKind(rawValue: rest) {
                store.openPicker(kind)
                for _ in 0..<40 where store.pickerItems == nil && store.pickerError == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            }
        case "cmd":
            let (kindName, text) = split(rest, "=")
            if let kind = KeyKind(rawValue: kindName) { store.setCommandText(kind, text) }
        case "commit": if let kind = KeyKind(rawValue: rest) { store.commitCommand(kind) }
        case "test":
            if let kind = KeyKind(rawValue: rest) {
                store.runTest(kind)
                for _ in 0..<60 where store.panel(kind).test == .running { try? await Task.sleep(nanoseconds: 100_000_000) }
            }
        case "askkey":
            if case .askKey(let request)? = store.sheet { request.onSubmit(rest) }
        case "invite": store.presentInvite(profile: rest)
        case "name": store.inviteForm.name = rest
        case "invite-mode": store.inviteForm.mode = InviteForm.Mode(rawValue: rest) ?? .machine
        case "invite-ttl": store.inviteForm.ttlDays = Int(rest) ?? 7
        case "create-code":
            if case .invite(let profile)? = store.sheet { store.submitInvite(profile: profile) }
        case "pause":
            let parts = rest.split(separator: ":").map(String.init)
            if parts.count == 2 { store.presentPause(member: parts[1], profile: parts[0]) }
        case "remove-member":
            let parts = rest.split(separator: ":").map(String.init)
            if parts.count == 2 { store.presentRemoveMember(member: parts[1], profile: parts[0]) }
        case "keys":
            // Both key sources as stored commands, so no step asks for a key it was not meant to show.
            for inner in ["source:admin:cmd", "cmd:admin=pass show cf-admin", "commit:admin",
                          "source:minter:cmd", "cmd:minter=pass show cf-minter", "commit:minter"] {
                await step(inner, store: store, controller: controller)
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        case "links":
            let popover = AllLinksWindowController.shared.store?.popover
            for _ in 0..<80 where popover?.profiles == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            AllLinksWindowController.shared.show()
            captureAllLinks = true
        case "ltab":
            AllLinksWindowController.shared.store?.state.show(AllLinksTab(rawValue: rest) ?? .all)
        case "lq": AllLinksWindowController.shared.store?.setQuery(rest)
        case "lselect":
            for id in rest.split(separator: "+") { AllLinksWindowController.shared.store?.state.toggle(String(id)) }
        case "lbulkcopy": AllLinksWindowController.shared.store?.bulkCopy()
        case "lbulkremove": AllLinksWindowController.shared.store?.bulkRemove()
        case "mload":
            for _ in 0..<60 where store.members.list == nil && store.members.failure == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        case "mfilter": store.members.filter = MemberFilter(rawValue: rest) ?? .all
        case "mquery": store.members.query = rest
        case "mmenu":
            if let record = store.members.list?.members.first(where: { $0.name == rest }) { store.members.menuMember = record.memberID }
        case "mverb":
            let parts = rest.split(separator: ":").map(String.init)
            if parts.count == 2, let verb = MemberVerb(rawValue: parts[1]),
               let record = store.members.list?.members.first(where: { $0.name == parts[0] }) { store.memberVerb(verb, member: record) }
        case "wait": try? await Task.sleep(nanoseconds: UInt64((Double(rest) ?? 1) * 1_000_000_000))
        default: break
        }
    }

    private static func split(_ text: String, _ separator: Character) -> (String, String) {
        guard let index = text.firstIndex(of: separator) else { return (text, "") }
        return (String(text[..<index]), String(text[text.index(after: index)...]))
    }
}
#endif
