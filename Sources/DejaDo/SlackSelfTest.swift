import AppKit
import ApplicationServices
@preconcurrency import DejaDoCore

/// Record and replay in a real Electron app: moving between two tabs in
/// Slack's sidebar (Activity, then Home). Nothing is typed into Slack and
/// nothing is sent; switching tabs is all it does.
///
/// Skipped, without failing, when Slack isn't installed or isn't signed in.
enum SlackSelfTest {
    static let slackID = "com.tinyspeck.slackmacgap"
    /// Sidebar tabs that only change what's shown, in the order to prefer.
    static let tabs = ["Activity", "Home", "DMs", "Later", "Files", "Directories", "Actividad", "Inicio", "Mensajes directos"]
    static let tabRoles: Set<String> = ["AXButton", "AXRadioButton", "AXTab", "AXLink", "AXMenuItem"]

    static func run(_ log: SelfTest.Log, vision: Bool) async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: slackID) else {
            log.check("Slack: record and replay", true, "Slack isn't installed, skipped", counted: false)
            return
        }
        log.line("Slack")
        let previous = NSWorkspace.shared.frontmostApplication
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)

        // Slack takes a while to start and to build its tree once asked.
        var pair: (AX.Found, AX.Found)?
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let app = ElementFinder.runningApp(slackID) else { continue }
            AX.wake(pid: app.processIdentifier, bundleID: slackID)
            app.activate(options: [.activateIgnoringOtherApps])
            if let p = sidebarPair() { pair = p; break }
        }
        guard let (first, second) = pair else {
            let named = controls().filter { ($0.node.label ?? "").count >= 2 }.count
            log.check("Slack: record and replay", true,
                      "couldn't find two sidebar tabs (\(named) named controls; Slack may be signed out), skipped", counted: false)
            previous?.activate(options: [.activateIgnoringOtherApps])
            return
        }
        let a = first.node.label ?? "", b = second.node.label ?? ""
        log.check("Slack describes its sidebar once asked", true, "using “\(a)” then “\(b)”, \(controls().count) controls")

        // Start on the second tab so the recording's first click changes something.
        _ = await press(b)
        let recorder = await MainActor.run { () -> Recorder in
            let r = Recorder()
            r.visionEnabled = vision
            r.checkSteps = true
            _ = r.start()
            return r
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        var acted = await press(a)
        acted = await press(b) && acted
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let steps: [Step] = await withCheckedContinuation { cont in
            DispatchQueue.main.async { recorder.finish { cont.resume(returning: $0) } }
        }
        let clicks = steps.compactMap { step -> ElementLocator? in
            if case .click(let t, _, _, _) = step.kind { return t }
            return nil
        }
        log.check("Slack: recorded two clicks on named tabs", acted && clicks.count == 2 && clicks.allSatisfy { $0.hasText },
                  steps.map(\.summary).joined(separator: " | "))
        let task = Automation(name: "Self test Slack", steps: steps)
        log.check("Slack: switching tabs isn't mistaken for a risky step",
                  task.steps.indices.allSatisfy { task.risk(at: $0).risk == .normal })
        guard acted, clicks.count == 2 else { previous?.activate(options: [.activateIgnoringOtherApps]); return }

        // Somewhere else first, then replay.
        _ = await press(a)
        let (error, notes) = await SelfTest.runTask(task, vision: vision)
        log.check("Slack: replay finds both tabs and finishes", error == nil && notes.components(separatedBy: "Found").count - 1 >= 2,
                  error ?? "finished")
        log.check("Slack: ends on “\(b)”", isSelected(b) != false, isSelected(b) == nil ? "Slack doesn't say which tab is selected" : "")
        log.line("      notes: \(notes)")

        // The window made narrower, which Slack reflows: the tabs must still be found.
        if let w = window(), let f = AX.frame(w), f.width > 900 {
            let narrower = CGSize(width: max(800, f.width - 300), height: f.height)
            var size = narrower
            if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            _ = await press(a)
            let (e2, n2) = await SelfTest.runTask(task, vision: vision)
            log.check("Slack: replay after the window is narrowed", e2 == nil, e2 ?? "finished")
            log.line("      notes: \(n2)")
            var back = f.size
            if let v = AXValueCreate(.cgSize, &back) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
        }
        previous?.activate(options: [.activateIgnoringOtherApps])
    }

    static func window() -> AXUIElement? {
        guard let app = ElementFinder.runningApp(slackID) else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 1.5)
        return AX.element(el, kAXFocusedWindowAttribute) ?? AX.elements(AX.raw(el, kAXWindowsAttribute)).first
    }

    static func controls() -> [AX.Found] {
        guard let w = window() else { return [] }
        return AX.collect(from: w, origin: nil, limit: 3000) { tabRoles.contains($0) }
    }

    /// Two sidebar tabs, by name.
    static func sidebarPair() -> (AX.Found, AX.Found)? {
        let all = controls()
        let found = tabs.compactMap { name in
            all.first { ($0.node.label ?? "").lowercased() == name.lowercased() && ($0.node.frame?.width ?? 0) > 4 }
        }
        guard found.count >= 2 else { return nil }
        return (found[0], found[1])
    }

    @discardableResult
    static func press(_ label: String) async -> Bool {
        guard let f = controls().first(where: { ($0.node.label ?? "") == label }), let r = f.node.frame else { return false }
        Input.click(at: CGPoint(x: r.midX, y: r.midY), button: .left, count: 1, modifiers: 0)
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        return true
    }

    /// Whether the tab says it's the selected one, or nil when Slack doesn't say.
    static func isSelected(_ label: String) -> Bool? {
        guard let f = controls().first(where: { ($0.node.label ?? "") == label }) else { return nil }
        if let v = AX.raw(f.element, kAXSelectedAttribute) as? Bool { return v }
        if let v = AX.raw(f.element, kAXValueAttribute) as? NSNumber, f.node.role == "AXRadioButton" || f.node.role == "AXTab" {
            return v.boolValue
        }
        return nil
    }
}
