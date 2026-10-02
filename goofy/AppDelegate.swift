//
//  AppDelegate.swift
//  goofy
//
//  Created by Daniel Büchele on 02/01/2026.
//  Warm-UX + smooth-cache: large URLCache; keep-process-warm; badge/noti warm;
//  Always on Top + ⌘⇧Y; suspendWhenHidden still opt-in.
//  Upstream ports: keep-alive (#524), reopen harden (#520).
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
    private var updaterSubscribed = false
    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?
    private var keepWarmActivity: NSObjectProtocol?
    /// Strong ref so close/minimize cycles cannot drop the only window (#520).
    private var retainedMainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateKeepWarmActivity()
        if let window = NSApplication.shared.windows.first {
            retainedMainWindow = window
            window.delegate = self
            window.setFrameAutosaveName("MainWindow")
            window.isReleasedWhenClosed = false
            applyAlwaysOnTop(GoofySettings.alwaysOnTop, window: window)
        }

        // Delay AppUpdater subscription + network check off the launch hot path.
        let work = DispatchWorkItem { [weak self] in
            self?.ensureUpdaterSubscribed()
            Self.appUpdater.check()
        }
        updateCheckWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: work)

        // Notification permission is requested once in ViewController.setupNotifications.

        setupProgrammaticMenus()
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
        updateCheckWorkItem?.cancel()
        endKeepWarmActivity()
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
        // orderOut keeps the window + WKWebView in memory (instant reopen).
        // Do not removeFromSuperview / do not clear website data here.
        // Deminiaturize first — orderOut of a miniaturized window is a Sequoia
        // footgun that can leave the Dock unable to restore (#520).
        if sender.isMiniaturized {
            sender.deminiaturize(nil)
        }
        retainedMainWindow = sender
        sender.isReleasedWhenClosed = false
        sender.orderOut(nil)
        viewController()?.notifyWindowVisibility(false)
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        viewController()?.notifyWindowVisibility(true)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            retainedMainWindow = window
        }
        viewController()?.notifyWindowVisibility(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            retainedMainWindow = window
        }
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
        if let retainedMainWindow,
           retainedMainWindow.contentViewController is ViewController {
            return retainedMainWindow
        }
        let found = NSApplication.shared.windows.first { $0.contentViewController is ViewController }
            ?? NSApplication.shared.windows.first
        if let found {
            retainedMainWindow = found
            found.isReleasedWhenClosed = false
            found.delegate = self
        }
        return found
    }

    func viewController() -> ViewController? {
        mainWindow()?.contentViewController as? ViewController
    }

    @objc func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = mainWindow() else {
            // Last resort: any app window.
            NSApplication.shared.windows.forEach { $0.makeKeyAndOrderFront(self) }
            return
        }
        retainedMainWindow = window
        window.isReleasedWhenClosed = false
        if window.delegate == nil {
            window.delegate = self
        }
        if window.isMiniaturized {
            window.deminiaturize(self)
        }
        // Force on-screen even after repeated orderOut / minimize cycles (#520).
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            var frame = window.frame
            if !screen.visibleFrame.intersects(frame) {
                frame.origin = NSPoint(
                    x: screen.visibleFrame.midX - frame.width / 2,
                    y: screen.visibleFrame.midY - frame.height / 2
                )
                window.setFrame(frame, display: true)
            }
        }
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.makeKeyAndOrderFront(self)
        if !window.isVisible {
            window.orderFrontRegardless()
        }
        viewController()?.notifyWindowVisibility(true)
    }

    @objc func toggleMainWindow() {
        guard let window = mainWindow() else {
            showMainWindow()
            return
        }
        let reallyVisible = window.isVisible && !window.isMiniaturized && NSApp.isActive
        if reallyVisible {
            window.orderOut(nil)
            viewController()?.notifyWindowVisibility(false)
        } else {
            showMainWindow()
        }
    }

    private func applyAlwaysOnTop(_ enabled: Bool, window: NSWindow? = nil) {
        let win = window ?? mainWindow()
        win?.level = enabled ? .floating : .normal
    }

    // MARK: - Hotkeys ⌘⇧Y (show/hide)

    private func registerHotkeys() {
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if self?.isToggleHotkey(event) == true {
                self?.toggleMainWindow()
                return nil
            }
            return event
        }
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if self?.isToggleHotkey(event) == true {
                DispatchQueue.main.async {
                    self?.toggleMainWindow()
                }
            }
        }
    }

    private func isToggleHotkey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return flags == [.command, .shift]
            && (event.charactersIgnoringModifiers?.lowercased() == "y")
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
        let always = NSMenuItem(
            title: "Always on Top", action: #selector(toggleAlwaysOnTop(_:)), keyEquivalent: "")
        always.state = GoofySettings.alwaysOnTop ? .on : .off
        always.target = self
        menu.addItem(always)
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

        let extras = NSMenu(title: "Goofy")
        let showHide = NSMenuItem(
            title: "Show/Hide Window", action: #selector(toggleMainWindow), keyEquivalent: "y")
        showHide.keyEquivalentModifierMask = [.command, .shift]
        showHide.target = self
        extras.addItem(showHide)
        extras.addItem(
            makeCheckItem("Always on Top", #selector(toggleAlwaysOnTop(_:)), GoofySettings.alwaysOnTop))
        extras.addItem(
            makeCheckItem("Menu Bar Icon", #selector(toggleMenuBar(_:)), GoofySettings.menuBarEnabled))
        extras.addItem(
            makeCheckItem(
                "Hide Notification Preview", #selector(toggleHidePreview(_:)),
                GoofySettings.hidePreview))
        extras.addItem(
            makeCheckItem(
                "Force Reduce Motion", #selector(toggleForceReduceMotion(_:)),
                GoofySettings.forceReduceMotion))
        extras.addItem(
            makeCheckItem(
                "Suspend When Hidden", #selector(toggleSuspendWhenHidden(_:)),
                GoofySettings.suspendWhenHidden))
        extras.addItem(
            makeCheckItem(
                "Keep Process Warm", #selector(toggleKeepProcessWarm(_:)),
                GoofySettings.keepProcessWarm))
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
                case "Always on Top":
                    item.state = GoofySettings.alwaysOnTop ? .on : .off
                case "Menu Bar Icon":
                    item.state = GoofySettings.menuBarEnabled ? .on : .off
                case "Hide Notification Preview":
                    item.state = GoofySettings.hidePreview ? .on : .off
                case "Force Reduce Motion":
                    item.state = GoofySettings.forceReduceMotion ? .on : .off
                case "Suspend When Hidden":
                    item.state = GoofySettings.suspendWhenHidden ? .on : .off
                case "Keep Process Warm":
                    item.state = GoofySettings.keepProcessWarm ? .on : .off
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

    @objc func toggleHidePreview(_ sender: Any?) {
        GoofySettings.hidePreview.toggle()
        refreshCheckStates()
    }

    @objc func toggleForceReduceMotion(_ sender: Any?) {
        GoofySettings.forceReduceMotion.toggle()
        viewController()?.applyForceReduceMotionToPage()
        refreshCheckStates()
    }

    @objc func toggleSuspendWhenHidden(_ sender: Any?) {
        GoofySettings.suspendWhenHidden.toggle()
        viewController()?.suspendWhenHiddenSettingDidChange()
        refreshCheckStates()
    }

    @objc func toggleKeepProcessWarm(_ sender: Any?) {
        GoofySettings.keepProcessWarm.toggle()
        updateKeepWarmActivity()
        refreshCheckStates()
    }

    /// Hold an NSActivity so App Nap does not throttle WebKit while the window is ordered out.
    private func updateKeepWarmActivity() {
        if GoofySettings.keepProcessWarm {
            if keepWarmActivity == nil {
                keepWarmActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiatedAllowingIdleSystemSleep],
                    reason: "Goofy keep Messenger WebKit warm for smooth reopen")
            }
        } else {
            endKeepWarmActivity()
        }
    }

    private func endKeepWarmActivity() {
        if let keepWarmActivity {
            ProcessInfo.processInfo.endActivity(keepWarmActivity)
            self.keepWarmActivity = nil
        }
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
            "Smooth cache: 512MB/2GB URLCache; keep-process-warm default ON. Badge/noti stay live while backgrounded. Menu bar, force reduce motion, suspend-when-hidden default OFF. Global ⌘⇧Y toggles the window (may need Accessibility)."
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
            ("Force reduce motion", GoofySettings.forceReduceMotion, #selector(toggleForceReduceMotion(_:))),
            ("Suspend web content when hidden", GoofySettings.suspendWhenHidden, #selector(toggleSuspendWhenHidden(_:))),
            ("Keep process warm (anti–App Nap)", GoofySettings.keepProcessWarm, #selector(toggleKeepProcessWarm(_:))),
        ]

        for (title, on, action) in toggles {
            let button = NSButton(checkboxWithTitle: title, target: self, action: action)
            button.state = on ? .on : .off
            stack.addArrangedSubview(button)
        }

        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 260)
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

    /// Lazily subscribe so launch does not pay Combine/AppUpdater overhead.
    private func ensureUpdaterSubscribed() {
        guard !updaterSubscribed else { return }
        updaterSubscribed = true
        Self.appUpdater.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if case .downloaded(let release, _, let bundle) = state {
                    self?.showUpdateAlert(version: release.tagName.description, bundle: bundle)
                }
            }
            .store(in: &cancellables)
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
        ensureUpdaterSubscribed()
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
