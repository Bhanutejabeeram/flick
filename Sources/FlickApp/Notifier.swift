import AppKit
import Foundation
import InboxCore
import UserNotifications

/// Native macOS notifications, with Allow/Deny buttons on the banner so the
/// common case never requires opening the popover.
///
/// `UNUserNotificationCenter` only exists for a bundled, signed app; when we are
/// running as a bare executable we fall back to an AppleScript banner so
/// development still gets alerts (without buttons).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called when the user hits a button on the banner itself.
    var onAction: ((String, InboxDecision) -> Void)?
    /// Called with the authorization outcome so the UI can explain missing banners.
    var onAuthStatus: ((Bool) -> Void)?

    private let hasBundle = Bundle.main.bundleIdentifier != nil
    private var authorized = false

    private enum Category {
        static let approval = "flick.approval"
        static let question = "flick.question"
        static let info = "flick.info"
    }

    func requestAuthorization() {
        guard hasBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let allow = UNNotificationAction(identifier: InboxDecision.allow.rawValue,
                                         title: "Allow once", options: [])
        let deny = UNNotificationAction(identifier: InboxDecision.deny.rawValue,
                                        title: "Deny", options: [.destructive])
        let approval = UNNotificationCategory(identifier: Category.approval,
                                              actions: [allow, deny],
                                              intentIdentifiers: [], options: [])
        let question = UNNotificationCategory(identifier: Category.question,
                                              actions: [], intentIdentifiers: [], options: [])
        let info = UNNotificationCategory(identifier: Category.info,
                                          actions: [], intentIdentifiers: [], options: [])
        center.setNotificationCategories([approval, question, info])

        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            self?.authorized = granted
            DispatchQueue.main.async { self?.onAuthStatus?(granted) }
        }
    }

    func notify(_ request: InboxRequest) {
        // Played by the app itself: notification-center sound only works when
        // the user has granted (and not muted) notification permission, and
        // `.defaultCritical` is silently dropped without a special
        // entitlement. An in-app chime works regardless.
        if Preferences.shared.soundEnabled, request.type.isActionable {
            NSSound(named: request.risk == .high ? "Sosumi" : "Glass")?.play()
        }

        guard Preferences.shared.notificationsEnabled else { return }
        let title = request.agent.displayName
        let body: String
        switch request.type {
        case .approval: body = "Wants to run: \(request.message)"
        case .question: body = request.message
        case .finished: body = request.message.isEmpty ? "Finished and waiting for you." : request.message
        case .error: body = request.message
        case .sessionStart, .sessionEnd: return
        }

        guard hasBundle else {
            fallbackBanner(title: title, body: body)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        // Project rides in the smaller subtitle line, not the title.
        content.subtitle = request.project
        content.body = body
        content.userInfo = ["requestID": request.id]
        switch request.type {
        case .approval:
            // Never put a one-click Allow on a destructive command.
            content.categoryIdentifier = request.risk == .high ? Category.info : Category.approval
            if request.risk == .high {
                content.subtitle = "Destructive — review before approving"
            }
        case .question:
            content.categoryIdentifier = Category.question
        default:
            content.categoryIdentifier = Category.info
        }
        // Sound comes from the in-app chime above; adding it here too would
        // double-ping when notification permission is granted.
        if request.type.isActionable {
            content.interruptionLevel = .timeSensitive
        }

        let req = UNNotificationRequest(identifier: request.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func withdraw(id: String) {
        guard hasBundle else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    private func fallbackBanner(title: String, body: String) {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "display notification \"\(escape(body))\" with title \"\(escape(title))\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        if let decision = InboxDecision(rawValue: response.actionIdentifier) {
            onAction?(id, decision)
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            // Tapping the banner opens the inbox rather than deciding anything.
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .openInbox, object: nil)
        }
        completionHandler()
    }
}

extension Notification.Name {
    static let openInbox = Notification.Name("flick.openInbox")
}
