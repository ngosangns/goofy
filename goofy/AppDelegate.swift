//
//  AppDelegate.swift
//  goofy
//
//  Created by Daniel Büchele on 02/01/2026.
//

import AppUpdater
import Cocoa
import Combine
import UserNotifications
internal import Version

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    // Point updater at this fork so upstream releases do not overwrite local install.
    static let appUpdater = AppUpdater(
        owner: "ngosangns", repo: "goofy", releasePrefix: "Goofy")

    private var cancellables = Set<AnyCancellable>()
    private var statusItem: NSStatusItem?
    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?
    private weak var preferencesWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let window = NSApplication.shared.windows.first {
            window.delegate = self
            window.setFrameAutosaveName("MainWindow")
            applyAlwaysOnTop(GoofySettings.alwaysOnTop, window: window)
        }

        Self.appUpdater.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                print("[AutoUpdater] State changed: \(state)")
                if case .downloaded(let release, _, let bundle) = state {
                    self?.showUpdateAlert(version: release.tagName.description, bundle: bundle)
                }
            }
            .store(in: &cancellables)

        Self.appUpdater.check()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
            granted, error in
            if let error = error {
                print("Notification authorization error: \(error)")
            }
        }

        setupProgrammaticMenus()
        applyDockVisibility()
        updateStatusItem()
        registerHotkeys()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(badgeDidChange(_:)),
            name: .goofyBadgeDidChange,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let globalHotkeyMonitor {
            NSEvent.removeMonitor(globalHotkeyMonitor)
        }
        if let localHotkeyMonitor {
            NSEvent.removeMonitor(localHotkeyMonitor)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.toolbar = nil
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let toolbar = NSToolbar(identifier: "MainToolbar")
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        showMainWindow()
        return true
    }

    // MARK: - Window helpers

    func mainWindow() -> NSWindow? {
        NSApplication.shared.windows.first { $0.contentViewController is ViewController }
            ?? NSApplication.shared.windows.first
    }

    func viewController() -> ViewController? {
        mainWindow()?.contentViewController as? ViewController
    }

    @objc func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if GoofySettings.hideDock {
            NSApp.setActivationPolicy(.regular)
            // Keep hideDock preference; temporarily show in Dock while visible if needed —
            // actually Caprine-style keeps accessory always. Just front the window.
            NSApp.setActivationPolicy(.accessory)
        }
        for window in NSApplication.shared.windows {
            if window.isMiniaturized {
                window.deminiaturize(self)
            }
            window.makeKeyAndOrderFront(self)
        }
    }

    @objc func toggleMainWindow() {
        guard let window = mainWindow() else {
            showMainWindow()
            return
        }
        if window.isVisible && NSApp.isActive {
            window.orderOut(nil)
        } else {
            showMainWindow()
        }
    }

    private func applyAlwaysOnTop(_ enabled: Bool, window: NSWindow? = nil) {
        let win = window ?? mainWindow()
        win?.level = enabled ? .floating : .normal
    }

    private func applyDockVisibility() {
        if GoofySettings.hideDock {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    // MARK: - Status item

    private func updateStatusItem() {
        if GoofySettings.menuBarEnabled {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let button = item.button {
                    button.title = "💬"
                    button.toolTip = "Goofy"
                    button.action = #selector(statusItemClicked(_:))
                    button.target = self
                    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                }
                item.menu = buildStatusMenu()
                statusItem = item
            } else {
                statusItem?.menu = buildStatusMenu()
            }
        } else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        // Menu handles right-click via statusItem.menu; left click also shows menu by default.
        // Extra: if we want toggle on left without menu delay, handle here.
        toggleMainWindow()
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Goofy", action: #selector(showMainWindow), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        let always = NSMenuItem(
            title: "Always on Top", action: #selector(toggleAlwaysOnTop(_:)), keyEquivalent: "")
        always.state = GoofySettings.alwaysOnTop ? .on : .off
        always.target = self
        menu.addItem(always)

        let chatOnly = NSMenuItem(
            title: "Chat Only Mode", action: #selector(toggleChatOnly(_:)), keyEquivalent: "")
        chatOnly.state = GoofySettings.chatOnly ? .on : .off
        chatOnly.target = self
        menu.addItem(chatOnly)

        let hideDock = NSMenuItem(
            title: "Hide Dock Icon", action: #selector(toggleHideDock(_:)), keyEquivalent: "")
        hideDock.state = GoofySettings.hideDock ? .on : .off
        hideDock.target = self
        menu.addItem(hideDock)

        menu.addItem(NSMenuItem.separator())
        let prefs = NSMenuItem(
            title: "Preferences…", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        prefs.keyEquivalentModifierMask = [.command]
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: "Quit Goofy", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        return menu
    }

    @objc private func badgeDidChange(_ notification: Notification) {
        let count = notification.userInfo?["count"] as? Int ?? 0
        guard let button = statusItem?.button else { return }
        if count > 0 {
            button.title = count > 99 ? "99+" : "\(count)"
        } else {
            button.title = "💬"
        }
    }

    // MARK: - Hotkeys ⌘⇧Y

    private func registerHotkeys() {
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.isToggleHotkey(event) == true {
                self?.toggleMainWindow()
                return nil
            }
            return event
        }
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.isToggleHotkey(event) == true {
                DispatchQueue.main.async {
                    self?.toggleMainWindow()
                }
            }
        }
    }

    private func isToggleHotkey(_ event: NSEvent) -> Bool {
        // ⌘⇧Y
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return flags == [.command, .shift]
            && (event.charactersIgnoringModifiers?.lowercased() == "y")
    }

    // MARK: - Programmatic menus

    private func setupProgrammaticMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }

        // Find or create Goofy app menu (first menu)
        if let appMenu = mainMenu.items.first?.submenu {
            // Insert Preferences if missing
            if appMenu.item(withTitle: "Preferences…") == nil
                && appMenu.item(withTitle: "Settings…") == nil
            {
                let prefs = NSMenuItem(
                    title: "Preferences…", action: #selector(showPreferences(_:)),
                    keyEquivalent: ",")
                prefs.target = self
                // Insert after About if present, else at top
                let insertIndex = min(1, appMenu.items.count)
                appMenu.insertItem(prefs, at: insertIndex)
                appMenu.insertItem(NSMenuItem.separator(), at: insertIndex + 1)
            }
        }

        // Window menu: Always on Top
        if let windowMenuItem = mainMenu.items.first(where: { $0.title == "Window" }),
            let windowMenu = windowMenuItem.submenu
        {
            if windowMenu.item(withTitle: "Always on Top") == nil {
                let item = NSMenuItem(
                    title: "Always on Top", action: #selector(toggleAlwaysOnTop(_:)),
                    keyEquivalent: "")
                item.target = self
                item.state = GoofySettings.alwaysOnTop ? .on : .off
                windowMenu.insertItem(item, at: 0)
                windowMenu.insertItem(NSMenuItem.separator(), at: 1)
            }
        }

        // Goofy / View extras: notification + privacy toggles + thread jump
        let extras = NSMenu(title: "Goofy")
        extras.addItem(makeCheckItem("Always on Top", #selector(toggleAlwaysOnTop(_:)), GoofySettings.alwaysOnTop))
        extras.addItem(makeCheckItem("Menu Bar Icon", #selector(toggleMenuBar(_:)), GoofySettings.menuBarEnabled))
        extras.addItem(makeCheckItem("Hide Dock Icon", #selector(toggleHideDock(_:)), GoofySettings.hideDock))
        extras.addItem(makeCheckItem("Chat Only Mode", #selector(toggleChatOnly(_:)), GoofySettings.chatOnly))
        extras.addItem(NSMenuItem.separator())
        extras.addItem(makeCheckItem("Hide Notification Preview", #selector(toggleHidePreview(_:)), GoofySettings.hidePreview))
        extras.addItem(makeCheckItem("Block Typing Indicator", #selector(toggleBlockTyping(_:)), GoofySettings.blockTyping))
        extras.addItem(makeCheckItem("Block Seen Receipts", #selector(toggleBlockSeen(_:)), GoofySettings.blockSeen))
        extras.addItem(NSMenuItem.separator())

        let notiMenu = NSMenu(title: "Notifications")
        for mode in GoofySettings.NotificationMode.allCases {
            let item = NSMenuItem(
                title: mode.displayName, action: #selector(setNotificationMode(_:)),
                keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.target = self
            item.state = GoofySettings.notificationMode == mode ? .on : .off
            notiMenu.addItem(item)
        }
        let notiItem = NSMenuItem(title: "Notifications", action: nil, keyEquivalent: "")
        notiItem.submenu = notiMenu
        extras.addItem(notiItem)

        extras.addItem(NSMenuItem.separator())
        extras.addItem(
            withTitle: "Preferences…", action: #selector(showPreferences(_:)), keyEquivalent: "")

        // Thread navigation
        let nav = NSMenu(title: "Conversation")
        for i in 1...9 {
            let item = NSMenuItem(
                title: "Jump to Conversation \(i)",
                action: #selector(jumpToThread(_:)),
                keyEquivalent: "\(i)")
            item.keyEquivalentModifierMask = [.command]
            item.tag = i - 1
            item.target = self
            nav.addItem(item)
        }
        nav.addItem(NSMenuItem.separator())
        let prev = NSMenuItem(
            title: "Previous Conversation", action: #selector(prevThread(_:)), keyEquivalent: "[")
        prev.keyEquivalentModifierMask = [.command]
        prev.target = self
        nav.addItem(prev)
        let next = NSMenuItem(
            title: "Next Conversation", action: #selector(nextThread(_:)), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command]
        next.target = self
        nav.addItem(next)

        // Insert Goofy menu before Help if present
        let goofyItem = NSMenuItem(title: "Goofy", action: nil, keyEquivalent: "")
        goofyItem.submenu = extras
        let convItem = NSMenuItem(title: "Conversation", action: nil, keyEquivalent: "")
        convItem.submenu = nav

        if let helpIndex = mainMenu.items.firstIndex(where: { $0.title == "Help" }) {
            mainMenu.insertItem(goofyItem, at: helpIndex)
            mainMenu.insertItem(convItem, at: helpIndex + 1)
        } else {
            mainMenu.addItem(goofyItem)
            mainMenu.addItem(convItem)
        }
    }

    private func makeCheckItem(_ title: String, _ action: Selector, _ on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    private func refreshCheckStates() {
        func walk(_ menu: NSMenu?) {
            guard let menu else { return }
            for item in menu.items {
                switch item.title {
                case "Always on Top":
                    item.state = GoofySettings.alwaysOnTop ? .on : .off
                case "Menu Bar Icon":
                    item.state = GoofySettings.menuBarEnabled ? .on : .off
                case "Hide Dock Icon":
                    item.state = GoofySettings.hideDock ? .on : .off
                case "Chat Only Mode":
                    item.state = GoofySettings.chatOnly ? .on : .off
                case "Hide Notification Preview":
                    item.state = GoofySettings.hidePreview ? .on : .off
                case "Block Typing Indicator":
                    item.state = GoofySettings.blockTyping ? .on : .off
                case "Block Seen Receipts":
                    item.state = GoofySettings.blockSeen ? .on : .off
                case "Banner", "Badge only", "Off":
                    if let raw = item.representedObject as? String {
                        item.state = GoofySettings.notificationMode.rawValue == raw ? .on : .off
                    }
                default:
                    break
                }
                walk(item.submenu)
            }
        }
        walk(NSApp.mainMenu)
        statusItem?.menu = buildStatusMenu()
    }

    // MARK: - Actions

    @objc func toggleAlwaysOnTop(_ sender: Any?) {
        GoofySettings.alwaysOnTop.toggle()
        applyAlwaysOnTop(GoofySettings.alwaysOnTop)
        refreshCheckStates()
    }

    @objc func toggleMenuBar(_ sender: Any?) {
        GoofySettings.menuBarEnabled.toggle()
        updateStatusItem()
        refreshCheckStates()
    }

    @objc func toggleHideDock(_ sender: Any?) {
        GoofySettings.hideDock.toggle()
        applyDockVisibility()
        refreshCheckStates()
        if GoofySettings.hideDock {
            // Ensure status item exists so user can quit / show
            if !GoofySettings.menuBarEnabled {
                GoofySettings.menuBarEnabled = true
                updateStatusItem()
            }
        }
    }

    @objc func toggleChatOnly(_ sender: Any?) {
        GoofySettings.chatOnly.toggle()
        viewController()?.applyChatOnlyPreference()
        refreshCheckStates()
    }

    @objc func toggleHidePreview(_ sender: Any?) {
        GoofySettings.hidePreview.toggle()
        refreshCheckStates()
    }

    @objc func toggleBlockTyping(_ sender: Any?) {
        GoofySettings.blockTyping.toggle()
        viewController()?.applyPrivacyPreferences()
        refreshCheckStates()
    }

    @objc func toggleBlockSeen(_ sender: Any?) {
        GoofySettings.blockSeen.toggle()
        viewController()?.applyPrivacyPreferences()
        refreshCheckStates()
    }

    @objc func setNotificationMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let mode = GoofySettings.NotificationMode(rawValue: raw)
        else { return }
        GoofySettings.notificationMode = mode
        refreshCheckStates()
    }

    @objc func jumpToThread(_ sender: NSMenuItem) {
        viewController()?.jumpToThread(index: sender.tag)
    }

    @objc func prevThread(_ sender: Any?) {
        viewController()?.prevThread()
    }

    @objc func nextThread(_ sender: Any?) {
        viewController()?.nextThread()
    }

    @objc func showPreferences(_ sender: Any?) {
        if let preferencesWindow, preferencesWindow.isVisible {
            preferencesWindow.makeKeyAndOrderFront(nil)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Goofy Preferences"
        alert.informativeText =
            "Notification mode, privacy, and window options. Changes apply immediately."
        alert.alertStyle = .informational

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modePopup.addItems(withTitles: GoofySettings.NotificationMode.allCases.map(\.displayName))
        if let idx = GoofySettings.NotificationMode.allCases.firstIndex(
            of: GoofySettings.notificationMode)
        {
            modePopup.selectItem(at: idx)
        }
        modePopup.target = self
        modePopup.action = #selector(prefsModeChanged(_:))

        func labeled(_ title: String, _ view: NSView) -> NSStackView {
            let row = NSStackView(views: [NSTextField(labelWithString: title), view])
            row.orientation = .horizontal
            row.spacing = 8
            return row
        }

        stack.addArrangedSubview(labeled("Notifications:", modePopup))

        let toggles: [(String, Bool, Selector)] = [
            ("Hide message preview", GoofySettings.hidePreview, #selector(toggleHidePreview(_:))),
            ("Always on Top", GoofySettings.alwaysOnTop, #selector(toggleAlwaysOnTop(_:))),
            ("Menu Bar Icon", GoofySettings.menuBarEnabled, #selector(toggleMenuBar(_:))),
            ("Hide Dock Icon", GoofySettings.hideDock, #selector(toggleHideDock(_:))),
            ("Chat Only Mode", GoofySettings.chatOnly, #selector(toggleChatOnly(_:))),
            ("Block Typing Indicator", GoofySettings.blockTyping, #selector(toggleBlockTyping(_:))),
            ("Block Seen Receipts", GoofySettings.blockSeen, #selector(toggleBlockSeen(_:))),
        ]

        for (title, on, action) in toggles {
            let button = NSButton(checkboxWithTitle: title, target: self, action: action)
            button.state = on ? .on : .off
            stack.addArrangedSubview(button)
        }

        let note = NSTextField(
            wrappingLabelWithString:
                "Hide Dock: quit from menu bar or Goofy ▸ Quit. Block typing/seen is experimental and may break."
        )
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)

        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 260)
        alert.accessoryView = stack
        alert.addButton(withTitle: "OK")
        alert.runModal()
        refreshCheckStates()
    }

    @objc private func prefsModeChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        let modes = GoofySettings.NotificationMode.allCases
        guard idx >= 0, idx < modes.count else { return }
        GoofySettings.notificationMode = modes[idx]
        refreshCheckStates()
    }

    private func showUpdateAlert(version: String, bundle: Bundle) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText =
            "A new version (\(version)) of Goofy is ready to install. The app will restart after updating."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install & Restart")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Self.appUpdater.install(bundle)
        }
    }

    @IBAction func openGitHub(_ sender: Any?) {
        if let url = URL(string: "https://github.com/ngosangns/goofy") {
            NSWorkspace.shared.open(url)
        }
    }

    @IBAction func checkForUpdates(_ sender: Any?) {
        Self.appUpdater.check(
            success: {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "No Update Available"
                    alert.informativeText = "You're running the latest version of Goofy."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            },
            fail: { error in
                if case AUError.cancelled = error {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "No Update Available"
                        alert.informativeText = "You're running the latest version of Goofy."
                        alert.alertStyle = .informational
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                    return
                }
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Update Check Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        )
    }
}

extension Notification.Name {
    static let goofyBadgeDidChange = Notification.Name("goofyBadgeDidChange")
}
