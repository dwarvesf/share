import AppKit
import ServiceManagement
import ShareBarCore
import SwiftUI

/// One sheet of the Settings window. The window draws it as an overlay (D2).
enum SheetContent {
    case add
    case progress
    case confirm(ImpactSheet, ConfirmAction)
    case refusal(RefusalSheet)
    case code(CodeSheet)
    case invite(profile: String)
    case askKey(AskKeyRequest)
    case picker(KeyKind)

    var kind: SheetKind {
        switch self {
        case .add: return .add
        case .progress: return .progress
        case .confirm: return .confirm
        case .refusal: return .refusal
        case .code: return .code
        case .invite: return .invite
        case .askKey: return .askKey
        case .picker: return .confirm
        }
    }
}

/// What a confirm sheet runs when its action button is pressed.
enum ConfirmAction {
    case stopServing(profile: String)
    case run(argv: [String], done: String)
    /// A verb that needs the admin key, and the minter key for a member add or removal.
    case runKeyed(argv: [String], kinds: [KeyKind], profile: String, done: String)
    case flow(FlowStepPlan, profile: String, done: String)
    case rollBack(op: OpInfo, profile: String)
    /// A verb whose argv depends on the sheet's pop-up (Remove member: keep or delete cloud links).
    case runChoice(done: String, kinds: [KeyKind], profile: String, argv: (Int) -> [String])
    /// A member verb that ends in a code to send (rotate keys, send a new code).
    case runForCode(argv: [String], kinds: [KeyKind], profile: String, member: String, rotate: Bool)
}

struct AddForm: Equatable {
    enum Path: Equatable { case join, setup }
    var path: Path
    var host = ""
    var code = ""
    var alsoCloud = false
}

/// A request for a key typed once (gap G3). `purpose` is the sentence under the title.
struct AskKeyRequest {
    let kind: KeyKind
    let purpose: String
    let onSubmit: (String) -> Void
}

struct Notice: Equatable {
    enum Tone { case ok, failure }
    let text: String
    let tone: Tone
}

enum KeyTestState: Equatable {
    case idle, running
    case passed(KeyTestResult)
    case failed(String)
}

struct KeyPanel: Equatable {
    var source: KeySource
    var commandText: String
    var test: KeyTestState = .idle
    var saved: Bool = false
}

/// A chain of journaled verbs shown in one progress sheet, one after another.
struct FlowStepPlan {
    let argv: [String]
    let kind: FlowKind
    let title: String
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var profiles: ProfilesSnapshot?
    @Published private(set) var failure: Failure?
    @Published var pane: SettingsPane = .general {
        didSet { if pane == .members, oldValue != .members { requestMembers() } }
    }
    @Published var selectedProfile: String?
    @Published var sheet: SheetContent?
    @Published private(set) var flow: FlowRun?
    @Published private(set) var notice: Notice?
    @Published private(set) var loaded = false
    @Published var addForm = AddForm(path: .join)
    @Published var inviteForm = InviteForm()
    @Published var impactChoice = 0

    // General
    @Published private(set) var ttl: ExpiryChoice? = .sevenDays
    @Published private(set) var storage: StorageChoice = .local
    @Published private(set) var openAtLogin = false
    @Published var menuShows: LinkScope
    @Published var recentCount: Int
    @Published var copyAfter: Bool
    @Published var notifyAfter: Bool
    @Published var notifyOffline: Bool
    @Published var notifyExpiry: Bool
    @Published var notifyMember: Bool

    // Advanced
    @Published var keys: [KeyKind: KeyPanel] = [:]
    @Published private(set) var cliPath = ""
    @Published private(set) var cliVersion: String?
    @Published var legacyMenu: Bool
    @Published var keyProfileOverride: String?
    @Published private(set) var pickerItems: [OnePasswordItem]?
    @Published private(set) var pickerError: String?

    let general: GeneralPrefs
    let keyStore: KeySourceStore
    let members = MembersStore()
    /// Called after every `member ls` read, so the popover's member lines of needs a look follow
    /// the roster (the popover never runs `member ls` itself, DEC-54).
    var onMembers: (MemberList?, String) -> Void = { _, _ in }
    /// Why ⌃⌥S did not register (`Control-Option-S is in use by another app`), or nil; the popover owns the key.
    var hotkeyMessage: () -> String? = { nil }
    let popoverPrefs: PopoverPrefs
    private let defaults: UserDefaults
    private let queue = MutationQueue()

    /// Reads (profiles, config, versions) and writes go through these, so tests and shots
    /// can swap them.
    var fetchProfiles: () async -> CLIResult = { await CLI.profiles(fresh: true) }
    var readCLI: ([String]) async -> CLIResult = { await CLI.run($0, timeout: 60) }
    var writeCLI: ([String]) async -> CLIResult
    var openAtLoginProvider: () -> Bool = { SMAppService.mainApp.status == .enabled }
    var locateCLI: () -> String = { CLI.locate(env: ProcessInfo.processInfo.environment, fileExists: { FileManager.default.isExecutableFile(atPath: $0) })?.path ?? "share not found" }
    var listOnePassword: () async -> Result<[OnePasswordItem], OnePasswordError> = { await OnePasswordClient.list() }

    private var runner: FlowRunner?
    private var plan: [FlowStepPlan] = []
    private var planKeys: [String: String] = [:]
    private var planDone: (() -> Void)?
    private var noticeTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        general = GeneralPrefs(defaults: defaults)
        keyStore = KeySourceStore(defaults: defaults)
        popoverPrefs = PopoverPrefs(defaults: defaults)
        menuShows = general.menuShows
        recentCount = general.recentCount
        copyAfter = general.copyAfterSharing
        notifyAfter = general.notifyAfterSharing
        notifyOffline = general.notifyOffline
        notifyExpiry = general.notifyExpiry
        notifyMember = general.notifyMember
        legacyMenu = LegacyMenu.isOn(defaults)
        let queue = self.queue
        writeCLI = { await queue.run($0) }
    }

    // MARK: derived

    var visibleTabs: [SettingsPane] { SettingsTabs.visible(profiles: profiles) }

    var tenants: [ProfileEntry] { TenantList.entries(profiles) }

    func detail(of entry: ProfileEntry) -> TenantDetail? {
        TenantDetail(entry: entry, adminKeyLabel: keyStore.adminKeyLabel(profile: entry.name))
    }

    var selectedEntry: ProfileEntry? {
        let list = tenants
        return list.first { $0.name == selectedProfile } ?? list.first
    }

    var selectedDetail: TenantDetail? { selectedEntry.flatMap(detail(of:)) }

    /// The tenant General and Advanced write to.
    var configTarget: ProfileEntry? {
        if let override = keyProfileOverride, let entry = tenants.first(where: { $0.name == override }) { return entry }
        return ConfigWrites.target(profiles: profiles, current: popoverPrefs.currentProfile)
    }

    var keyTargets: [ProfileEntry] {
        tenants.filter { entry in
            guard let state = entry.state else { return false }
            let role = Role(raw: state.role)
            return role != .member && role != .migrated
        }
    }

    var offersStorage: Bool { configTarget.map(ConfigWrites.offersStorage) ?? false }

    // MARK: window lifecycle

    func show(pane: SettingsPane) {
        self.pane = pane
        if pane == .tenants, let current = popoverPrefs.currentProfile, tenants.contains(where: { $0.name == current }) {
            selectedProfile = current
        }
        Task {
            await refresh()
            if self.pane == .members { requestMembers() }
        }
    }

    func refresh() async {
        let result = await fetchProfiles()
        let folded = ProfilesSnapshot.fold(result, over: profiles)
        profiles = folded.profiles
        failure = folded.failure
        loaded = true
        if !visibleTabs.contains(pane) { pane = .general }
        if selectedProfile == nil || !tenants.contains(where: { $0.name == selectedProfile }) {
            let current = popoverPrefs.currentProfile
            selectedProfile = tenants.first { $0.name == current }?.name ?? tenants.first?.name
        }
        await loadGeneral()
        loadKeys()
        openAtLogin = openAtLoginProvider()
        if cliPath.isEmpty { cliPath = locateCLI() }
        if cliVersion == nil { await loadCLIVersion() }
    }

    func loadCLIVersion() async {
        let result = await readCLI(["version"])
        guard result.status == 0 else { return }
        let words = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        cliVersion = words.last.map(String.init)
    }

    func announce(_ text: String, tone: Notice.Tone = .ok) {
        notice = Notice(text: text, tone: tone)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled { self?.notice = nil }
        }
    }

    // MARK: General

    func loadGeneral() async {
        guard let target = configTarget else { return }
        let read = await readCLI(ConfigWrites.readTTL(profile: target.name))
        if read.status == 0 {
            let value = read.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            ttl = value.isEmpty ? .sevenDays : ExpiryChoice(configValue: value)
        }
        if ConfigWrites.offersStorage(target) {
            let stored = await readCLI(ConfigWrites.readStorageDefault(profile: target.name))
            if stored.status == 0 {
                storage = StorageChoice(rawValue: stored.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                    ?? (target.state?.storageDefault.flatMap(StorageChoice.init(rawValue:)) ?? .local)
            }
        }
    }

    func setExpiry(_ choice: ExpiryChoice) {
        guard let target = configTarget else { return }
        let before = ttl
        ttl = choice
        let argv = ConfigWrites.ttl(profile: target.name, choice)
        Task {
            let result = await writeCLI(argv)
            if result.status != 0 { ttl = before; showFailure(result, host: target.state?.host ?? target.name) }
        }
    }

    func setStorage(_ choice: StorageChoice) {
        guard let target = configTarget else { return }
        let before = storage
        storage = choice
        let argv = ConfigWrites.storageDefault(profile: target.name, choice)
        Task {
            let result = await writeCLI(argv)
            if result.status != 0 { storage = before; showFailure(result, host: target.state?.host ?? target.name) }
        }
    }

    func setMenuShows(_ scope: LinkScope) {
        menuShows = scope
        general.setMenuShows(scope, profiles: tenants.map(\.name))
    }

    func setRecent(_ count: Int) {
        recentCount = count
        general.recentCount = count
    }

    func setCopyAfter(_ on: Bool) { copyAfter = on; general.copyAfterSharing = on }
    func setNotifyAfter(_ on: Bool) { notifyAfter = on; general.notifyAfterSharing = on }
    func setNotifyOffline(_ on: Bool) { notifyOffline = on; general.notifyOffline = on }
    func setNotifyExpiry(_ on: Bool) { notifyExpiry = on; general.notifyExpiry = on }
    func setNotifyMember(_ on: Bool) { notifyMember = on; general.notifyMember = on }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            announce("Could not change Open at login: \(error.localizedDescription)", tone: .failure)
        }
        openAtLogin = openAtLoginProvider()
    }

    // MARK: Advanced

    func loadKeys() {
        guard let target = configTarget else { return }
        for kind in KeyKind.allCases where keys[kind] == nil || keys[kind]?.test == .idle {
            let source = keyStore.load(kind, profile: target.name)
            var panel = keys[kind] ?? KeyPanel(source: source, commandText: "")
            panel.source = source
            if case .command(let text) = source { panel.commandText = text }
            keys[kind] = panel
        }
    }

    func panel(_ kind: KeyKind) -> KeyPanel {
        keys[kind] ?? KeyPanel(source: .askEachTime, commandText: "")
    }

    enum SourceChoice: Hashable { case onePassword, command, ask }

    func sourceChoice(_ kind: KeyKind) -> SourceChoice {
        switch panel(kind).source {
        case .onePassword: return .onePassword
        case .command: return .command
        case .askEachTime: return .ask
        }
    }

    /// The pop-up changed: 1Password keeps whatever item was picked and writes when one is
    /// picked; a command writes when it is committed; Ask me each time clears at once.
    func chooseSourceKind(_ kind: KeyKind, _ choice: SourceChoice) {
        guard let target = configTarget else { return }
        var panel = panel(kind)
        panel.test = .idle
        switch choice {
        case .onePassword:
            if case .onePassword = panel.source {} else {
                let remembered = keyStore.load(kind, profile: target.name)
                if case .onePassword = remembered { panel.source = remembered } else { panel.source = .onePassword(nil) }
            }
        case .command:
            panel.source = .command(panel.commandText)
        case .ask:
            panel.source = .askEachTime
            keys[kind] = panel
            writeSource(kind, panel.source, profile: target.name)
            return
        }
        // 1Password and a command are only a choice on screen until the CLI has stored them:
        // the remembered source changes when the write succeeds, never before.
        keys[kind] = panel
    }

    func setCommandText(_ kind: KeyKind, _ text: String) {
        var panel = panel(kind)
        panel.commandText = text
        panel.source = .command(text)
        panel.saved = false
        keys[kind] = panel
    }

    func commitCommand(_ kind: KeyKind) {
        guard let target = configTarget else { return }
        writeSource(kind, KeySource.command(panel(kind).commandText), profile: target.name)
    }

    func pickItem(_ kind: KeyKind, _ item: OnePasswordItem) {
        guard let target = configTarget else { return }
        var panel = panel(kind)
        panel.source = .onePassword(item)
        panel.test = .idle
        keys[kind] = panel
        sheet = nil
        writeSource(kind, panel.source, profile: target.name)
    }

    private func writeSource(_ kind: KeyKind, _ source: KeySource, profile: String) {
        guard let argv = KeyArgv.write(kind, source: source, profile: profile) else { return }
        Task {
            let result = await writeCLI(argv)
            if result.status == 0 {
                keyStore.save(source, kind: kind, profile: profile)
                var panel = self.panel(kind)
                panel.saved = true
                keys[kind] = panel
            } else {
                showFailure(result, host: profile)
            }
        }
    }

    func openPicker(_ kind: KeyKind) {
        pickerItems = nil
        pickerError = nil
        sheet = .picker(kind)
        Task {
            switch await listOnePassword() {
            case .success(let items): pickerItems = items
            case .failure(let error): pickerError = error.sentence
            }
        }
    }

    func runTest(_ kind: KeyKind) {
        guard let target = configTarget else { return }
        let argv = KeyArgv.test(kind, profile: target.name)
        if case .askEachTime = panel(kind).source {
            sheet = .askKey(AskKeyRequest(kind: kind, purpose: "Share Bar uses it for this test only and forgets it right away.") { [weak self] key in
                self?.sheet = nil
                self?.finishTest(kind, argv: argv, key: key)
            })
            return
        }
        finishTest(kind, argv: argv, key: nil)
    }

    private func finishTest(_ kind: KeyKind, argv: [String], key: String?) {
        var panel = panel(kind)
        panel.test = .running
        keys[kind] = panel
        Task {
            let result: CLIResult
            if let key {
                result = await AskedKeyCommand(argv: argv, variable: kind.environmentName, key: key).spawn().result
            } else {
                result = await readCLI(argv)
            }
            var done = self.panel(kind)
            if result.status == 0, let parsed = KeyTestResult.decode(result.stdout, kind: kind) {
                done.test = .passed(parsed)
            } else {
                done.test = .failed(KeyTestResult.failureSentence(result))
            }
            keys[kind] = done
        }
    }

    func setLegacyMenu(_ on: Bool) {
        legacyMenu = on
        defaults.set(on, forKey: LegacyMenu.key)
    }

    func copyShareState() {
        guard let target = configTarget else { return }
        Task {
            let result = await readCLI(ProfileArgs.argv(target.name, ["state"]))
            guard result.status == 0 else { showFailure(result, host: target.name); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.stdout, forType: .string)
            announce("Copied the share state for \(target.state?.host ?? target.name) as JSON.")
        }
    }

    func showServeLog() {
        guard let target = configTarget else { return }
        let root = target.name == "default" ? "\(NSHomeDirectory())/share" : "\(NSHomeDirectory())/share/profiles/\(target.name)"
        let candidates = ["\(root)/serve.log", "\(root)/logs/serve.log", "\(root)/.serve.log"]
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: found)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: root))
        }
    }

    // MARK: Tenants

    func select(_ profile: String) { selectedProfile = profile }

    func presentAdd(_ kind: AddSheetKind) {
        pane = .tenants
        addForm = AddForm(path: kind == .join ? .join : .setup)
        sheet = .add
    }

    /// The Members tab's Invite… button.
    func presentInvite(profile: String) {
        inviteForm = InviteForm()
        sheet = .invite(profile: profile)
    }

    /// `display` is the capitalised name the sheet says; `member` is the CLI name argv carries.
    func presentPause(member: String, profile: String, display: String? = nil) {
        let shares = entry(profile)?.state?.shares ?? []
        let shown = display ?? member
        impactChoice = 0
        sheet = .confirm(Impact.pause(member: shown, shares: shares),
                         .runKeyed(argv: ProfileArgs.argv(profile, ["member", "pause", member]), kinds: [.admin], profile: profile, done: "\(shown) is paused."))
    }

    func presentRemoveMember(member: String, profile: String, display: String? = nil) {
        let shares = entry(profile)?.state?.shares ?? []
        let shown = display ?? member
        impactChoice = 0
        sheet = .confirm(Impact.removeMember(member: shown, shares: shares),
                         .runChoice(done: "\(shown) is removed. Their machine links stopped answering.", kinds: [.admin, .minter], profile: profile) { choice in
                             ProfileArgs.argv(profile, ["member", "rm", member, "--cloud-links", choice == 0 ? "keep" : "delete"])
                         })
    }

    /// Create code: runs `member add` (admin and minter keys), then shows the code once.
    func submitInvite(profile: String) {
        guard let argv = inviteForm.argv(profile: profile) else { return }
        let form = inviteForm
        collectKeys(keysNeedingAsk([.admin, .minter], profile: profile), asked: [:],
                    purpose: "Share Bar uses it to add this member and forgets it right away.") { [weak self] keys in
            guard let self else { return }
            Task {
                let result = await self.runWith(argv, keys: keys)
                guard result.status == 0, let code = InviteForm.code(fromStdout: result.stdout) else {
                    self.showFailure(result, host: self.entry(profile)?.state?.host ?? profile)
                    return
                }
                self.sheet = .code(CodeSheet(member: form.name.trimmingCharacters(in: .whitespaces), code: code, rotate: false, ttlDays: form.ttlDays))
                await self.loadMembers(profile: profile, keys: keys)
            }
        }
    }

    // MARK: asked keys

    /// The keys among `kinds` whose source is "Ask me each time" for this profile.
    func keysNeedingAsk(_ kinds: [KeyKind], profile: String) -> [KeyKind] {
        kinds.filter { kind in
            if case .askEachTime = keyStore.load(kind, profile: profile) { return true }
            return false
        }
    }

    /// Opens one ask sheet per key, in order, gathering each value in `asked` only; calls `then`
    /// with everything asked. Cancel (Esc) leaves nothing running and nothing kept.
    func collectKeys(_ remaining: [KeyKind], asked: [String: String], purpose: String, then: @escaping ([String: String]) -> Void) {
        guard let kind = remaining.first else { then(asked); return }
        sheet = .askKey(AskKeyRequest(kind: kind, purpose: purpose) { [weak self] key in
            self?.sheet = nil
            var next = asked
            next[kind.environmentName] = key
            self?.collectKeys(Array(remaining.dropFirst()), asked: next, purpose: purpose, then: then)
        })
    }

    /// Runs one command with the asked keys in its environment, through the app's queue when
    /// there are none.
    func runWith(_ argv: [String], keys: [String: String]) async -> CLIResult {
        if keys.isEmpty { return await writeCLI(argv) }
        return await AskedKeyCommand(argv: argv, environment: keys).spawn().result
    }

    func runKeyed(_ argv: [String], kinds: [KeyKind], profile: String, host: String, done: String) {
        collectKeys(keysNeedingAsk(kinds, profile: profile), asked: [:],
                    purpose: "Share Bar uses it for this one action and forgets it right away.") { [weak self] keys in
            guard let self else { return }
            Task {
                let result = await self.runWith(argv, keys: keys)
                await self.refresh()
                if argv.contains("member") { await self.loadMembers(profile: profile, keys: keys) }
                if result.status == 0 { self.announce(done) } else { self.showFailure(result, host: host) }
            }
        }
    }

    func loadKeysAgain() {
        keys = [:]
        loadKeys()
    }

    func openInBrowser(_ detail: TenantDetail) {
        if let url = URL(string: "https://\(detail.host)/") { NSWorkspace.shared.open(url) }
    }

    func copyRequest(_ detail: TenantDetail) {
        let reason = detail.banner == .keyExpired ? "expired" : "stopped working"
        let text = "Hi, my Share key for \(detail.host) \(reason). Could you renew it? Thanks."
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        announce("Copied a renew request for your admin.")
    }

    func perform(_ action: TenantAction, on detail: TenantDetail) {
        switch action {
        case .start:
            runQuiet(ProfileArgs.start(detail.profile), host: detail.host, done: "\(detail.host) is starting.")
        case .stop:
            let shares = entry(detail.profile)?.state?.shares ?? []
            sheet = .confirm(Impact.stopServing(host: detail.host, shares: shares), .stopServing(profile: detail.profile))
        case .turnOnCloud:
            guard let argv = FlowArgv.turnOnCloud(profile: detail.profile, host: detail.host) else { return }
            startPlan([FlowStepPlan(argv: argv, kind: .setupR2, title: "Turning on cloud storage for \(detail.host)")],
                      needsKey: true, profile: detail.profile, done: "\(detail.host): cloud storage is on.")
        case .turnOnMembers:
            guard let argv = FlowArgv.turnOnMembers(profile: detail.profile, host: detail.host) else { return }
            sheet = .confirm(Impact.turnOnMembers(host: detail.host),
                             .flow(FlowStepPlan(argv: argv, kind: .setupMembers, title: "Turning on members for \(detail.host)"),
                                   profile: detail.profile, done: "\(detail.host): members are on. Invite people from the Members tab."))
        case .resume:
            resume(detail)
        case .rollBack:
            guard let op = detail.callout?.op,
                  let checked = JournalRun.argv(op: op, kind: .rollback, profile: detail.profile) else { return }
            // The sheet names the checked argv that will run, never the journal's display string.
            let command = "share " + checked.joined(separator: " ")
            let what = op.verb == "setup-r2" ? "cloud storage" : (op.verb == "join" ? "the join" : op.verb)
            sheet = .confirm(Impact.rollBack(what: what, command: command), .rollBack(op: op, profile: detail.profile))
        case .openInBrowser:
            openInBrowser(detail)
        case .copyRequest:
            copyRequest(detail)
        case .cleanUp:
            confirmRemoval(detail)
        }
    }

    func confirmRemoval(_ detail: TenantDetail) {
        guard let removal = detail.removal else { return }
        if removal == .refusedMembers {
            sheet = .refusal(Impact.refusedMembers(host: detail.host))
            return
        }
        let shares = entry(detail.profile)?.state?.shares ?? []
        guard let impact = Impact.removeTenant(detail, shares: shares), let argv = removal.argv(profile: detail.profile) else { return }
        let word = removal == .teardown(cloudLinksKeepAnswering: false) || removal == .teardown(cloudLinksKeepAnswering: true) ? "Removed" : (removal == .leave ? "Left" : "Cleaned up")
        sheet = .confirm(impact, .run(argv: argv, done: "\(word) \(detail.host)."))
    }

    func confirm(_ action: ConfirmAction) {
        sheet = nil
        switch action {
        case .stopServing(let profile):
            let host = entry(profile)?.state?.host ?? profile
            runQuiet(ProfileArgs.stop(profile), host: host, done: "\(host) stopped serving from this Mac.")
        case .runChoice(let done, let kinds, let profile, let argv):
            runKeyed(argv(impactChoice), kinds: kinds, profile: profile, host: entry(profile)?.state?.host ?? profile, done: done)
        case .runKeyed(let argv, let kinds, let profile, let done):
            runKeyed(argv, kinds: kinds, profile: profile, host: entry(profile)?.state?.host ?? profile, done: done)
        case .runForCode(let argv, let kinds, let profile, let member, let rotate):
            runForCode(argv, kinds: kinds, profile: profile, member: member, rotate: rotate)
        case .flow(let step, let profile, let done):
            startPlan([step], needsKey: true, profile: profile, done: done)
        case .run(let argv, let done):
            let host = argv.first == "--profile" && argv.count > 2 ? (entry(argv[1])?.state?.host ?? argv[1]) : ""
            runQuiet(argv, host: host, done: done)
        case .rollBack(let op, let profile):
            guard let argv = JournalRun.argv(op: op, kind: .rollback, profile: profile) else { return }
            let host = entry(profile)?.state?.host ?? profile
            runKeyed(argv, kinds: op.verb == "join" ? [] : [.admin], profile: profile, host: host, done: "Rolled back: \(host).")
        }
    }

    func resume(_ detail: TenantDetail) {
        guard let op = detail.callout?.op,
              let argv = JournalRun.argv(op: op, kind: .rerun, profile: detail.profile) else { return }
        if let kind = FlowKind(rawValue: op.verb) {
            let needsKey = kind == .setupR2 || kind == .setupMembers
            startPlan([FlowStepPlan(argv: argv, kind: kind, title: "Resuming \(op.verb) on \(detail.host)")],
                      needsKey: needsKey, profile: detail.profile, done: "\(detail.host): finished.")
        } else {
            runQuiet(argv, host: detail.host, done: "\(detail.host): finished.")
        }
    }

    func entry(_ profile: String) -> ProfileEntry? { profiles?.profiles.first { $0.name == profile } }

    /// A verb with no progress sheet: run it, read the tenants again, say what happened.
    private func runQuiet(_ argv: [String], host: String, done: String) {
        Task {
            let result = await writeCLI(argv)
            await refresh()
            if result.status == 0 { announce(done) } else { showFailure(result, host: host) }
        }
    }

    /// A refused or failed command: the CLI's sentence and its next step, on the refusal sheet.
    func showFailure(_ result: CLIResult, host: String) {
        let error = ErrorLine.last(inStderr: result.stderr)
        let line = result.lastErrorLine
        let message = error?.message ?? (line.hasPrefix("share: ") ? String(line.dropFirst(7)) : line)
        sheet = .refusal(RefusalSheet.from(code: error?.code ?? "", message: Redact.tokenShaped(message), next: error?.next, host: host))
    }

    // MARK: add flows

    func submitAdd() {
        let form = addForm
        switch form.path {
        case .join:
            let parsed = JoinInput.parse(codeField: form.code, hostField: form.host)
            guard let argv = FlowArgv.join(host: parsed.host, code: parsed.code) else { return }
            startPlan([FlowStepPlan(argv: argv, kind: .join, title: "Joining \(parsed.host)")], needsKey: false,
                      profile: ProfileName.slug(host: parsed.host), done: "You joined \(parsed.host).")
        case .setup:
            let host = form.host.trimmingCharacters(in: .whitespaces)
            guard let argv = FlowArgv.setup(host: host) else { return }
            var steps = [FlowStepPlan(argv: argv, kind: .setupTunnel, title: "Setting up \(host)")]
            if form.alsoCloud, let r2 = FlowArgv.turnOnCloud(profile: ProfileName.slug(host: host), host: host) {
                steps.append(FlowStepPlan(argv: r2, kind: .setupR2, title: "Turning on cloud storage for \(host)"))
            }
            startPlan(steps, needsKey: true, profile: ProfileName.slug(host: host), done: "\(host) is serving from this Mac.")
        }
    }

    /// Starts a chain of journaled verbs. When the admin key is "Ask me each time" and the
    /// chain needs it, the ask sheet opens first and the key goes to each command's
    /// environment only.
    func startPlan(_ steps: [FlowStepPlan], needsKey: Bool, profile: String, done: String) {
        guard !steps.isEmpty, runner == nil || !(flow?.isActive ?? false) else { return }
        let asking = needsKey ? keysNeedingAsk([.admin], profile: profile) : []
        collectKeys(asking, asked: [:], purpose: "Share Bar uses it for this action and forgets it when the action ends.") { [weak self] keys in
            guard let self else { return }
            self.plan = steps
            self.planKeys = keys
            self.planDone = { [weak self] in
                guard let self else { return }
                Task {
                    await self.refresh()
                    self.announce(done)
                }
            }
            self.startNext()
        }
    }

    private func startNext() {
        guard !plan.isEmpty else { return }
        let step = plan.removeFirst()
        let runner = FlowRunner(argv: step.argv, kind: step.kind, title: step.title, environment: planKeys) { [weak self] run in
            Task { @MainActor in self?.flowChanged(run) }
        }
        self.runner = runner
        flow = runner.run
        sheet = .progress
        runner.start()
    }

    private func flowChanged(_ run: FlowRun) {
        guard flow?.kind == run.kind || flow == nil else { return }
        // Snapshots hop threads before they reach here: a late running one never undoes a later phase.
        if case .running = run.phase, let current = flow, current.kind == run.kind, !current.isActive || current.phase == .stopping { return }
        flow = run
        guard case .done = run.phase else {
            if case .failed = run.phase { dropKey() }
            if case .stopped = run.phase { dropKey(); Task { await refresh() } }
            return
        }
        if !plan.isEmpty {
            startNext()
            return
        }
        let done = planDone
        planDone = nil
        dropKey()
        runner = nil
        sheet = nil
        flow = nil
        done?()
    }

    private func dropKey() {
        planKeys = [:]
        plan = []
    }

    /// Stop on the progress sheet: SIGTERM, the journal keeps the step.
    func stopFlow() {
        runner?.stop()
    }

    /// Close on the progress sheet once the run ended (stopped or failed).
    func closeProgress() {
        guard let run = flow, !run.isActive else { return }
        runner = nil
        flow = nil
        sheet = nil
        Task { await refresh() }
    }

    // MARK: sheets

    func dismissSheet() {
        guard let sheet else { return }
        if !sheet.kind.escCloses { return }
        self.sheet = nil
        // Esc on the key the tab asked for: the list stays unread, with a way to ask again.
        if case .askKey = sheet, members.askPending, members.list == nil, members.profile != nil {
            members.askPending = false
            members.failed("Reading the members needs the admin key.", profile: members.profile ?? "")
        }
    }

    /// Esc: closes every sheet but progress.
    func escape() { dismissSheet() }

    func openMembers() {
        sheet = nil
        if visibleTabs.contains(.members) { pane = .members }
    }
}

enum OnePasswordError: Error {
    case notFound
    case failed(String)

    var sentence: String {
        switch self {
        case .notFound: return "The 1Password command line (op) was not found. Install it, or choose From a command."
        case .failed(let text): return text
        }
    }
}

/// Lists items by name and id for the picker; never reads a secret value.
enum OnePasswordClient {
    static func locate() -> String? {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["SHAREBAR_OP_BIN"], !override.isEmpty { return override }
        #endif
        return ["/opt/homebrew/bin/op", "/usr/local/bin/op", "/usr/bin/op"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func list() async -> Result<[OnePasswordItem], OnePasswordError> {
        guard let path = locate() else { return .failure(.notFound) }
        return await Task.detached(priority: .userInitiated) { () -> Result<[OnePasswordItem], OnePasswordError> in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["item", "list", "--format", "json"]
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch { return .failure(.failed("Could not run op: \(error.localizedDescription)")) }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let line = String(decoding: errData, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? "op exited \(process.terminationStatus)"
                return .failure(.failed(Redact.tokenShaped(line.replacingOccurrences(of: "[ERROR] ", with: ""))))
            }
            return .success(OnePasswordItem.decode(String(decoding: data, as: UTF8.self)))
        }.value
    }
}
