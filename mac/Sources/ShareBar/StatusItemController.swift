import AppKit
import ServiceManagement
import ShareBarCore
import os

private let actionLogger = Logger(subsystem: ShareBarIdentity.bundleID, category: "actions")

/// Carries a non-Sendable AppKit value across a Task boundary when the caller already
/// guarantees (as here) that it's only ever touched back on the main thread.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A row's submenu, tagged with the (profile, share id) pair it belongs to and holding a
/// direct reference to its "Loading…" item, so `menuWillOpen`/hits completion can address
/// it without a lookup table keyed by menu identity.
private final class RowMenu: NSMenu {
    let profile: String
    let rowID: String
    let hitsItem: NSMenuItem

    init(profile: String, rowID: String, hitsItem: NSMenuItem) {
        self.profile = profile
        self.rowID = rowID
        self.hitsItem = hitsItem
        super.init(title: "")
    }

    required init(coder: NSCoder) {
        fatalError("RowMenu does not support NSCoding")
    }
}

/// Owns the status item and its menu: builds a plain `NSMenu` from the latest `MenuModel`,
/// keeps it current on a 60s timer, on wake, and on every open, and applies the icon.
///
/// Every verb the app runs is `--profile <name> <verb>`, `default` included, so the menu
/// and the writes resolve the same profile and root. A failed or timed-out refresh keeps
/// the last good snapshot on screen (stale: slashed icon, failure header); only
/// `.cliNotFound` and `.oldCLI` clear the sections, because no verb would work.
// @unchecked Sendable: every mutable property is only ever touched on the main thread (init,
// or a block scheduled through `RunLoop.main.perform(inModes:)`); this just tells the
// compiler what's already true so the refresh closure doesn't need a warning suppressed
// some other way.
final class StatusItemController: NSObject, @unchecked Sendable {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let mutationQueue = MutationQueue()
    private let defaults: UserDefaults = .standard

    private var model = MenuModel(profiles: nil, failure: nil, now: Date())
    private var refreshGate = RefreshGate()
    private var pollTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    // MARK: - Mutating-verb state

    /// The last `profiles --json` read, kept alongside `model` so a mutation's start/end
    /// can rebuild `MenuModel` with a new `working` flag without re-reading.
    private var currentProfiles: ProfilesSnapshot?
    /// Non-nil while the latest refresh failed; beside a kept `currentProfiles` it marks
    /// the snapshot stale (slashed icon, publish button names the profile).
    private var currentFailure: Failure?
    private var working: Working?
    private var showStopWaitingItem = false
    private var stopWaitingTimer: Timer?
    private var checkmarkRevertTimer: Timer?
    private var dropView: DropView?

    // MARK: - Lazy hits state

    /// One call in flight at a time; a new submenu opening cancels whatever was running.
    private var currentHitsJob: CLIJob?
    private var currentHitsKey: String?
    /// Bumped on every `requestHits` call; a completion whose generation no longer matches
    /// belonged to a cancelled or superseded call and is discarded rather than applied or
    /// cached (it may carry killed-process garbage, not a real hits line).
    private var hitsGeneration = 0
    /// Keyed by (profile, id); cleared when the top-level menu closes.
    private var hitsCache: [String: String] = [:]

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        installDropView()

        // Renders the "Loading…" placeholder instantly so the item never opens empty; the
        // first real `profiles` call (kicked off below) replaces it in place when it returns.
        applyModel()
        startPolling()
        observeWake()
        triggerRefresh()
    }

    deinit {
        pollTimer?.invalidate()
        stopWaitingTimer?.invalidate()
        checkmarkRevertTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    // MARK: - Polling and wake

    private func startPolling() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.triggerRefresh()
        }
        // .common, not the default mode, so the tick still fires while the menu is open
        // (NSMenu tracking runs its own run loop mode).
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.triggerRefresh()
        }
    }

    // MARK: - Refresh

    /// Runs `share profiles --json`, then applies the result on the main run loop in
    /// common modes, so an already-open menu still updates in place. A plain trigger
    /// during a run is dropped (that run answers it); a `fresh` trigger (setup
    /// completion) during a run gets its own run once that one ends, so it always sees a
    /// read that started after its verb exited.
    private func triggerRefresh(fresh: Bool = false) {
        guard refreshGate.request(fresh: fresh) else { return }
        startRefresh(fresh: fresh)
    }

    private func startRefresh(fresh: Bool) {
        Task { [weak self] in
            let result = await CLI.profiles(fresh: fresh)
            guard let self else { return }
            RunLoop.main.perform(inModes: [.common]) {
                self.applyResult(result)
                self.rebuildModel()
                if self.refreshGate.finish() {
                    self.startRefresh(fresh: true)
                }
            }
        }
    }

    /// Folds one `profiles --json` result into `currentProfiles`/`currentFailure`
    /// (rules in `ProfilesSnapshot.fold`).
    private func applyResult(_ result: CLIResult) {
        (currentProfiles, currentFailure) = ProfilesSnapshot.fold(result, over: currentProfiles)
    }

    /// Rebuilds `model` from the last read plus the current `working` flag, then
    /// re-renders. The one place both inputs to `MenuModel` come together, so a
    /// mutation's start/end can flip the header to/from the Working line without a fresh
    /// `profiles` call, and a fresh result can land without losing that flag.
    private func rebuildModel() {
        model = MenuModel(profiles: currentProfiles, failure: currentFailure, now: Date(), working: working)
        applyModel()
    }

    // MARK: - Rendering

    private func applyModel() {
        if let button = statusItem.button {
            StatusIcon.apply(model.icon, to: button)
            button.setAccessibilityLabel(model.header)
        }

        menu.removeAllItems()

        let headerItem = NSMenuItem(title: model.header, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())

        // The trailing column (`2d left`, `live`, `never`, `expired`) right-aligns at a tab
        // stop past the widest row title in this render, so it reads as one column instead
        // of drifting per row.
        let font = NSFont.menuFont(ofSize: 0)
        let widestRowTitle = model.sections
            .flatMap(\.rows)
            .reduce(into: CGFloat(0)) { widest, row in
                widest = max(widest, (row.title as NSString).size(withAttributes: [.font: font]).width)
            }
        let tabLocation = widestRowTitle + 24

        for section in model.sections {
            addSection(section, tabLocation: tabLocation, font: font)
            menu.addItem(.separator())
        }

        if showStopWaitingItem {
            menu.addItem(actionItem("Stop Waiting…", action: #selector(stopWaiting)))
        }

        let shareItem = actionItem("Share File…", action: #selector(shareFile), keyEquivalent: "n")
        shareItem.isEnabled = model.canPublish
        menu.addItem(shareItem)

        if model.showCopyInstallCommand {
            menu.addItem(actionItem("Copy Install Command", action: #selector(copyInstallCommand)))
        }
        if model.showCopyUpgradeCommand {
            menu.addItem(actionItem("Copy Upgrade Command", action: #selector(copyUpgradeCommand)))
        }

        menu.addItem(openAtLoginItem())

        menu.addItem(.separator())

        menu.addItem(actionItem("About Share Bar", action: #selector(aboutShareBar)))

        let quitItem = NSMenuItem(title: "Quit Share Bar", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// One profile's block: the disabled `<name> · <host or -> · <status>` title line, its
    /// rows, the `N more` hint, Start/Stop Sharing, Set Up…, and the access_pending note.
    private func addSection(_ section: Section, tabLocation: CGFloat, font: NSFont) {
        let titleItem = NSMenuItem(
            title: "\(section.profile) · \(section.host ?? "-") · \(section.status)",
            action: nil,
            keyEquivalent: ""
        )
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        for row in section.rows {
            let item = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
            item.attributedTitle = rowAttributedTitle(row, tabLocation: tabLocation, font: font)
            item.setAccessibilityTitle(row.accessibilityTitle)
            if let typeImage = NSImage(systemSymbolName: row.typeGlyph.symbol, accessibilityDescription: row.typeGlyph.word) {
                typeImage.isTemplate = true
                item.image = typeImage
            }
            item.submenu = submenu(for: row)
            menu.addItem(item)
        }

        if section.more > 0 {
            let prefix = section.cloudMore ? "about " : ""
            let moreItem = NSMenuItem(title: "\(prefix)\(section.more) more (\(section.command) ls)", action: nil, keyEquivalent: "")
            moreItem.isEnabled = false
            menu.addItem(moreItem)
        }

        if let cloudError = section.cloudError {
            let errorItem = NSMenuItem(title: "Cloud links not listed: \(cloudError)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        if section.showStop {
            menu.addItem(sectionItem("Stop Sharing", action: #selector(stopSharing), profile: section.profile))
        } else if section.showStart {
            menu.addItem(sectionItem("Start Sharing", action: #selector(startSharing), profile: section.profile))
        }

        if section.showSetUp {
            let item = actionItem("Set Up…", action: #selector(setUp))
            item.representedObject = section
            menu.addItem(item)
        }

        if section.accessPending > 0 {
            let pendingItem = NSMenuItem(
                title: "\(section.accessPending) Access app(s) await deletion (\(section.command) prune)",
                action: nil,
                keyEquivalent: ""
            )
            pendingItem.isEnabled = false
            menu.addItem(pendingItem)
        }
    }

    /// The name in the plain font/color, a tab, then the trailing text right-aligned at
    /// `tabLocation` in `secondaryLabelColor` (macOS's shortcut-hint grey), and after it
    /// the marker column: the storage badge, the link-type marker, and the lock on a
    /// gated row. `item.title` is still set to the plain name (see `addSection`) so
    /// accessibility reads the name alone. A symbol name that fails to resolve falls
    /// back to no image rather than a blank box.
    private func rowAttributedTitle(_ row: Row, tabLocation: CGFloat, font: NSFont) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.tabStops = [NSTextTab(textAlignment: .right, location: tabLocation, options: [:])]
        paragraphStyle.defaultTabInterval = tabLocation

        let result = NSMutableAttributedString(
            string: row.title,
            attributes: [.font: font, .paragraphStyle: paragraphStyle]
        )
        result.append(NSAttributedString(
            string: "\t\(row.trailing)",
            attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle,
            ]
        ))

        var markers = [row.linkGlyph]
        if let storage = row.storageGlyph {
            markers.insert(storage, at: 0)
        }
        if row.access != nil {
            markers.append(RowGlyphs.lock)
        }
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
        for marker in markers {
            guard let image = NSImage(systemSymbolName: marker.symbol, accessibilityDescription: marker.word)?
                .withSymbolConfiguration(symbolConfig) else { continue }
            image.isTemplate = true
            result.append(NSAttributedString(
                string: " ",
                attributes: [.font: font, .paragraphStyle: paragraphStyle]
            ))
            let attachment = NSTextAttachment()
            attachment.image = image
            // Baseline-to-descender alignment: the marker bottoms out where the text does.
            attachment.bounds = CGRect(origin: CGPoint(x: 0, y: font.descender), size: image.size)
            result.append(NSAttributedString(attachment: attachment))
        }
        return result
    }

    private func submenu(for row: Row) -> NSMenu {
        let hitsItem = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
        hitsItem.isEnabled = false

        let submenu = RowMenu(profile: row.profile, rowID: row.id, hitsItem: hitsItem)
        submenu.autoenablesItems = false
        submenu.delegate = self

        if let rule = row.access {
            let gateItem = NSMenuItem(title: "Login required: \(rule)", action: nil, keyEquivalent: "")
            gateItem.isEnabled = false
            submenu.addItem(gateItem)
            submenu.addItem(.separator())
        }

        let copyItem = actionItem("Copy Link", action: #selector(copyLink))
        copyItem.isEnabled = row.canCopy
        copyItem.representedObject = row
        submenu.addItem(copyItem)

        let openItem = actionItem("Open in Browser", action: #selector(openInBrowser))
        openItem.isEnabled = row.canCopy
        openItem.representedObject = row
        submenu.addItem(openItem)

        let refreshItem = actionItem("Refresh", action: #selector(refreshRow))
        refreshItem.isEnabled = row.canRefresh
        refreshItem.representedObject = row
        submenu.addItem(refreshItem)

        submenu.addItem(hitsItem)

        submenu.addItem(.separator())
        let removeItem = actionItem("Remove…", action: #selector(removeRow))
        removeItem.representedObject = row
        submenu.addItem(removeItem)

        return submenu
    }

    /// Reads (never registers on its own) `SMAppService.mainApp.status` every time the menu
    /// renders, i.e. every open. `.requiresApproval` shows the approve-in-Settings wording;
    /// clicking it in that state opens Login Items instead of toggling registration.
    private func openAtLoginItem() -> NSMenuItem {
        let status = SMAppService.mainApp.status
        let title = status == .requiresApproval
            ? "Open at Login (approve in System Settings)"
            : "Open at Login"
        let item = actionItem(title, action: #selector(toggleOpenAtLogin))
        item.state = status == .enabled ? .on : .off
        return item
    }

    private func actionItem(_ title: String, action: Selector = #selector(noOp), keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    /// An action item that also carries the profile it acts on.
    private func sectionItem(_ title: String, action: Selector, profile: String) -> NSMenuItem {
        let item = actionItem(title, action: action)
        item.representedObject = profile
        return item
    }

    @objc private func noOp() {}

    // MARK: - Row actions

    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Row, row.canCopy else { return }
        actionLogger.log("copy-link profile=\(row.profile, privacy: .public) id=\(row.id, privacy: .public)")
        setPasteboard(row.url)
    }

    @objc private func openInBrowser(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Row, row.canCopy, let url = URL(string: row.url) else { return }
        actionLogger.log("open-in-browser profile=\(row.profile, privacy: .public) id=\(row.id, privacy: .public)")
        NSWorkspace.shared.open(url)
    }

    // MARK: - Mutating actions

    @objc private func refreshRow(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Row, row.canRefresh else { return }
        actionLogger.log("refresh profile=\(row.profile, privacy: .public) id=\(row.id, privacy: .public)")
        Task { [weak self] in
            await self?.performMutation(ProfileArgs.refresh(row.profile, id: row.id), warningShareID: row.id, isAdd: false, profile: row.profile)
        }
    }

    @objc private func removeRow(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Row else { return }
        guard confirmRemove(row) else { return }
        actionLogger.log("remove profile=\(row.profile, privacy: .public) id=\(row.id, privacy: .public)")
        Task { [weak self] in
            await self?.performMutation(ProfileArgs.remove(row.profile, id: row.id), warningShareID: nil, isAdd: false, profile: row.profile)
        }
    }

    /// Cancel is the default button (added first, so it gets the Return key equivalent and
    /// the rightmost/primary position); Remove is the destructive-styled secondary button.
    private func confirmRemove(_ row: Row) -> Bool {
        let alert = NSAlert()
        alert.messageText = row.removeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        let removeButton = alert.addButton(withTitle: "Remove")
        removeButton.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc private func startSharing(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? String else { return }
        actionLogger.log("start profile=\(profile, privacy: .public)")
        Task { [weak self] in
            await self?.performMutation(ProfileArgs.start(profile), warningShareID: nil, isAdd: false, profile: profile)
        }
    }

    @objc private func stopSharing(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? String else { return }
        actionLogger.log("stop profile=\(profile, privacy: .public)")
        Task { [weak self] in
            await self?.performMutation(ProfileArgs.stop(profile), warningShareID: nil, isAdd: false, profile: profile)
        }
    }

    @objc private func shareFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Share"
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        presentPublishDialog(paths: paths)
    }

    @objc private func stopWaiting() {
        Task { [weak self] in
            // Read the running job's token BEFORE the confirm opens: a confirm answered
            // after that job ended cancels nothing (never the next job).
            guard let token = await self?.mutationQueue.currentJob() else { return }
            RunLoop.main.perform(inModes: [.common]) {
                guard let self else { return }
                let alert = NSAlert()
                alert.messageText = StopWaiting.confirmText
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Continue Waiting")
                let stopButton = alert.addButton(withTitle: "Stop Waiting")
                stopButton.hasDestructiveAction = true
                guard alert.runModal() == .alertSecondButtonReturn else { return }
                actionLogger.log("stop-waiting confirmed")
                Task { [weak self] in await self?.mutationQueue.cancel(job: token) }
            }
        }
    }

    // MARK: - Publish dialog

    /// Every drop and every Share File… selection opens one `NSAlert` with an accessory
    /// view, one dialog per batch. `PublishForm` holds all its state and rules; the
    /// dialog only renders it and writes back the mutations (`select`, `choose`).
    private func presentPublishDialog(paths: [String]) {
        guard let profiles = currentProfiles, !PublishChoice.eligible(profiles).isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No share profile is ready. Set one up first."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        var form = PublishForm(
            profiles: profiles,
            lastProfile: defaults.string(forKey: "publish.lastProfile"),
            lastRules: storedRules(profiles: profiles),
            staleHosts: currentFailure != nil
        )

        let alert = NSAlert()
        alert.messageText = PublishMessage.text(paths: paths, isDirectory: isDirectory)
        alert.addButton(withTitle: form.buttonTitle)
        alert.addButton(withTitle: "Cancel")

        let profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for name in PublishChoice.eligible(profiles) {
            let host = profiles.profiles.first { $0.name == name }?.state?.host
            profilePopup.addItem(withTitle: host.map { "\(name) · \($0)" } ?? name)
            profilePopup.lastItem?.representedObject = name
        }
        if let selected = form.profile,
           let index = profilePopup.itemArray.firstIndex(where: { $0.representedObject as? String == selected }) {
            profilePopup.selectItem(at: index)
        }

        let audiencePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        audiencePopup.addItems(withTitles: ["Anyone with the link", "Only people who log in"])
        audiencePopup.selectItem(at: form.audience == .login ? 1 : 0)

        // One `Storage:` row holds two possible controls: the picker an r2-on origin
        // gets, and the disabled label a member gets. `sync` picks between them (and
        // hides the row entirely for a plain tunnel profile) as the profile changes.
        let storagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let storageLabel = NSTextField(labelWithString: "In the cloud")
        storageLabel.isEnabled = false
        let storageControls = NSStackView(views: [storagePopup, storageLabel])
        storageControls.orientation = .horizontal
        let storageRow = labeledRow("Storage:", storageControls)

        let ruleField = NSTextField(frame: .zero)
        ruleField.placeholderString = "group:<name>, email:a@x.io,b@y.io, or domain:<domain>"
        ruleField.stringValue = form.rule
        ruleField.translatesAutoresizingMaskIntoConstraints = false

        let loginNote = NSTextField(labelWithString: "Login needs a named setup, not quick mode")
        loginNote.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        loginNote.textColor = .secondaryLabelColor

        let accessory = NSStackView(views: [
            labeledRow("Profile:", profilePopup),
            storageRow,
            labeledRow("Who can open:", audiencePopup),
            labeledRow("Rule:", ruleField),
            loginNote,
        ])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        accessory.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 0, right: 0)
        accessory.translatesAutoresizingMaskIntoConstraints = false
        accessory.widthAnchor.constraint(equalToConstant: 380).isActive = true
        ruleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        alert.accessoryView = accessory

        let sync: (PublishForm) -> Void = { [ruleField, loginNote, storageRow, storagePopup, storageLabel, alert] form in
            // Only on a real change: rewriting the text mid-edit would move the caret.
            if ruleField.stringValue != form.rule {
                ruleField.stringValue = form.rule
            }
            ruleField.isEnabled = form.audience == .login
            loginNote.isHidden = !(form.audience == .login && !form.loginAvailable)
            switch form.storageField {
            case .none:
                storageRow.isHidden = true
            case .member:
                storageRow.isHidden = false
                storagePopup.isHidden = true
                storageLabel.isHidden = false
            case .picker(let machine):
                storageRow.isHidden = false
                storageLabel.isHidden = true
                storagePopup.isHidden = false
                let titles = ["On \(machine)", "In the cloud"]
                if storagePopup.itemTitles != titles {
                    storagePopup.removeAllItems()
                    storagePopup.addItems(withTitles: titles)
                }
                let index = form.storage == .cloud ? 1 : 0
                if storagePopup.indexOfSelectedItem != index {
                    storagePopup.selectItem(at: index)
                }
            }
            alert.buttons[0].title = form.buttonTitle
            alert.buttons[0].isEnabled = form.canPublish
        }
        sync(form)

        let alertForm = AlertForm(form: form, sync: sync, ruleField: ruleField)
        profilePopup.target = alertForm
        profilePopup.action = #selector(AlertForm.profileChanged(_:))
        audiencePopup.target = alertForm
        audiencePopup.action = #selector(AlertForm.audienceChanged(_:))
        storagePopup.target = alertForm
        storagePopup.action = #selector(AlertForm.storageChanged(_:))
        ruleField.target = alertForm
        ruleField.action = #selector(AlertForm.ruleEdited(_:))
        ruleField.delegate = alertForm

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        form = alertForm.form
        guard let profile = form.profile, form.canPublish else { return }
        let rule = form.audience == .login ? form.rule.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        defaults.set(profile, forKey: "publish.lastProfile")
        defaults.set(rule ?? "", forKey: PublishForm.ruleKey(for: profile))
        Task { [weak self] in
            await self?.publishBatch(paths: paths, profile: profile, rule: rule, storage: form.storageFlag)
        }
    }

    /// The `publish.rule.<profile>` values for every eligible profile, as `PublishForm`
    /// expects them: the stored rule, or absent for `anyone`.
    private func storedRules(profiles: ProfilesSnapshot) -> [String: String] {
        var rules: [String: String] = [:]
        for name in PublishChoice.eligible(profiles) {
            if let stored = defaults.string(forKey: PublishForm.ruleKey(for: name)), !stored.isEmpty {
                rules[name] = stored
            }
        }
        return rules
    }

    /// One `add` per path, in order, through the mutation queue. The batch stops at the
    /// first `add` that exits non-zero, is stopped with Stop Waiting, or is followed by a
    /// failed re-read; the alert for that event adds `Not published: <names>` for the
    /// paths that never ran.
    @MainActor
    private func publishBatch(paths: [String], profile: String, rule: String?, storage: PublishStorage? = nil) async {
        for (index, path) in paths.enumerated() {
            guard let argv = PublishChoice.args(profile: profile, rule: rule, path: path, storage: storage) else { continue }
            actionLogger.log("add profile=\(profile, privacy: .public) path=\(path, privacy: .private)")
            let unpublished = Array(paths.dropFirst(index + 1))
            let ok = await performMutation(
                argv,
                warningShareID: nil,
                isAdd: true,
                profile: profile,
                notPublished: unpublished.isEmpty ? nil : unpublished.map { ($0 as NSString).lastPathComponent }
            )
            if !ok { return }
        }
    }

    /// Manual-verification-only entry point (`SHAREBAR_DEBUG_ADD_PATHS`, wired in
    /// `AppDelegate`): runs the exact same publish path a real Share File… selection or a
    /// real drop would, so a check can exercise the add/warning/id-diff/checkmark path
    /// deterministically without driving `NSOpenPanel` or a real drag.
    // #if DEBUG: must not exist in a release binary, or the env var alone would let any
    // process trigger an unattended `add` with no user action.
    #if DEBUG
    func debugAddPaths(_ paths: [String]) {
        guard let profiles = currentProfiles, let profile = PublishChoice.eligible(profiles).first else { return }
        Task { [weak self] in await self?.publishBatch(paths: paths, profile: profile, rule: nil, storage: nil) }
    }
    #endif

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Runs one mutating verb through the shared queue: shows the Working header and
    /// (after 60s) offers Stop Waiting while it runs, re-reads `profiles` when it
    /// finishes, and presents whatever alert the combined result calls for. Returns true
    /// only when the verb exited 0 AND the follow-up read succeeded; a batch stops on
    /// false. `@MainActor` because every await here must resume back on the main thread
    /// (it drives `NSAlert` and the menu itself) and every caller is already main-thread.
    @MainActor
    @discardableResult
    private func performMutation(
        _ args: [String],
        warningShareID: String?,
        isAdd: Bool,
        profile: String?,
        notPublished: [String]? = nil
    ) async -> Bool {
        let idsBefore: Set<String> = isAdd ? Set(shares(of: profile).map(\.id)) : []
        beginMutating(gated: args.contains("--access"))
        let result = await mutationQueue.run(args)
        let stateResult = await CLI.profiles(fresh: true)
        var readFailed = false
        if case .failure = ProfilesSnapshot.from(stateResult) { readFailed = true }
        applyResult(stateResult)
        endMutating()
        handleOutcome(
            result: result,
            idsBefore: idsBefore,
            warningShareID: warningShareID,
            isAdd: isAdd,
            profile: profile,
            readFailed: readFailed,
            notPublished: notPublished
        )
        return result.status == 0 && !readFailed
    }

    private func shares(of profile: String?) -> [Share] {
        guard let profile else { return [] }
        return currentProfiles?.profiles.first { $0.name == profile }?.state?.shares ?? []
    }

    private func entry(of profile: String?) -> ProfileEntry? {
        guard let profile else { return nil }
        return currentProfiles?.profiles.first { $0.name == profile }
    }

    private func beginMutating(gated: Bool) {
        working = gated ? .gatedAdd : .plain
        showStopWaitingItem = false
        rebuildModel()
        stopWaitingTimer?.invalidate()
        let timer = Timer(timeInterval: StopWaiting.delay, repeats: false) { [weak self] _ in
            self?.showStopWaitingItem = true
            self?.rebuildModel()
        }
        RunLoop.main.add(timer, forMode: .common)
        stopWaitingTimer = timer
    }

    private func endMutating() {
        working = nil
        showStopWaitingItem = false
        stopWaitingTimer?.invalidate()
        stopWaitingTimer = nil
        rebuildModel()
    }

    /// Decides (via `MutationOutcome`, in `ShareBarCore`) what alert this result calls for,
    /// finds an add's new share id by diffing against `idsBefore` in the target profile,
    /// and, on a successful add, copies its url and flashes the checkmark icon (shared
    /// with the drop target). When `notPublished` is set (a batch stopped midway) the
    /// alert adds the `Not published:` line for the paths that never ran.
    private func handleOutcome(
        result: CLIResult,
        idsBefore: Set<String>,
        warningShareID: String?,
        isAdd: Bool,
        profile: String?,
        readFailed: Bool,
        notPublished: [String]?
    ) {
        var effectiveWarningID = warningShareID
        if isAdd, result.status == 0 {
            if readFailed {
                // The add exited 0 but the fresh re-read failed: the share may be live,
                // its link unknown; the alert names the profile and the `ls` command.
                var alert = MutationAlert(
                    kind: .failure,
                    message: "Published to \(profile ?? ""), but the menu could not refresh; see \(ProfileArgs.commandName(profile ?? "default")) ls"
                )
                alert = appendingNotPublished(notPublished, to: alert)
                present(alert, profile: profile)
                return
            }
            if let state = entry(of: profile)?.state,
               let newShare = MutationOutcome.newShare(before: idsBefore, after: state.shares) {
                effectiveWarningID = newShare.id
                setPasteboard(newShare.url)
                flashCheckmark()
            }
        }
        let notServingHere = isAdd && result.status == 0 && entry(of: profile)?.state?.servesHere == false
        if var alert = MutationOutcome.alert(for: result, warningShareID: effectiveWarningID, notServingHere: notServingHere) {
            alert = appendingNotPublished(notPublished, to: alert)
            present(alert, profile: profile)
        }
    }

    /// Appends `Not published: <names>` to the alert's detail (its own line when there is
    /// no stderr detail to append to).
    private func appendingNotPublished(_ names: [String]?, to alert: MutationAlert) -> MutationAlert {
        guard let names, !names.isEmpty else { return alert }
        let line = "Not published: \(names.joined(separator: ", "))"
        let detail = alert.detail.map { "\($0)\n\(line)" } ?? line
        return MutationAlert(kind: alert.kind, message: alert.message, detail: detail, removeShareID: alert.removeShareID)
    }

    private func present(_ alert: MutationAlert, profile: String?) {
        let nsAlert = NSAlert()
        nsAlert.messageText = alert.message
        nsAlert.alertStyle = alert.kind == .failure ? .warning : .informational
        if let detail = alert.detail {
            // The CLI's guided blocks (O1/O3, the gate timeout) are shown verbatim, as
            // selectable monospaced text inside the alert.
            nsAlert.accessoryView = detailView(detail)
        }
        switch alert.kind {
        case .failure, .notServingHere:
            nsAlert.addButton(withTitle: "OK")
            nsAlert.runModal()
        case .privateWarning:
            nsAlert.addButton(withTitle: "OK")
            let removeButton = nsAlert.addButton(withTitle: "Remove")
            removeButton.hasDestructiveAction = true
            // The remove runs on the profile the verb ran on: share ids repeat across
            // profiles, so a bare id is not enough.
            if nsAlert.runModal() == .alertSecondButtonReturn, let id = alert.removeShareID, let profile {
                actionLogger.log("remove-from-warning profile=\(profile, privacy: .public) id=\(id, privacy: .public)")
                Task { [weak self] in
                    await self?.performMutation(ProfileArgs.remove(profile, id: id), warningShareID: nil, isAdd: false, profile: profile)
                }
            }
        }
    }

    /// A scrollable read-only monospaced view for an alert's stderr detail.
    private func detailView(_ text: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 120))
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 120))
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.string = text
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        return scroll
    }

    /// Swaps in a plain `checkmark` SF Symbol for 1.5s, then restores whatever icon the
    /// current model calls for. Shared by every successful add.
    private func flashCheckmark() {
        guard let button = statusItem.button else { return }
        if let image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Shared") {
            image.isTemplate = true
            button.image = image
            button.title = ""
        }
        checkmarkRevertTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self, let button = self.statusItem.button else { return }
            StatusIcon.apply(self.model.icon, to: button)
        }
        RunLoop.main.add(timer, forMode: .common)
        checkmarkRevertTimer = timer
    }

    // MARK: - Drop target

    /// See `DropView`'s own doc comment for the hitTest/drag spike finding this shape rests
    /// on. Sized and pinned to the button so a drop anywhere on the icon is caught.
    private func installDropView() {
        guard let button = statusItem.button else { return }
        let view = DropView(forwarding: button)
        view.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            view.topAnchor.constraint(equalTo: button.topAnchor),
            view.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        view.onFiles = { [weak self] urls in
            actionLogger.log("drop paths=\(urls.count, privacy: .public)")
            RunLoop.main.perform(inModes: [.common]) {
                self?.presentPublishDialog(paths: urls.map(\.path))
            }
        }
        view.onFilePromise = { [weak self] in
            self?.presentFilePromiseRefused()
        }
        dropView = view
    }

    private func presentFilePromiseRefused() {
        actionLogger.log("drop refused: file promise")
        let alert = NSAlert()
        alert.messageText =
            "Share Bar can't share this drag (Mail, Photos, and similar apps hand over a promise, " +
            "not a file). Save it to disk first, then drop the file."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Lazy hits

    /// Called once when a row's submenu is about to display. Serves a cached line
    /// instantly; otherwise cancels whatever hits call was in flight and starts a new one,
    /// with a 15s timeout enforced on top of `spawnCancellable`'s own cancel path. Rows
    /// are keyed by (profile, id), so the same 6-hex id under two profiles gets two hits
    /// calls with two different argv.
    private func requestHits(profile: String, rowID: String, hitsItem: NSMenuItem) {
        let key = "\(profile)|\(rowID)"
        if let cached = hitsCache[key] {
            hitsItem.title = cached
            return
        }

        cancelHits()
        hitsGeneration += 1
        let generation = hitsGeneration
        currentHitsKey = key

        actionLogger.log("hits spawn profile=\(profile, privacy: .public) id=\(rowID, privacy: .public)")
        let job = CLI.spawnCancellable(ProfileArgs.hits(profile, id: rowID)) { _ in }
        currentHitsJob = job

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            job.cancel()
        }

        // Boxed so the Sendable check on the crossing into the detached Task below doesn't
        // complain about carrying an NSMenuItem; it is only ever read or written back on
        // the main thread, inside the RunLoop.main.perform block, same as `self`'s own
        // mutable state (see the class-level @unchecked Sendable note).
        let boxedHitsItem = UncheckedBox(hitsItem)

        Task { [weak self] in
            let result = await job.result
            timeoutTask.cancel()
            guard let self else { return }
            let line = result.hitsText
            RunLoop.main.perform(inModes: [.common]) {
                // A superseded generation means this row's call was cancelled (the user
                // opened another submenu, or the top menu closed): the process was killed
                // mid-flight, so its output is not a real hits line and must not be cached
                // or shown.
                guard self.hitsGeneration == generation else { return }
                self.hitsCache[key] = line
                self.currentHitsJob = nil
                self.currentHitsKey = nil
                boxedHitsItem.value.title = line
            }
        }
    }

    private func cancelHits() {
        guard let job = currentHitsJob else { return }
        if let key = currentHitsKey {
            actionLogger.log("hits cancelled key=\(key, privacy: .public)")
        }
        job.cancel()
        currentHitsJob = nil
        currentHitsKey = nil
    }

    // MARK: - Other actions

    /// Set Up… for one existing profile: the setup window runs `--profile <p> setup` and
    /// its hostname field is prefilled from the section (empty when `not_setup`), because
    /// rerunning setup is the recovery for a half-finished one.
    @objc private func setUp(_ sender: NSMenuItem) {
        guard let section = sender.representedObject as? Section else { return }
        actionLogger.log("set-up requested profile=\(section.profile, privacy: .public)")
        SetupWindowController.show(profile: section.profile, host: section.host) { [weak self] in
            self?.triggerRefresh(fresh: true)
        }
    }

    @objc private func copyInstallCommand() {
        actionLogger.log("copy-install-command")
        setPasteboard("brew install dwarvesf/tools/share")
    }

    @objc private func copyUpgradeCommand() {
        actionLogger.log("copy-upgrade-command")
        setPasteboard("brew upgrade dwarvesf/tools/share")
    }

    @objc private func toggleOpenAtLogin() {
        let status = SMAppService.mainApp.status
        actionLogger.log("open-at-login toggled; status=\(String(describing: status), privacy: .public)")
        if status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        do {
            if status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            actionLogger.error("open-at-login toggle failed: \(String(describing: error), privacy: .public)")
        }
        applyModel() // re-reads status immediately so the checkmark reflects the new state
    }

    /// `.accessory` apps don't get frontmost focus for free, so the panel needs an explicit
    /// activate before `orderFrontStandardAboutPanel` or it can show up behind other windows.
    @objc private func aboutShareBar() {
        actionLogger.log("about")
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        actionLogger.log("quit")
        NSApp.terminate(nil)
    }

    private func setPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// A label plus control in one horizontal row of the dialog accessory view.
    private func labeledRow(_ label: String, _ control: NSView) -> NSStackView {
        let labelField = NSTextField(labelWithString: label)
        labelField.alignment = .right
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let row = NSStackView(views: [labelField, control])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }
}

extension StatusItemController: NSMenuDelegate {
    /// Called right before the menu displays (every open); the menu already shows the
    /// cached snapshot instantly, this just kicks a fresh `profiles` call whose result
    /// replaces the items in place if it lands while the menu is still open. Row submenus
    /// get their own delegate callback (`menuWillOpen`, below), not this one.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        // Cleared on open as well because menuDidClose is not guaranteed to fire for every close path.
        cancelHits()
        hitsCache.removeAll()
        triggerRefresh()
    }

    /// Fires once per row submenu open; kicks the lazy `hits` call for that row.
    func menuWillOpen(_ menu: NSMenu) {
        guard let rowMenu = menu as? RowMenu else { return }
        requestHits(profile: rowMenu.profile, rowID: rowMenu.rowID, hitsItem: rowMenu.hitsItem)
    }

    /// The top-level menu closing is the cache boundary the spec names ("cached until the
    /// menu closes"); a row submenu closing on its own (the user hovering to another row)
    /// must not clear it.
    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        cancelHits()
        hitsCache.removeAll()
    }
}

/// Holds the publish dialog's `PublishForm` while it is open: the popup and field targets
/// mutate it and re-sync the accessory view after every change. ObjC targets need a
/// class, hence this little box rather than the value-type form itself.
private final class AlertForm: NSObject, NSTextFieldDelegate, @unchecked Sendable {
    var form: PublishForm
    private let sync: (PublishForm) -> Void
    private weak var ruleField: NSTextField?

    init(form: PublishForm, sync: @escaping (PublishForm) -> Void, ruleField: NSTextField) {
        self.form = form
        self.sync = sync
        self.ruleField = ruleField
    }

    @objc func profileChanged(_ sender: NSPopUpButton) {
        guard let name = sender.selectedItem?.representedObject as? String else { return }
        form.select(profile: name)
        resync()
    }

    @objc func audienceChanged(_ sender: NSPopUpButton) {
        form.choose(sender.indexOfSelectedItem == 1 ? .login : .anyone)
        resync()
    }

    @objc func storageChanged(_ sender: NSPopUpButton) {
        form.choose(storage: sender.indexOfSelectedItem == 1 ? .cloud : .local)
        resync()
    }

    @objc func ruleEdited(_ sender: NSTextField) {
        form.rule = sender.stringValue
        resync()
    }

    /// Every keystroke in the rule field: Publish enables as soon as the rule is well
    /// formed, without waiting for Return.
    func controlTextDidChange(_ obj: Notification) {
        resync()
    }

    /// Called on every control change so the final field text (edited but never
    /// action-fired) is in the form.
    private func resync() {
        if let field = ruleField {
            form.rule = field.stringValue
        }
        sync(form)
    }
}
