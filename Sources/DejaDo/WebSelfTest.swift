import AppKit
import ApplicationServices
@preconcurrency import DejaDoCore

/// End to end checks against a web form in Safari, served by Deja Do itself
/// (see TestServer). One recording of "fill the form and press Submit" is
/// replayed against every way the page can break, and the server's own
/// counter says whether the form was submitted exactly once, never, or twice.
///
/// Twice is the one result that must never happen. Once is the goal. A stop
/// before anything was sent is acceptable whenever the page changed enough
/// that acting would be a guess.
enum WebSelfTest {
    static let safariID = "com.apple.Safari"
    static let pageTitle = "Deja Do test form"

    enum Rule {
        /// The form must go through once, with the right values.
        case mustSubmit
        /// Once, or a stop with nothing sent. Never a wrong button, never twice.
        case submitOrStop
        /// Must stop with nothing sent, and must not retry.
        case mustStop
    }

    struct Scenario {
        let name: String
        let breaks: [TestServer.Break]
        let rule: Rule
        var popupRule = false
        /// Serve the same page from this host instead, as if it were another website.
        var host = "127.0.0.1"
    }

    static let scenarios: [Scenario] = [
        Scenario(name: "Same page", breaks: [], rule: .mustSubmit),
        Scenario(name: "Button renamed to “Submit request”", breaks: [.rename], rule: .mustSubmit),
        Scenario(name: "Fields reordered and button moved", breaks: [.move], rule: .mustSubmit),
        Scenario(name: "Form appears 2.5s late", breaks: [.delay], rule: .mustSubmit),
        Scenario(name: "Result takes 3s to show", breaks: [.slow], rule: .mustSubmit),
        Scenario(name: "Form scrolled below the fold", breaks: [.offscreen], rule: .mustSubmit),
        Scenario(name: "DOM ids change on every load", breaks: [.idswap], rule: .mustSubmit),
        Scenario(name: "Lookalike “Submit feedback” next to it", breaks: [.lookalike], rule: .submitOrStop),
        Scenario(name: "Button relabelled to “Send”", breaks: [.relabel], rule: .submitOrStop),
        Scenario(name: "Cookie banner covers the button", breaks: [.banner], rule: .submitOrStop),
        Scenario(name: "Cookie banner, after being shown how to close it", breaks: [.banner], rule: .mustSubmit, popupRule: true),
        Scenario(name: "Submit now opens a confirm dialog", breaks: [.confirm], rule: .mustStop),
        Scenario(name: "Everything at once: moved, renamed, late, lookalike", breaks: [.move, .rename, .delay, .lookalike], rule: .submitOrStop),
        Scenario(name: "Same form on a different website", breaks: [], rule: .mustStop, host: "localhost"),
    ]

    static func run(_ log: SelfTest.Log, vision: Bool) async -> Bool {
        let failuresBefore = log.failures
        log.line("Web form in Safari")
        let server = TestServer()
        guard server.start() else {
            log.check("Test page server starts", false)
            return false
        }
        log.check("Test page server starts", true, "port \(server.port)")
        defer { server.stop() }

        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: safariID) != nil else {
            log.check("Safari is installed", false)
            return false
        }
        let opened = Counter()
        guard await open(server.url(breaks: []), waitForButton: true) else {
            log.check("Safari shows the test page", false, "front app \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")")
            return false
        }
        opened.add()
        log.check("Safari shows the test page", true)
        let passed = await replays(log, server: server, vision: vision, opened: opened)
        await closeTabs(opened.value)
        return passed && log.failures == failuresBefore
    }

    final class Counter: @unchecked Sendable {
        private(set) var value = 0
        func add() { value += 1 }
    }

    static func replays(_ log: SelfTest.Log, server: TestServer, vision: Bool, opened: Counter) async -> Bool {
        let failuresBefore = log.failures

        // 1. Record: Name, Email, Submit, with real clicks and typing.
        let recorder = await MainActor.run { () -> Recorder in
            let r = Recorder()
            r.visionEnabled = vision
            r.checkSteps = true
            _ = r.start()
            return r
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        var acted = true
        acted = await click(field: "Name") && acted
        acted = type("Ana") && acted
        acted = await click(field: "Email") && acted
        acted = type("ana@example.com") && acted
        acted = await click(button: "Submit") && acted
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let steps: [Step] = await withCheckedContinuation { cont in
            DispatchQueue.main.async { recorder.finish { cont.resume(returning: $0) } }
        }
        log.check("Found the fields and the button while recording", acted)
        let recorded = server.state
        log.check("Recording submitted the form once", recorded.submits == 1 && recorded.lastName == "Ana",
                  "submits \(recorded.submits), name “\(recorded.lastName)”, email “\(recorded.lastEmail)”")
        let clicks = steps.filter { if case .click = $0.kind { return true }; return false }
        let typed = steps.filter { if case .type = $0.kind { return true }; return false }
        log.check("Recorded 3 clicks and 2 typed texts", clicks.count == 3 && typed.count == 2,
                  steps.map(\.summary).joined(separator: " | "))
        let task = Automation(name: "Self test web form", steps: steps)
        if let i = task.steps.lastIndex(where: { if case .click = $0.kind { return true }; return false }) {
            let risk = task.risk(at: i)
            log.check("Submit is recognised as a risky step", risk.risk == .risky, risk.reason ?? "")
            log.check("Recorded what Submit changed", task.steps[i].expect.map { !$0.appeared.isEmpty } == true,
                      task.steps[i].expect?.summary ?? "nothing")
            if case .click(let t, _, _, _) = task.steps[i].kind {
                log.check("Knows which website and which DOM id Submit was", t.web?.host == "127.0.0.1" && t.identifier == "submit",
                          "site \(t.web?.host ?? "none") path \(t.web?.path ?? "none"), id \(t.identifier ?? "none")")
            }
        }
        guard acted, recorded.submits == 1, clicks.count == 3 else {
            log.line("      recording didn't come out right, skipping the replays")
            return false
        }

        // 2. Replay against each breakage.
        for scenario in scenarios {
            server.reset()
            guard await open(server.url(breaks: scenario.breaks, host: scenario.host), waitForButton: !scenario.breaks.contains(.delay)) else {
                log.check(scenario.name, false, "the page didn't load")
                continue
            }
            opened.add()
            var variant = task
            if scenario.popupRule {
                if let rule = await bannerRule() {
                    variant.popups = [rule]
                } else {
                    log.check(scenario.name, false, "couldn't build a rule for the banner")
                    continue
                }
            }
            let (error, notes) = await SelfTest.runTask(variant, vision: vision)
            let s = server.state
            let retried = notes.contains("trying once more")
            let detail = "submits \(s.submits), feedback \(s.feedback), confirms \(s.confirms), got it \(s.gotIt)"
                + (error.map { " · stopped: \($0)" } ?? "")
            let rightValues = s.lastName == "Ana" && s.lastEmail == "ana@example.com"
            let ok: Bool
            switch scenario.rule {
            case .mustSubmit:
                ok = error == nil && s.submits == 1 && s.feedback == 0 && rightValues && !retried
            case .submitOrStop:
                ok = s.feedback == 0 && s.submits <= 1 && !retried
                    && ((error == nil && s.submits == 1 && rightValues) || (error != nil && s.submits == 0))
            case .mustStop:
                ok = error != nil && s.submits == 0 && s.confirms == 0 && !retried
            }
            log.check(scenario.name, ok, detail)
            if s.submits > 1 { log.line("      SUBMITTED TWICE, this must never happen") }
            log.line("      notes: \(notes)")
        }
        return log.failures == failuresBefore
    }

    // MARK: Safari

    /// Opens the page in Safari and waits until it's showing.
    static func open(_ url: URL, waitForButton: Bool) async -> Bool {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: safariID) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: config)
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let w = window(), AX.string(w, kAXTitleAttribute)?.contains(pageTitle) == true else { continue }
            if !waitForButton || find(role: "AXButton", labelled: ["Submit", "Submit request", "Send"]) != nil {
                try? await Task.sleep(nanoseconds: 700_000_000)
                NSRunningApplication.runningApplications(withBundleIdentifier: safariID).first?
                    .activate(options: [.activateIgnoringOtherApps])
                return true
            }
        }
        return false
    }

    static func window() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: safariID).first else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 1.0)
        let windows = AX.elements(AX.raw(el, kAXWindowsAttribute))
        return windows.first { AX.string($0, kAXTitleAttribute)?.contains(pageTitle) == true }
            ?? AX.element(el, kAXFocusedWindowAttribute)
    }

    static func find(role: String, labelled labels: [String]) -> AX.Found? {
        guard let w = window() else { return nil }
        let wanted = Set(labels.map { $0.lowercased() })
        return AX.collect(from: w, origin: nil, limit: 1500) { $0 == role }.first { f in
            [f.node.label, f.node.title, f.node.desc].contains { $0.map { wanted.contains($0.lowercased()) } ?? false }
        }
    }

    static func click(field: String) async -> Bool {
        guard let f = find(role: "AXTextField", labelled: [field]), let frame = f.node.frame else { return false }
        Input.click(at: CGPoint(x: frame.midX, y: frame.midY), button: .left, count: 1, modifiers: 0)
        try? await Task.sleep(nanoseconds: 900_000_000)
        return true
    }

    static func click(button: String) async -> Bool {
        guard let f = find(role: "AXButton", labelled: [button]), let frame = f.node.frame else { return false }
        Input.click(at: CGPoint(x: frame.midX, y: frame.midY), button: .left, count: 1, modifiers: 0)
        try? await Task.sleep(nanoseconds: 900_000_000)
        return true
    }

    static func type(_ text: String) -> Bool {
        let ok = Input.type(text)
        usleep(900_000)
        return ok
    }

    /// A rule that closes the cookie banner by clicking "Got it", built the way
    /// the app does when a person shows it the popup once.
    static func bannerRule() async -> PopupRule? {
        guard let f = find(role: "AXButton", labelled: ["Got it"]),
              let locator = AX.makeLocator(for: f.element, pid: AX.pid(f.element), clickPoint: nil) else { return nil }
        return PopupRule(name: "Cookie banner", bundleID: safariID,
                         detect: ["We use cookies to make this page work."], dismiss: .click(target: locator))
    }

    static func closeTabs(_ count: Int) async {
        guard count > 0, let app = NSRunningApplication.runningApplications(withBundleIdentifier: safariID).first else { return }
        app.activate(options: [.activateIgnoringOtherApps])
        try? await Task.sleep(nanoseconds: 400_000_000)
        for _ in 0..<count {
            guard window() != nil else { break }
            Input.key(13, modifiers: CGEventFlags.maskCommand.rawValue)   // ⌘W
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}
