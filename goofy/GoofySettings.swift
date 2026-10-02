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
        static let menuBarEnabled = "goofy.menuBarEnabled"
        static let forceReduceMotion = "goofy.forceReduceMotion"
        static let suspendWhenHidden = "goofy.suspendWhenHidden"
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

    /// Default OFF — status item is pure UX and adds badge-update work on the hot path.
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
}
