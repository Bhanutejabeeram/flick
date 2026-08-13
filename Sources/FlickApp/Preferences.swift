import Foundation
import ServiceManagement
import SwiftUI

/// User-visible settings. Deliberately tiny — anything that changes how safe
/// the product is (auto-approval, for instance) is not a setting.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let notifications = "notificationsEnabled"
        static let sound = "soundEnabled"
        static let showFinished = "showFinishedEvents"
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.notifications: true,
            Key.sound: true,
            Key.showFinished: true,
        ])
    }

    var notificationsEnabled: Bool {
        get { defaults.bool(forKey: Key.notifications) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.notifications) }
    }

    var soundEnabled: Bool {
        get { defaults.bool(forKey: Key.sound) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.sound) }
    }

    var showFinishedEvents: Bool {
        get { defaults.bool(forKey: Key.showFinished) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.showFinished) }
    }

    /// Set when a launch-at-login change fails, so the settings panel can
    /// say why the checkbox refused to move instead of silently snapping back.
    @Published private(set) var launchAtLoginError: String?

    /// On for everyone by default: a menu-bar safety net that is not running
    /// is worse than useless, because the user believes they are covered.
    /// The "applied" flag is only persisted once registration verifiably
    /// succeeded — a failed attempt (translocated app, DMG, login items
    /// disallowed) is retried on the next launch rather than abandoned.
    /// Once applied, turning it off afterwards is respected.
    func applyDefaultLaunchAtLogin() {
        let key = "launchAtLoginDefaultApplied"
        guard !defaults.bool(forKey: key) else { return }
        if !launchAtLogin { launchAtLogin = true }
        if SMAppService.mainApp.status == .enabled {
            defaults.set(true, forKey: key)
        }
    }

    /// Registered with the system, not UserDefaults — SMAppService is the
    /// source of truth, so this stays honest if the user changes it in
    /// System Settings → General → Login Items.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = "Couldn't change launch at login — see System Settings → General → Login Items. (\(error.localizedDescription))"
                NSLog("Flick: launch-at-login change failed: \(error)")
            }
        }
    }
}
