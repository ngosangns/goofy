//
//  GoofySettings.swift
//  goofy
//
//  UserDefaults-backed preferences for the ngosangns fork.
//  Speed-first: only settings that are cheap or needed for core messaging.
//

import Foundation

enum GoofySettings {

    enum Key {
        static let notificationMode = "goofy.notificationMode"
        static let hidePreview = "goofy.hidePreview"
        static let alwaysOnTop = "goofy.alwaysOnTop"
        static let menuBarEnabled = "goofy.menuBarEnabled"
        static let forceReduceMotion = "goofy.forceReduceMotion"
        static let suspendWhenHidden = "goofy.suspendWhenHidden"
        /// Keep WebKit/process warm (anti–App Nap). Default ON for smooth reopen/switch.
        static let keepProcessWarm = "goofy.keepProcessWarm"
    }

    enum NotificationMode: String, CaseIterable {
        case banner
        case badge
        case off

        var displayName: String {
            switch self {
            case .banner: return "Banner"
            case .badge: return "Badge only"
            case .off: return "Off"
            }
        }
    }

    static var notificationMode: NotificationMode {
        get {
            let raw = UserDefaults.standard.string(forKey: Key.notificationMode) ?? NotificationMode.banner.rawValue
            return NotificationMode(rawValue: raw) ?? .banner
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.notificationMode) }
    }

    static var hidePreview: Bool {
        get { UserDefaults.standard.bool(forKey: Key.hidePreview) }
        set { UserDefaults.standard.set(newValue, forKey: Key.hidePreview) }
    }

    /// Default OFF — window floating level when enabled.
    static var alwaysOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: Key.alwaysOnTop) }
        set { UserDefaults.standard.set(newValue, forKey: Key.alwaysOnTop) }
    }

    /// Default OFF — status item is pure UX; Dock badge is trusted without it.
    static var menuBarEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Key.menuBarEnabled) == nil { return false }
            return UserDefaults.standard.bool(forKey: Key.menuBarEnabled)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.menuBarEnabled) }
    }

    /// Default OFF — safer; when ON, inject CSS that kills animations regardless of system preference.
    static var forceReduceMotion: Bool {
        get {
            if UserDefaults.standard.object(forKey: Key.forceReduceMotion) == nil { return false }
            return UserDefaults.standard.bool(forKey: Key.forceReduceMotion)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.forceReduceMotion) }
    }

    /// Default OFF (opt-in). When ON and window is hidden: pause videos / hide webView without clearing cookies.
    static var suspendWhenHidden: Bool {
        get {
            if UserDefaults.standard.object(forKey: Key.suspendWhenHidden) == nil { return false }
            return UserDefaults.standard.bool(forKey: Key.suspendWhenHidden)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.suspendWhenHidden) }
    }

    /// Default ON — hold an NSActivity so App Nap does not starve WebKit while window is ordered out.
    static var keepProcessWarm: Bool {
        get {
            if UserDefaults.standard.object(forKey: Key.keepProcessWarm) == nil { return true }
            return UserDefaults.standard.bool(forKey: Key.keepProcessWarm)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.keepProcessWarm) }
    }

    // MARK: - Web cache capacities (not UserDefaults — always-on for smooth UX / high RAM OK)

    /// Shared URLCache memory capacity (bytes). Helps URLSession + some WebKit shared paths.
    static let urlCacheMemoryCapacity = 512 * 1024 * 1024  // 512 MB
    /// Shared URLCache disk capacity (bytes).
    static let urlCacheDiskCapacity = 2 * 1024 * 1024 * 1024  // 2 GB
}
