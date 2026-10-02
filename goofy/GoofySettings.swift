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
}
