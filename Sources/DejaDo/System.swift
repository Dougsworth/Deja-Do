import AppKit
import ApplicationServices
import Security
import DejaDoCore

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
