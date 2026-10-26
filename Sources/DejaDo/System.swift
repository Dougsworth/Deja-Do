import AppKit
import ApplicationServices
import Security
import UserNotifications
import DejaDoCore

/// Tells the person when a task that ran on its own, on a schedule or for
/// another tool, didn't finish. Nobody was watching, so the status line isn't enough.
enum Notify {
    static let taskKey = "task"

    /// Asks once, the first time it's needed. Saying no just means no banners.
    static func ask() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func problem(task: Automation, message: String) {
        let e = Explainer.explain(message)
        let content = UNMutableNotificationContent()
        content.title = "“\(task.name)” didn't finish"
        content.subtitle = e.headline
        content.body = message
        content.sound = .default
        content.userInfo = [taskKey: task.id.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}

/// Stores the API key in the login keychain instead of a plain file.
enum Keychain {
    private static let service = "com.douglasbyfield.dejado"
    /// Where keys were kept while the app was called Once.
    private static let legacyService = "com.douglasbyfield.once"

    static func get(_ account: String) -> String? {
        if let value = get(account, service: service) { return value }
        guard let old = get(account, service: legacyService) else { return nil }
        set(old, for: account)
        return old
    }

    private static func get(_ account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Small modal prompts used while an automation runs.
enum Prompt {
    /// A yes or no question. Returns true for yes.
    static func confirm(_ question: String, detail: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = detail
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Stop")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func text(_ message: String, secret: Bool) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = secret ? "This is never saved." : "This step asks each time it runs."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Stop")
        let field: NSTextField = secret ? NSSecureTextField() : NSTextField()
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
