import AppKit
import ApplicationServices
@preconcurrency import DejaDoCore

/// End to end checks against a web form in Safari and Chrome, served by Deja Do itself
/// (see TestServer). One recording of "fill the form and press Submit" is
/// replayed against every way the page can break, and the server's own
/// counter says whether the form was submitted exactly once, never, or twice.
///
/// Twice is the one result that must never happen. Once is the goal. A stop
/// before anything was sent is acceptable whenever the page changed enough
/// that acting would be a guess.
enum WebSelfTest {
    static let safariID = "com.apple.Safari"
    static let chromeID = "com.google.Chrome"
    static let pageTitle = "Deja Do test form"

    /// The browser the current suite drives.
    final class Current: @unchecked Sendable {
        private let lock = NSLock()
        private var id = WebSelfTest.safariID
        var browserID: String {
            get { lock.lock(); defer { lock.unlock() }; return id }
            set { lock.lock(); id = newValue; lock.unlock() }
        }
    }
    static let current = Current()
    static var browserID: String { current.browserID }
    static var browserName: String { browserID == chromeID ? "Chrome" : "Safari" }

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
        let server = TestServer()
        guard server.start() else {
            log.check("Test page server starts", false)
            return false
        }
        log.check("Test page server starts", true, "port \(server.port)")
        defer { server.stop() }

        let only = SelfTest.suites.contains("chrome") ? [chromeID] : [safariID, chromeID]
        for id in only {
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil else {
                log.check("Web form in \(id == chromeID ? "Chrome" : "Safari")", true, "not installed, skipped", counted: false)
                continue
            }
            current.browserID = id
            log.line("Web form in \(browserName)")
            let opened = Counter()
            server.reset()
            guard await open(server.url(breaks: []), waitForButton: true) else {
                log.check("\(browserName) shows the test page", false, diagnose())
                continue
            }
            opened.add()
            log.check("\(browserName) shows the test page", true)
            let recorded = await replays(log, server: server, vision: vision, opened: opened)
            if id == safariID {
                if let task = recorded.task { await aiRepair(log, task: task, server: server, vision: vision, opened: opened) }
                _ = await spanish(log, server: server, vision: vision, opened: opened)
            }
            await closeTabs(opened.value)
        }
        current.browserID = safariID
        return log.failures == failuresBefore
    }

    /// The same form in Spanish: recorded and replayed with Spanish labels, so
    /// nothing about finding things or spotting risky steps leans on English.
    static func spanish(_ log: SelfTest.Log, server: TestServer, vision: Bool, opened: Counter) async -> Bool {
        let failuresBefore = log.failures
        log.line("Web form in Spanish")
        server.reset()
        guard await open(server.url(breaks: [], spanish: true), waitForButton: true) else {
            log.check("The Spanish page loads", false)
            return false
        }
        opened.add()
        let recorder = await MainActor.run { () -> Recorder in
            let r = Recorder()
            r.visionEnabled = vision
            r.checkSteps = true
            _ = r.start()
            return r
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        var acted = await click(field: "Nombre")
        acted = type("Ana") && acted
        acted = await click(field: "Correo") && acted
        acted = type("ana@example.com") && acted
        acted = await click(button: "Enviar") && acted
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let steps: [Step] = await withCheckedContinuation { cont in
            DispatchQueue.main.async { recorder.finish { cont.resume(returning: $0) } }
        }
        log.check("Recorded the Spanish form", acted && server.state.submits == 1, steps.map(\.summary).joined(separator: " | "))
        let task = Automation(name: "Self test Spanish form", steps: steps)
        guard let i = task.steps.lastIndex(where: { if case .click = $0.kind { return true }; return false }), acted else { return false }
        log.check("“Enviar” is recognised as a risky step", task.risk(at: i).risk == .risky, task.risk(at: i).reason ?? "not flagged")
        log.check("Recorded what “Enviar” changed", task.steps[i].expect.map { !$0.appeared.isEmpty } == true,
                  task.steps[i].expect?.summary ?? "nothing")
        for (name, breaks) in [("Spanish page, same", [TestServer.Break]()), ("Spanish page, fields reordered and button moved", [.move]),
                               ("Spanish page, button renamed to “Enviar solicitud”", [.rename])] {
            server.reset()
            guard await open(server.url(breaks: breaks, spanish: true), waitForButton: true) else {
                log.check(name, false, "the page didn't load")
                continue
            }
            opened.add()
            let (error, notes) = await SelfTest.runTask(task, vision: vision)
            let s = server.state
            log.check(name, error == nil && s.submits == 1 && s.lastName == "Ana",
                      "submits \(s.submits)" + (error.map { " · stopped: \($0)" } ?? ""))
            if s.submits > 1 { log.line("      SUBMITTED TWICE, this must never happen") }
            log.line("      notes: \(notes)")
        }
        return log.failures == failuresBefore
    }

    final class Counter: @unchecked Sendable {
        private(set) var value = 0
        func add() { value += 1 }
    }

    static func replays(_ log: SelfTest.Log, server: TestServer, vision: Bool, opened: Counter) async -> (passed: Bool, task: Automation?) {
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
            return (false, nil)
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
            let rightValues: Bool = s.lastName == "Ana" && s.lastEmail == "ana@example.com"
            let finished: Bool = error == nil
            let sentOnce: Bool = s.submits == 1
            let sentNothing: Bool = s.submits == 0
            let noWrongButton: Bool = s.feedback == 0
            let ok: Bool
            switch scenario.rule {
            case .mustSubmit:
                ok = finished && sentOnce && noWrongButton && rightValues && !retried
            case .submitOrStop:
                let good: Bool = finished && sentOnce && rightValues
                let safe: Bool = !finished && sentNothing
                ok = noWrongButton && !retried && (good || safe)
            case .mustStop:
                ok = !finished && sentNothing && s.confirms == 0 && !retried
            }
            log.check(scenario.name, ok, detail)
            if s.submits > 1 { log.line("      SUBMITTED TWICE, this must never happen") }
            log.line("      notes: \(notes)")
        }
        return (log.failures == failuresBefore, task)
    }

    /// AI repair, end to end, against a stand-in AI service (see StandInAI).
    /// The button is relabelled "Send", moved, and given a new id, so nothing
    /// the recording knows finds it. AI has to pick it; because Submit sends,
    /// the person must be asked first; and once fixed, the next run must not
    /// need AI at all.
    static func aiRepair(_ log: SelfTest.Log, task: Automation, server: TestServer, vision: Bool, opened: Counter) async {
        log.line("AI repair")
        let ai = StandInAI()
        guard ai.start() else { log.check("Stand-in AI service starts", false); return }
        defer { ai.stop() }
        let config = AIConfig(provider: .ollama, model: "stand-in", baseURL: ai.baseURL)
        let breaks: [TestServer.Break] = [.relabel, .move, .idswap]
        guard let submit = task.steps.lastIndex(where: { if case .click = $0.kind { return true }; return false }) else { return }

        final class Box: @unchecked Sendable {
            var asked: [String] = []
            var learned: ElementLocator?
            var byAI = false
        }

        // 1. AI finds it, the person is asked, it's sent once, and the fix is kept.
        server.reset(); ai.reset()
        guard await open(server.url(breaks: breaks), waitForButton: true) else { log.check("AI: page loads", false); return }
        opened.add()
        let box = Box()
        let first = await SelfTest.runTaskReading(task, vision: vision, ai: config,
            confirm: { q, _ in box.asked.append(q); return true },
            learned: { i, l, byAI in if i == submit { box.learned = l; box.byAI = byAI } })
        var s = server.state
        log.check("AI: finds the relabelled, moved button and it's sent once", first.error == nil && s.submits == 1 && s.feedback == 0,
                  "submits \(s.submits), AI asked \(ai.calls) time\(ai.calls == 1 ? "" : "s")" + (first.error.map { " · stopped: \($0)" } ?? ""))
        log.check("AI: the question names what was recorded", ai.lastPrompt?.contains("label=\"Submit\"") == true)
        log.check("AI: asks you before clicking a step that sends", box.asked.contains { $0.contains("Send") }, box.asked.joined(separator: " / "))
        log.check("AI: keeps the fix", box.learned?.label == "Send" && box.byAI, box.learned?.label ?? "nothing learned")
        log.line("      notes: \(first.notes)")

        // 2. With the fix applied, the same broken page needs no AI.
        var fixed = task
        if let l = box.learned, case .click(_, let b, let c, let m) = fixed.steps[submit].kind {
            fixed.steps[submit].kind = .click(target: l, button: b, count: c, modifiers: m)
        }
        server.reset(); ai.reset()
        if await open(server.url(breaks: breaks), waitForButton: true) {
            opened.add()
            let second = await SelfTest.runTaskReading(fixed, vision: vision, ai: config)
            s = server.state
            log.check("AI: next run needs no AI", second.error == nil && s.submits == 1 && ai.calls == 0,
                      "submits \(s.submits), AI asked \(ai.calls) times" + (second.error.map { " · stopped: \($0)" } ?? ""))
        }

        // 3. Saying no stops the run with nothing sent.
        server.reset(); ai.reset()
        if await open(server.url(breaks: breaks), waitForButton: true) {
            opened.add()
            let declined = await SelfTest.runTaskReading(task, vision: vision, ai: config, confirm: { _, _ in false })
            s = server.state
            log.check("AI: saying no to its pick stops with nothing sent", declined.error != nil && s.submits == 0,
                      declined.error ?? "it finished")
        }

        // 4. When AI sees nothing that fits, the run stops rather than guessing.
        server.reset(); ai.reset(); ai.mode = .refuses
        if await open(server.url(breaks: breaks), waitForButton: true) {
            opened.add()
            let refused = await SelfTest.runTaskReading(task, vision: vision, ai: config)
            s = server.state
            log.check("AI: when it finds nothing, the run stops with nothing sent", refused.error != nil && s.submits == 0,
                      refused.error ?? "it finished")
        }
        ai.mode = .sensible

        // 5. The AI service set up in Settings, if any. Reported, not counted: it costs a request and needs the network.
        if let real = configuredAI() {
            server.reset()
            if await open(server.url(breaks: breaks), waitForButton: true) {
                opened.add()
                let r = await SelfTest.runTaskReading(task, vision: vision, ai: real)
                s = server.state
                log.check("AI: your \(real.provider.name) (\(real.model)) finds it too", r.error == nil && s.submits == 1,
                          "submits \(s.submits)" + (r.error.map { " · stopped: \($0)" } ?? ""), counted: false)
            }
        } else {
            log.check("AI: your own AI service", true, "none set up in Settings, skipped", counted: false)
        }
    }

    /// The AI service chosen in Settings, when it's ready to use.
    static func configuredAI() -> AIConfig? {
        let d = UserDefaults.standard
        guard let raw = d.string(forKey: "aiProvider"), let p = AIProvider(rawValue: raw), p != .dejaDo else { return nil }
        let key = p.keychainAccount.flatMap { Keychain.get($0) } ?? ""
        let base: String? = p == .ollama ? (d.string(forKey: "ollamaURL") ?? AIRequest.ollamaDefault) : nil
        let c = AIConfig(provider: p, model: AppModel.savedModel(for: p), key: key, baseURL: base)
        return c.problem == nil ? c : nil
    }

    // MARK: The browser

    /// Opens the page in the current browser and waits until it's showing.
    static func open(_ url: URL, waitForButton: Bool) async -> Bool {
        guard let browser = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserID) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: config)
        // Up to 40 seconds: a browser starting from cold can take a while.
        for _ in 0..<160 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: browserID).first {
                AX.wake(pid: app.processIdentifier, bundleID: browserID)
            }
            guard let w = window(), AX.string(w, kAXTitleAttribute)?.contains(pageTitle) == true else { continue }
            if !waitForButton || find(role: "AXButton", labelled: ["Submit", "Submit request", "Send", "Enviar", "Enviar solicitud"]) != nil {
                try? await Task.sleep(nanoseconds: 700_000_000)
                NSRunningApplication.runningApplications(withBundleIdentifier: browserID).first?
                    .activate(options: [.activateIgnoringOtherApps])
                return true
            }
        }
        return false
    }

    /// What the browser looks like to Accessibility, for when the page can't be found.
    static func diagnose() -> String {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: browserID).first else { return "\(browserName) isn't running" }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 1.0)
        let ws = AX.elements(AX.raw(el, kAXWindowsAttribute))
        let titles = ws.map { "“\(AX.string($0, kAXTitleAttribute) ?? "")”" }.joined(separator: ", ")
        let w = window()
        let areas = w.map { AX.collect(from: $0, origin: nil, limit: 3000) { $0 == "AXWebArea" } } ?? []
        let buttons = w.map { AX.collect(from: $0, origin: nil, limit: 3000) { $0 == "AXButton" } } ?? []
        let named = buttons.compactMap(\.node.label).prefix(8).joined(separator: ", ")
        let url = areas.compactMap { AX.url(of: $0.element)?.absoluteString }.joined(separator: " ")
        return "front \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"); windows \(titles); web areas \(areas.count) \(url); buttons \(buttons.count): \(named)"
    }

    static func window() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: browserID).first else { return nil }
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

    /// The text field named `label`, or else the one just below the text `label`,
    /// for browsers that don't pass the form's label on to the field.
    static func field(_ label: String) -> AX.Found? {
        if let f = find(role: "AXTextField", labelled: [label]) { return f }
        guard let w = window(), let text = AX.collect(from: w, origin: nil, limit: 1500, include: { $0 == "AXStaticText" })
                .first(where: { $0.node.label?.lowercased() == label.lowercased() }), let tf = text.node.frame else { return nil }
        return AX.collect(from: w, origin: nil, limit: 1500) { $0 == "AXTextField" }
            .filter { ($0.node.frame?.minY ?? -1) >= tf.minY }
            .min { abs(($0.node.frame?.minY ?? 0) - tf.maxY) < abs(($1.node.frame?.minY ?? 0) - tf.maxY) }
    }

    static func click(field: String) async -> Bool {
        guard let f = Self.field(field), let frame = f.node.frame else { return false }
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
        return PopupRule(name: "Cookie banner", bundleID: browserID,
                         detect: ["We use cookies to make this page work."], dismiss: .click(target: locator))
    }

    static func closeTabs(_ count: Int) async {
        guard count > 0, let app = NSRunningApplication.runningApplications(withBundleIdentifier: browserID).first else { return }
        app.activate(options: [.activateIgnoringOtherApps])
        try? await Task.sleep(nanoseconds: 400_000_000)
        // Only ever close a tab that is showing the test page, never one of the person's own.
        let el = AXUIElementCreateApplication(app.processIdentifier)
        for _ in 0..<(count + 2) {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == browserID,
                  let front = AX.element(el, kAXFocusedWindowAttribute),
                  AX.string(front, kAXTitleAttribute)?.contains(pageTitle) == true else { break }
            Input.key(13, modifiers: CGEventFlags.maskCommand.rawValue)   // ⌘W
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
    }
}
