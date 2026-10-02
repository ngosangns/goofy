//
//  ViewController.swift
//  goofy
//
//  Created by Daniel Büchele on 02/01/2026.
//

import AVFoundation
import Cocoa
import Network
import UserNotifications
import WebKit

class ViewController: NSViewController {

    private var webView: GoofyWebView!
    private let messageHandlerName = "goofy"

    // Zoom properties
    private static let zoomKey = "WebViewZoomLevel"
    private var zoomLevel: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: Self.zoomKey)
            return stored == 0 ? 1.0 : CGFloat(stored)
        }
        set {
            let clamped = min(max(newValue, 0.5), 3.0)
            UserDefaults.standard.set(Double(clamped), forKey: Self.zoomKey)
            webView.pageZoom = clamped
        }
    }

    // Periodic reload properties
    private let reloadInterval: TimeInterval = 3 * 60 * 60  // 3 hours
    private var reloadPending = false
    private var reloadTimer: Timer?
    private var networkMonitor: NWPathMonitor?
    private var wasNetworkConnected = true
    private var windowConfigured = false
    private var isAuthenticated = false
    private var safariLoginController: SafariLoginController?

    // Soft-reload / interaction tracking
    private var lastUserInteraction = Date()
    private var lastReloadDate = Date.distantPast
    private let softReloadIdleSeconds: TimeInterval = 30 * 60
    private let recentTypingSeconds: TimeInterval = 2 * 60
    private var appearanceObserver: NSKeyValueObservation?
    private var currentThreadKey: String?
    private var networkReloadWorkItem: DispatchWorkItem?
    private var windowVisible = true
    private var interactionMonitor: Any?
    private var didLoadMessenger = false
    private var webContentSuspended = false
    private var contentRulesInstalled = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupWebView()
        setupNotifications()
        setupAppearanceObserver()
        setupInteractionTracking()
        // Defer first loadMessenger to viewDidAppear so window/chrome settle first.
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !windowConfigured {
            configureWindow()
            setupPeriodicReload()
            windowConfigured = true
        }
        if !didLoadMessenger {
            didLoadMessenger = true
            applyForceReduceMotionToPage()
            loadMessenger()
        }
    }

    deinit {
        reloadTimer?.invalidate()
        networkMonitor?.cancel()
        networkReloadWorkItem?.cancel()
        appearanceObserver?.invalidate()
        if let interactionMonitor {
            NSEvent.removeMonitor(interactionMonitor)
        }
        NotificationCenter.default.removeObserver(self)
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: messageHandlerName, contentWorld: .defaultClient)
    }

    // MARK: - WebView Setup

    private func setupWebView() {
        let configuration = WKWebViewConfiguration()
        #if DEBUG
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        // Prefer video-only gesture gate so chat audio/voice notes can play.
        // AirPlay stays off to avoid background media work.
        configuration.mediaTypesRequiringUserActionForPlayback = .video
        configuration.allowsAirPlayForMediaPlayback = false

        let userContentController = WKUserContentController()

        // Use .defaultClient world to isolate our code from the page's JS
        userContentController.add(self, contentWorld: .defaultClient, name: messageHandlerName)

        // Inject style.css at document start (before page renders)
        if let cssURL = Bundle.main.url(forResource: "style", withExtension: "css"),
            let cssContent = try? String(contentsOf: cssURL, encoding: .utf8)
        {
            let escapedCSS = cssContent
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")
            let cssScript = WKUserScript(
                source: """
                    (function() {
                        const style = document.createElement('style');
                        style.textContent = `\(escapedCSS)`;
                        (document.head || document.documentElement).appendChild(style);
                    })();
                    """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            )
            userContentController.addUserScript(cssScript)
        }

        // Bootstrap force-reduce-motion class early when the setting is on.
        if GoofySettings.forceReduceMotion {
            let reduceScript = WKUserScript(
                source: "document.documentElement.classList.add('goofy-force-reduce-motion');",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            )
            userContentController.addUserScript(reduceScript)
        }

        // Inject content.js at document end
        if let scriptURL = Bundle.main.url(forResource: "content", withExtension: "js"),
            let scriptContent = try? String(contentsOf: scriptURL, encoding: .utf8)
        {
            let userScript = WKUserScript(
                source: scriptContent,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: .defaultClient
            )
            userContentController.addUserScript(userScript)
        }

        configuration.userContentController = userContentController
        installContentRuleList(into: userContentController)

        // Create WebView
        webView = GoofyWebView(frame: view.bounds, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self

        webView.allowsBackForwardNavigationGestures = true

        // Dynamic Safari user agent
        webView.customUserAgent = Self.safariUserAgent()

        webView.pageZoom = zoomLevel

        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #else
        if #available(macOS 13.3, *) {
            webView.isInspectable = false
        }
        #endif

        // Avoid an extra opaque layer behind WebKit content where possible.
        webView.setValue(false, forKey: "drawsBackground")

        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureWindow() {
        guard let window = view.window else { return }

        // Set minimum window size
        window.minSize = NSSize(width: 400, height: 600)

        // On first launch, no saved frame exists — set default size
        if UserDefaults.standard.string(forKey: "NSWindow Frame MainWindow") == nil {
            window.setContentSize(NSSize(width: 1200, height: 800))
            window.center()
        }

        // Make window resizable
        window.styleMask.insert(.resizable)

        // Full-size content view with transparent titlebar for inset traffic lights
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // Add toolbar for inset traffic light style and window corner radius
        let toolbar = NSToolbar(identifier: "MainToolbar")
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // Match system window background (light/dark)
        window.backgroundColor = NSColor.windowBackgroundColor
        applyAppearanceToWindow()
    }

    // MARK: - Safari UA

    private static let cachedSafariUserAgent: String = {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osVersionString =
            "\(osVersion.majorVersion)_\(osVersion.minorVersion)_\(osVersion.patchVersion)"
        let safariVersion = safariShortVersion() ?? "17.0"
        return
            "Mozilla/5.0 (Macintosh; Intel Mac OS X \(osVersionString)) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Safari/605.1.15"
    }()

    static func safariUserAgent() -> String {
        cachedSafariUserAgent
    }

    static func safariShortVersion() -> String? {
        let plistURL = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plistURL) as? [String: Any],
            let version = dict["CFBundleShortVersionString"] as? String
        else { return nil }
        return version
    }

    // MARK: - Appearance

    private func setupAppearanceObserver() {
        appearanceObserver = NSApp.observe(\NSApplication.effectiveAppearance, options: [.new]) {
            [weak self] _, _ in
            DispatchQueue.main.async {
                self?.applyAppearanceToWindow()
            }
        }
        applyAppearanceToWindow()
    }

    private func applyAppearanceToWindow() {
        view.window?.backgroundColor = NSColor.windowBackgroundColor
        view.appearance = NSApp.effectiveAppearance
    }

    // MARK: - Interaction tracking

    /// App Nap friendly: do not keep a permanent local event monitor.
    /// Attach only while a soft-reload is pending or near the idle window.
    private func setupInteractionTracking() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        lastUserInteraction = Date()
    }

    private func noteUserInteraction() {
        lastUserInteraction = Date()
        if !reloadPending {
            detachInteractionMonitor()
        }
    }

    private func ensureInteractionMonitorAttached() {
        guard interactionMonitor == nil else { return }
        interactionMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.noteUserInteraction()
            return event
        }
    }

    private func detachInteractionMonitor() {
        if let interactionMonitor {
            NSEvent.removeMonitor(interactionMonitor)
            self.interactionMonitor = nil
        }
    }

    private func markReloadPending() {
        reloadPending = true
        ensureInteractionMonitorAttached()
    }

    private func loadMessenger() {
        guard let url = URL(string: "https://www.facebook.com/messages/") else { return }
        let request = URLRequest(url: url)
        webView.load(request)
    }

    // MARK: - Content blocker (trackers only; never fbcdn/fbsbx media)

    /// Blocks pixel/tr trackers. Media hosts (`fbcdn.net`, `fbsbx.com`) are intentionally not matched.
    private func installContentRuleList(into controller: WKUserContentController) {
        guard !contentRulesInstalled else { return }
        let json = """
        [
          {"trigger":{"url-filter":"^https?://pixel\\.facebook\\.com"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^https?://([a-z0-9-]+\\.)?facebook\\.com/tr(/|\\?|$)"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^https?://connect\\.facebook\\.net/.*/fbevents"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^https?://www\\.facebook\\.com/tr(/|\\?|$)"},"action":{"type":"block"}}
        ]
        """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "GoofyTrackerBlock",
            encodedContentRuleList: json
        ) { [weak self] list, error in
            #if DEBUG
            if let error {
                print("Content rule compile failed: \(error)")
            }
            #endif
            guard let list else { return }
            DispatchQueue.main.async {
                controller.add(list)
                self?.contentRulesInstalled = true
            }
        }
    }

    // MARK: - Periodic Reload

    private func setupPeriodicReload() {
        // Observer for when app goes to background - handles pending reloads
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        // Observer for system wake from sleep
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared
        )

        // Timer every 3 hours — large tolerance helps App Nap coalesce wakes.
        reloadTimer = Timer.scheduledTimer(
            withTimeInterval: reloadInterval,
            repeats: true
        ) { [weak self] _ in
            self?.timerFired()
        }
        reloadTimer?.tolerance = min(15 * 60, reloadInterval * 0.1)

        // Network connectivity monitor
        setupNetworkMonitor()
    }

    private func setupNetworkMonitor() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.handleNetworkChange(path)
            }
        }
        networkMonitor?.start(
            queue: DispatchQueue(label: "NetworkMonitor", qos: .utility))
    }

    private func timerFired() {
        if NSApplication.shared.isActive {
            markReloadPending()
            #if DEBUG
            print("Reload deferred - app is in foreground")
            #endif
        } else {
            softReload(reason: "periodic-timer")
        }
    }

    @objc private func systemDidWake(_ notification: Notification) {
        // Skip wake storm when session looks healthy and user was recently active —
        // but only after a deeper readyState / navigation probe.
        let idle = Date().timeIntervalSince(lastUserInteraction)
        if isAuthenticated, idle < softReloadIdleSeconds {
            probePageHealth { [weak self] broken in
                guard let self else { return }
                if broken || self.isPageLikelyBrokenSync() {
                    #if DEBUG
                    print("System wake - page looks broken, soft reload")
                    #endif
                    self.softReload(reason: "wake-broken")
                } else {
                    #if DEBUG
                    print("System wake - soft reload skipped (authenticated, idle \(Int(idle))s, healthy)")
                    #endif
                }
            }
            return
        }
        #if DEBUG
        print("System woke from sleep - evaluating soft reload")
        #endif
        softReload(reason: "wake")
    }

    private func handleNetworkChange(_ path: NWPath) {
        let isConnected = path.status == .satisfied
        if !wasNetworkConnected && isConnected {
            // Debounce NWPathMonitor chatter (flaps on sleep/VPN).
            networkReloadWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                #if DEBUG
                print("Network connection restored - evaluating soft reload")
                #endif
                self?.softReload(reason: "network")
            }
            networkReloadWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
        wasNetworkConnected = isConnected
    }

    /// Soft-reload: only reload if idle ≥ 30 min OR page looks broken.
    /// Never reload while key + recently typed. Wake/network never force-reload.
    private func softReload(reason: String) {
        let idle = Date().timeIntervalSince(lastUserInteraction)
        let recentlyTyped = idle < recentTypingSeconds
        let isKey = view.window?.isKeyWindow == true && NSApp.isActive

        if isKey && recentlyTyped {
            #if DEBUG
            print("Soft reload skipped (\(reason)): user recently active while key")
            #endif
            markReloadPending()
            return
        }

        // Avoid reload storms: at most once per 10 minutes unless page looks broken.
        let sinceLast = Date().timeIntervalSince(lastReloadDate)
        let pageBroken = isPageLikelyBrokenSync()
        if !pageBroken && sinceLast < 10 * 60 {
            #if DEBUG
            print("Soft reload skipped (\(reason)): reloaded \(Int(sinceLast))s ago")
            #endif
            markReloadPending()
            return
        }

        let idleEnough = idle >= softReloadIdleSeconds
        // periodic-timer only reloads when actually idle or broken — never force.
        if pageBroken || idleEnough {
            performReload(reason: reason)
        } else {
            #if DEBUG
            print(
                "Soft reload deferred (\(reason)): idle \(Int(idle))s < \(Int(softReloadIdleSeconds))s"
            )
            #endif
            markReloadPending()
        }
    }

    /// Sync URL-host heuristic (cheap).
    private func isPageLikelyBrokenSync() -> Bool {
        guard let url = webView.url else { return true }
        let host = url.host ?? ""
        if !host.contains("facebook.com") && !host.contains("messenger.com") {
            return true
        }
        return false
    }

    /// Deeper probe: readyState + [role=navigation] via JS (async).
    private func probePageHealth(completion: @escaping (Bool) -> Void) {
        if isPageLikelyBrokenSync() {
            completion(true)
            return
        }
        guard webView != nil else {
            completion(true)
            return
        }
        let script =
            "window.__GOOFY && window.__GOOFY.isPageLikelyBroken ? window.__GOOFY.isPageLikelyBroken() : (document.readyState === 'loading' || !document.querySelector('[role=\"navigation\"]'));"
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
            switch result {
            case .success(let value):
                completion((value as? Bool) ?? false)
            case .failure:
                completion(false)
            }
        }
    }

    private func performReload(reason: String = "manual") {
        reloadPending = false
        detachInteractionMonitor()
        lastReloadDate = Date()
        webView.reload()
        #if DEBUG
        print("Reload performed (\(reason))")
        #endif
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        notifyAppState("background")
        // Near soft-reload idle window — attach monitor so return-to-app updates idle clock.
        let idle = Date().timeIntervalSince(lastUserInteraction)
        if reloadPending || idle >= softReloadIdleSeconds - 5 * 60 {
            ensureInteractionMonitorAttached()
        }
        if reloadPending {
            softReload(reason: "resign-pending")
        }
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        noteUserInteraction()
        if windowVisible {
            notifyAppState("foreground")
        }
    }

    private func notifyAppState(_ state: String) {
        guard webView != nil else { return }
        let script = "window.__GOOFY && window.__GOOFY.setAppState && window.__GOOFY.setAppState(\"\(state)\");"
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in }
    }

    /// Warm UX: window hide/show never starves badge/noti by itself.
    /// Only when suspendWhenHidden is ON: pause media + hide webView + pause observers.
    func notifyWindowVisibility(_ visible: Bool) {
        windowVisible = visible
        if visible {
            restoreWebContentIfNeeded()
            noteUserInteraction()
            if NSApp.isActive {
                notifyAppState("foreground")
            }
        } else {
            notifyAppState("background")
            if GoofySettings.suspendWhenHidden {
                suspendWebContent()
            }
        }
    }

    /// Pause videos, hide web view, and pause JS observers. Does NOT clear cookies/session.
    /// Only used when GoofySettings.suspendWhenHidden is ON.
    private func suspendWebContent() {
        guard !webContentSuspended, webView != nil else { return }
        webContentSuspended = true
        let script = """
            if (window.__GOOFY) {
              window.__GOOFY.pauseMedia && window.__GOOFY.pauseMedia();
              window.__GOOFY.setSuspended && window.__GOOFY.setSuspended(true);
            }
            """
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in }
        webView.isHidden = true
    }

    private func restoreWebContentIfNeeded() {
        guard webContentSuspended, webView != nil else { return }
        webContentSuspended = false
        webView.isHidden = false
        let script = "window.__GOOFY && window.__GOOFY.setSuspended && window.__GOOFY.setSuspended(false);"
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in }
    }

    func applyForceReduceMotionToPage() {
        guard webView != nil else { return }
        let enabled = GoofySettings.forceReduceMotion
        let script =
            "window.__GOOFY && window.__GOOFY.setForceReduceMotion && window.__GOOFY.setForceReduceMotion(\(enabled ? "true" : "false"));"
        webView.evaluateJavaScript(script, in: nil, in: .page) { _ in }
        // Also toggle class directly in case __GOOFY is not ready yet.
        let cls =
            "document.documentElement.classList.toggle('goofy-force-reduce-motion', \(enabled ? "true" : "false"));"
        webView.evaluateJavaScript(cls, in: nil, in: .page) { _ in }
    }

    // MARK: - Window Actions (forwarded to window)

    @IBAction func performMiniaturize(_ sender: Any?) {
        view.window?.performMiniaturize(sender)
    }

    @IBAction func performZoom(_ sender: Any?) {
        view.window?.performZoom(sender)
    }

    // MARK: - Zoom Actions

    @IBAction func zoomIn(_ sender: Any?) {
        zoomLevel += 0.1
    }

    @IBAction func zoomOut(_ sender: Any?) {
        zoomLevel -= 0.1
    }

    @IBAction func resetZoom(_ sender: Any?) {
        zoomLevel = 1.0
    }

    // MARK: - Reload Action (CMD+R)

    @IBAction func reloadPage(_ sender: Any?) {
        loadMessenger()
    }

    // MARK: - New Message Action (CMD+N)

    @IBAction func newMessage(_ sender: Any?) {
        let script = "window.__GOOFY.newMessage();"
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
            if case .failure(let error) = result {
                print("Failed to trigger new message: \(error)")
            }
        }
    }

    // MARK: - Search Action (CMD+F)

    @IBAction func focusSearch(_ sender: Any?) {
        let script = "window.__GOOFY.focusSearch();"
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
            if case .failure(let error) = result {
                print("Failed to focus search: \(error)")
            }
        }
    }

    // MARK: - Login with Safari Action

    @IBAction func loginWithSafari(_ sender: Any?) {
        view.window?.orderOut(nil)
        let controller = SafariLoginController()
        safariLoginController = controller
        controller.startLogin { [weak self] in
            self?.safariLoginController = nil
            self?.loadMessenger()
            self?.view.window?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Log Out Action

    @IBAction func logOut(_ sender: Any?) {
        isAuthenticated = false
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()

        dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
            let messengerRecords = records.filter { record in
                record.displayName.contains("messenger.com")
                    || record.displayName.contains("facebook.com")
            }
            dataStore.removeData(ofTypes: dataTypes, for: messengerRecords) {
                DispatchQueue.main.async {
                    self.loadMessenger()
                }
            }
        }
    }

    // MARK: - Notifications Setup

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Defer permission prompt/work slightly so it is not on the cold-launch path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                #if DEBUG
                if let error = error {
                    print("Notification authorization error: \(error)")
                }
                print("Notification permission granted: \(granted)")
                #endif
            }
        }
    }

    // MARK: - Badge Updates

    private func updateBadge(count: Int) {
        DispatchQueue.main.async {
            // Dock badge always — trusted even when menu bar is off.
            if count > 0 {
                NSApp.dockTile.badgeLabel = "\(count)"
            } else {
                NSApp.dockTile.badgeLabel = nil
            }
            NotificationCenter.default.post(
                name: .goofyBadgeDidChange, object: nil, userInfo: ["count": count])
        }
    }

    // MARK: - Show Notification

    private func showNotification(title: String, body: String, threadKey: String) {
        let mode = GoofySettings.notificationMode
        if mode == .off { return }

        // If already viewing this thread and window is key, skip enqueue entirely
        if shouldSuppressBanner(for: threadKey) && mode == .banner {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = GoofySettings.hidePreview ? "" : body
        if mode == .banner {
            content.sound = .default
        }
        content.userInfo = ["threadKey": threadKey]

        let identifier = threadKey.replacingOccurrences(of: "/", with: "_")
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to show notification: \(error)")
            }
        }
    }

    private func shouldSuppressBanner(for threadKey: String) -> Bool {
        guard view.window?.isKeyWindow == true, NSApp.isActive else { return false }
        guard let current = currentThreadKey, !current.isEmpty else { return false }
        return threadKeysMatch(current, threadKey)
    }

    private func threadKeysMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        // Compare path tails (/messages/t/ID)
        let na = normalizeThreadKey(a)
        let nb = normalizeThreadKey(b)
        return !na.isEmpty && na == nb
    }

    private func normalizeThreadKey(_ key: String) -> String {
        if let url = URL(string: key, relativeTo: URL(string: "https://www.facebook.com")) {
            return url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return key.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - Navigate to Thread

    func navigateToThread(threadKey: String) {
        let escapedKey = threadKey.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "window.__GOOFY.navigateToThread(\"\(escapedKey)\");"
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
            if case .failure(let error) = result {
                print("Failed to navigate to thread: \(error)")
            }
        }

        // Bring window to front
        NSApp.activate(ignoringOtherApps: true)
        view.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Keyboard / prefs bridge

    func jumpToThread(index: Int) {
        let script = "window.__GOOFY && window.__GOOFY.jumpToThread && window.__GOOFY.jumpToThread(\(index));"
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in }
    }

    func prevThread() {
        webView.evaluateJavaScript(
            "window.__GOOFY && window.__GOOFY.prevThread && window.__GOOFY.prevThread();",
            in: nil, in: .defaultClient) { _ in }
    }

    func nextThread() {
        webView.evaluateJavaScript(
            "window.__GOOFY && window.__GOOFY.nextThread && window.__GOOFY.nextThread();",
            in: nil, in: .defaultClient) { _ in }
    }

}

// MARK: - WKScriptMessageHandler

extension ViewController: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard message.name == messageHandlerName,
            let body = message.body as? [String: Any],
            let type = body["type"] as? String
        else {
            return
        }

        switch type {
        case "badge":
            if let count = body["count"] as? Int {
                updateBadge(count: count)
            }

        case "notification":
            if let title = body["title"] as? String,
                let notificationBody = body["body"] as? String,
                let threadKey = body["threadKey"] as? String
            {
                if let current = body["currentThreadKey"] as? String {
                    currentThreadKey = current
                }
                showNotification(title: title, body: notificationBody, threadKey: threadKey)
            }

        case "currentThread":
            if let threadKey = body["threadKey"] as? String {
                currentThreadKey = threadKey
            } else if body["threadKey"] is NSNull {
                currentThreadKey = nil
            }

        case "log":
            if let logMessage = body["message"] as? String {
                print("[Goofy JS] \(logMessage)")
            }

        default:
            break
        }
    }
}

// MARK: - WKNavigationDelegate

extension ViewController: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // Handle blob URLs as downloads
        if url.scheme == "blob" {
            decisionHandler(.download)
            return
        }

        // Allow messages + media + call-related FB paths
        if isAllowedInApp(url: url) {
            decisionHandler(.allow)
            return
        }

        // While Safari login is active, don't cancel auth flows from main view
        if safariLoginController != nil {
            decisionHandler(.cancel)
            return
        }

        // Before login, silently cancel other navigations (login redirects)
        if !isAuthenticated {
            decisionHandler(.cancel)
            return
        }

        // After login, unwrap tracking redirects then open externally
        if let scheme = url.scheme, ["http", "https"].contains(scheme) {
            let unwrapped = Self.unwrapTrackingURL(url)
            NSWorkspace.shared.open(unwrapped)
        }
        decisionHandler(.cancel)
    }

    private func isAllowedInApp(url: URL) -> Bool {
        let host = url.host ?? ""
        let path = url.path.lowercased()

        if host.contains("fbsbx.com") || host.contains("fbcdn.net") {
            return true
        }
        if host.contains("facebook.com") || host.contains("messenger.com") {
            if path.hasPrefix("/messages") { return true }
            // Calls / rooms / attachment helpers
            if path.contains("/call") || path.contains("/rtc") || path.contains("/voip") {
                return true
            }
            if path.hasPrefix("/video_call") || path.hasPrefix("/groupcall") {
                return true
            }
            // Auth-ish while already in messages shell
            if path.hasPrefix("/login") || path.hasPrefix("/checkpoint") {
                return true
            }
        }
        return false
    }

    /// Unwrap l.facebook.com/l.php?u= and similar tracking redirects.
    static func unwrapTrackingURL(_ url: URL) -> URL {
        let host = url.host ?? ""
        guard host.contains("l.facebook.com") || host.contains("lm.facebook.com")
            || host == "facebook.com" && url.path.hasPrefix("/l.php")
            || host.hasSuffix(".facebook.com") && url.path.hasPrefix("/l.php")
        else {
            return url
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let uParam = components.queryItems?.first(where: { $0.name == "u" })?.value,
            let decoded = uParam.removingPercentEncoding,
            let unwrapped = URL(string: decoded)
        else {
            return url
        }
        return unwrapped
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        #if DEBUG
        print("Page finished loading: \(url.absoluteString)")
        #endif

        guard url.host?.contains("facebook.com") == true,
              safariLoginController == nil else { return }

        // Once authenticated, skip repeated getAllCookies scans on every navigation.
        if isAuthenticated { return }

        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            let authenticated = cookies.contains {
                $0.domain.contains("facebook.com") && $0.name == "c_user"
            }
            DispatchQueue.main.async {
                if authenticated {
                    self?.isAuthenticated = true
                    let foreground = NSApp.isActive && (self?.windowVisible ?? true)
                    self?.notifyAppState(foreground ? "foreground" : "background")
                } else {
                    #if DEBUG
                    print("[Goofy] Not authenticated, opening Safari login window")
                    #endif
                    self?.loginWithSafari(nil)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        #if DEBUG
        print("Navigation failed: \(error.localizedDescription)")
        #endif
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        #if DEBUG
        print("Provisional navigation failed: \(error.localizedDescription)")
        #endif
    }
}

// MARK: - WKUIDelegate

extension ViewController: WKUIDelegate {
    // Handle JavaScript alerts
    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    // Handle JavaScript confirms
    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    // Handle file upload picker
    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        if panel.runModal() == .OK {
            completionHandler(panel.urls)
        } else {
            completionHandler(nil)
        }
    }

    // Handle new window requests (target="_blank" links)
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            if url.scheme == "blob" {
                webView.load(navigationAction.request)
            } else if isAllowedInApp(url: url) {
                webView.load(URLRequest(url: url))
            } else {
                NSWorkspace.shared.open(Self.unwrapTrackingURL(url))
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // Handle camera/microphone permission requests
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        // Only allow for messenger.com and facebook.com
        guard origin.host.contains("messenger.com") || origin.host.contains("facebook.com") else {
            decisionHandler(.deny)
            return
        }

        // Determine which media types are being requested
        let mediaTypes: [AVMediaType] = {
            switch type {
            case .camera:
                return [.video]
            case .microphone:
                return [.audio]
            case .cameraAndMicrophone:
                return [.video, .audio]
            @unknown default:
                return []
            }
        }()

        // Check and request permissions for all required media types
        checkAndRequestPermissions(for: mediaTypes) { allGranted in
            DispatchQueue.main.async {
                if allGranted {
                    decisionHandler(.grant)
                } else {
                    decisionHandler(.deny)
                    self.showPermissionDeniedAlert(for: type)
                }
            }
        }
    }

    private func checkAndRequestPermissions(
        for mediaTypes: [AVMediaType],
        completion: @escaping (Bool) -> Void
    ) {
        let group = DispatchGroup()
        var allGranted = true

        for mediaType in mediaTypes {
            group.enter()

            let status = AVCaptureDevice.authorizationStatus(for: mediaType)

            switch status {
            case .authorized:
                group.leave()

            case .notDetermined:
                AVCaptureDevice.requestAccess(for: mediaType) { granted in
                    if !granted {
                        allGranted = false
                    }
                    group.leave()
                }

            case .denied, .restricted:
                allGranted = false
                group.leave()

            @unknown default:
                allGranted = false
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(allGranted)
        }
    }

    private func showPermissionDeniedAlert(for type: WKMediaCaptureType) {
        let alert = NSAlert()

        let deviceName: String
        switch type {
        case .camera:
            deviceName = "camera"
        case .microphone:
            deviceName = "microphone"
        case .cameraAndMicrophone:
            deviceName = "camera and microphone"
        @unknown default:
            deviceName = "media device"
        }

        alert.messageText = "\(deviceName.capitalized) Access Required"
        alert.informativeText =
            "Goofy needs \(deviceName) access for calls. Please enable it in System Settings > Privacy & Security > \(type == .microphone ? "Microphone" : "Camera")."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            let urlString: String
            switch type {
            case .camera:
                urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
            case .microphone:
                urlString =
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            case .cameraAndMicrophone:
                urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
            @unknown default:
                urlString = "x-apple.systempreferences:com.apple.preference.security"
            }

            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - WKDownloadDelegate

extension ViewController: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        if panel.runModal() == .OK {
            completionHandler(panel.url)
        } else {
            completionHandler(nil)
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension ViewController: UNUserNotificationCenterDelegate {
    // Handle notification when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let mode = GoofySettings.notificationMode
        if mode == .off {
            completionHandler([])
            return
        }
        if mode == .badge {
            completionHandler([.badge])
            return
        }
        let threadKey = notification.request.content.userInfo["threadKey"] as? String
        if let threadKey, shouldSuppressBanner(for: threadKey) {
            completionHandler([])
            return
        }
        completionHandler([.banner, .sound, .badge])
    }

    // Handle notification click
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let threadKey = userInfo["threadKey"] as? String {
            navigateToThread(threadKey: threadKey)
        }
        completionHandler()
    }
}

// MARK: - Custom WebView

/// WKWebView subclass that passes through mouse events in the titlebar drag area
/// so the window can be dragged. The drag area is taller on the left side (55px for
/// the first 200px) when the window is wide enough (664px+), to cover the inset
/// traffic light buttons. Otherwise it's a uniform 18px strip.
class GoofyWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let dragHeight: CGFloat
        if bounds.width >= 664 && point.x <= 200 {
            dragHeight = 55
        } else {
            dragHeight = 18
        }
        if point.y > bounds.height - dragHeight {
            return nil
        }
        return super.hitTest(point)
    }
}
