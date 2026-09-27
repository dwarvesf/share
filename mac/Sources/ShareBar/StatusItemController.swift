import AppKit
import ServiceManagement
import ShareBarCore

/// Owns the status item and its menu: builds a plain `NSMenu` from the latest `MenuModel`,
/// keeps it current on a 60s timer, on wake, and on every open, and applies the icon.
///
/// Rendering only (TASK-008). Every action here is a no-op or a disabled item per the model's
/// flags; Copy Link, Open, hits, Set Up, Start/Stop, Remove, Share File, and Open at Login
/// registration are wired for real in TASK-009/017. Quit is the one action that must work now.
// @unchecked Sendable: every mutable property is only ever touched on the main thread (init,
// or a block scheduled through `RunLoop.main.perform(inModes:)`); this just tells the
// compiler what's already true so the refresh closure doesn't need a warning suppressed
// some other way.
final class StatusItemController: NSObject, @unchecked Sendable {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var model = MenuModel(snapshot: nil, failure: nil, now: Date())
    private var isRefreshing = false
    private var pollTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        // Renders the "Not set up" placeholder instantly so the item never opens empty; the
        // first real `state` call (kicked off below) replaces it in place when it returns.
        applyModel()
        startPolling()
        observeWake()
        triggerRefresh()
    }

    deinit {
        pollTimer?.invalidate()
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

    /// Runs `share state`, then applies the result on the main run loop in common modes, so
    /// an already-open menu still updates in place. Concurrent triggers collapse to the
    /// `state` call already in flight (`CLI.state()` coalesces); this guard just skips
    /// spawning a second `MenuModel` rebuild on top of one already pending.
    private func triggerRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { [weak self] in
            let result = await CLI.state()
            guard let self else { return }
            let snapshot: Snapshot?
            let failure: Failure?
            switch Snapshot.from(result) {
            case .success(let value):
                snapshot = value
                failure = nil
            case .failure(let value):
                snapshot = nil
                failure = value
            }
            let newModel = MenuModel(snapshot: snapshot, failure: failure, now: Date())
            RunLoop.main.perform(inModes: [.common]) {
                self.model = newModel
                self.isRefreshing = false
                self.applyModel()
            }
        }
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

        for row in model.rows {
            let item = NSMenuItem(title: rowTitle(row), action: nil, keyEquivalent: "")
            item.submenu = submenu(for: row)
            menu.addItem(item)
        }

        if model.more > 0 {
            let moreItem = NSMenuItem(title: "\(model.more) more (share ls)", action: nil, keyEquivalent: "")
            moreItem.isEnabled = false
            menu.addItem(moreItem)
        }

        menu.addItem(.separator())

        menu.addItem(actionItem("Share File…", keyEquivalent: "n"))

        if model.showStop {
            menu.addItem(actionItem("Stop Sharing"))
        } else if model.showStart {
            menu.addItem(actionItem("Start Sharing"))
        }

        menu.addItem(.separator())

        if model.showSetUp {
            menu.addItem(actionItem("Set Up…"))
        }
        if model.showCopyInstallCommand {
            menu.addItem(actionItem("Copy Install Command"))
        }

        menu.addItem(openAtLoginItem())

        let quitItem = NSMenuItem(title: "Quit Share Bar", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func rowTitle(_ row: Row) -> String {
        "\(row.title)    \(row.trailing)"
    }

    private func submenu(for row: Row) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let copyItem = actionItem("Copy Link")
        copyItem.isEnabled = row.canCopy
        submenu.addItem(copyItem)

        let openItem = actionItem("Open in Browser")
        openItem.isEnabled = row.canCopy
        submenu.addItem(openItem)

        let refreshItem = actionItem("Refresh")
        refreshItem.isEnabled = row.canRefresh
        submenu.addItem(refreshItem)

        let hitsItem = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
        hitsItem.isEnabled = false
        submenu.addItem(hitsItem)

        submenu.addItem(.separator())
        submenu.addItem(actionItem("Remove…"))

        return submenu
    }

    /// Reads (never registers) `SMAppService.mainApp.status` so the checkmark and the
    /// "approve in System Settings" wording render correctly before TASK-009 wires the
    /// toggle and the Login Items deep link.
    private func openAtLoginItem() -> NSMenuItem {
        let status = SMAppService.mainApp.status
        let title = status == .requiresApproval
            ? "Open at Login (approve in System Settings)"
            : "Open at Login"
        let item = actionItem(title)
        item.state = status == .enabled ? .on : .off
        return item
    }

    private func actionItem(_ title: String, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(noOp), keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func noOp() {}

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension StatusItemController: NSMenuDelegate {
    /// Called right before the menu displays (every open); the menu already shows the
    /// cached snapshot instantly, this just kicks a fresh `state` call whose result replaces
    /// the items in place if it lands while the menu is still open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        triggerRefresh()
    }
}
