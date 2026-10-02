//
//  AppDelegate.swift
//  goofy
//
//  Created by Daniel Büchele on 02/01/2026.
//  Speed-trim: no global hotkeys, no Always-on-Top / Hide Dock / chat-only /
//  typing-seen hooks. Menu bar opt-in (default off). AppUpdater delayed.
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
    private var updateCheckWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let window = NSApplication.shared.windows.first {
            window.delegate = self
            window.setFrameAutosaveName("MainWindow")
        }

        Self.appUpdater.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if case .downloaded(let release, _, let bundle) = state {
                    self?.showUpdateAlert(version: release.tagName.description, bundle: bundle)
                }
            }
            .store(in: &cancellables)

        // Delay auto-update network/CPU off the launch hot path.
        let work = DispatchWorkItem {
            Self.appUpdater.check()
        }
        updateCheckWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: work)

        // Notification permission is requested once in ViewController.setupNotifications.

        setupProgrammaticMenus()
        updateStatusItem()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(badgeDidChange(_:)),
            name: .goofyBadgeDidChange,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateCheckWorkItem?.cancel()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        // Tell web content to pause observers while window is hidden.
        viewController()?.notifyWindowVisibility(false)
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        viewController()?.notifyWindowVisibility(true)
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
        for window in NSApplication.shared.windows {
            if window.isMiniaturized {
                window.deminiaturize(self)
            }
            window.makeKeyAndOrderFront(self)
        }
        viewController()?.notifyWindowVisibility(true)
    }

    @objc func toggleMainWindow() {
        guard let window = mainWindow() else {
            showMainWindow()
            return
        }
        if window.isVisible && NSApp.isActive {
            window.orderOut(nil)
            viewController()?.notifyWindowVisibility(false)
        } else {
            showMainWindow()
        }
    }

    // MARK: - Status item (opt-in, default off)

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
        toggleMainWindow()
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Goofy", action: #selector(showMainWindow), keyEquivalent: "")
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
        guard statusItem != nil else { return }
        let count = notification.userInfo?["count"] as? Int ?? 0
        guard let button = statusItem?.button else { return }
        if count > 0 {
            button.title = count > 99 ? "99+" : "\(count)"
        } else {
            button.title = "💬"
        }
    }

    // MARK: - Programmatic menus

    private func setupProgrammaticMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }

        if let appMenu = mainMenu.items.first?.submenu {
            if appMenu.item(withTitle: "Preferences…") == nil
                && appMenu.item(withTitle: "Settings…") == nil
            {
                let prefs = NSMenuItem(
                    title: "Preferences…", action: #selector(showPreferences(_:)),
                    keyEquivalent: ",")
                prefs.target = self
                let insertIndex = min(1, appMenu.items.count)
                appMenu.insertItem(prefs, at: insertIndex)
                appMenu.insertItem(NSMenuItem.separator(), at: insertIndex + 1)
            }
        }

        let extras = NSMenu(title: "Goofy")
        extras.addItem(
            makeCheckItem("Menu Bar Icon", #selector(toggleMenuBar(_:)), GoofySettings.menuBarEnabled))
        extras.addItem(
            makeCheckItem(
                "Hide Notification Preview", #selector(toggleHidePreview(_:)),
                GoofySettings.hidePreview))
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
                case "Menu Bar Icon":
                    item.state = GoofySettings.menuBarEnabled ? .on : .off
                case "Hide Notification Preview":
                    item.state = GoofySettings.hidePreview ? .on : .off
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
        if GoofySettings.menuBarEnabled {
            statusItem?.menu = buildStatusMenu()
        }
    }

    // MARK: - Actions

    @objc func toggleMenuBar(_ sender: Any?) {
        GoofySettings.menuBarEnabled.toggle()
        updateStatusItem()
        refreshCheckStates()
    }

    @objc func toggleHidePreview(_ sender: Any?) {
        GoofySettings.hidePreview.toggle()
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
        let alert = NSAlert()
        alert.messageText = "Goofy Preferences"
        alert.informativeText =
            "Notification options. Menu bar icon is off by default to save idle work."
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
            ("Menu Bar Icon", GoofySettings.menuBarEnabled, #selector(toggleMenuBar(_:))),
        ]

        for (title, on, action) in toggles {
            let button = NSButton(checkboxWithTitle: title, target: self, action: action)
            button.state = on ? .on : .off
            stack.addArrangedSubview(button)
        }

        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 140)
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
        updateCheckWorkItem?.cancel()
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
