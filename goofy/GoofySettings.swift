//
//  GoofySettings.swift
//  goofy
//
//  UserDefaults-backed preferences for the ngosangns fork.
//

import Foundation

enum GoofySettings {

    enum Key {
        static let notificationMode = "goofy.notificationMode"
        static let hidePreview = "goofy.hidePreview"
        static let alwaysOnTop = "goofy.alwaysOnTop"
        static let menuBarEnabled = "goofy.menuBarEnabled"
        static let hideDock = "goofy.hideDock"
        static let chatOnly = "goofy.chatOnly"
        static let blockTyping = "goofy.blockTyping"
        static let blockSeen = "goofy.blockSeen"
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

    static var alwaysOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: Key.alwaysOnTop) }
        set { UserDefaults.standard.set(newValue, forKey: Key.alwaysOnTop) }
    }

    static var menuBarEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Key.menuBarEnabled) == nil { return true }
            return UserDefaults.standard.bool(forKey: Key.menuBarEnabled)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.menuBarEnabled) }
    }

    static var hideDock: Bool {
        get { UserDefaults.standard.bool(forKey: Key.hideDock) }
        set { UserDefaults.standard.set(newValue, forKey: Key.hideDock) }
    }

    static var chatOnly: Bool {
        get { UserDefaults.standard.bool(forKey: Key.chatOnly) }
        set { UserDefaults.standard.set(newValue, forKey: Key.chatOnly) }
    }

    static var blockTyping: Bool {
        get { UserDefaults.standard.bool(forKey: Key.blockTyping) }
        set { UserDefaults.standard.set(newValue, forKey: Key.blockTyping) }
    }

    static var blockSeen: Bool {
        get { UserDefaults.standard.bool(forKey: Key.blockSeen) }
        set { UserDefaults.standard.set(newValue, forKey: Key.blockSeen) }
    }
}
