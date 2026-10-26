import AppKit
import Combine
import Sparkle

/// Keeps copies of Deja Do sent to people up to date. Checks once a day,
/// asks before installing, and only accepts updates signed with the key
/// whose public half is in Info.plist (SUPublicEDKey). Builds without that
/// key, such as ones made for testing, never check.
final class Updates: ObservableObject {
    static let shared = Updates()
    @Published private(set) var canCheck = false
    private var controller: SPUStandardUpdaterController?
    private var watch: AnyCancellable?

    var isAvailable: Bool { controller != nil }

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let key = (info["SUPublicEDKey"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let feed = (info["SUFeedURL"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !feed.isEmpty, !SelfTest.requested else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = c
        watch = c.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).sink { [weak self] in self?.canCheck = $0 }
    }

    func check() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
