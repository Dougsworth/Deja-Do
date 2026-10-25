import AppKit
import ApplicationServices
import DejaDoCore

/// Plays an automation back. Runs off the main thread; reports through callbacks.
final class Replayer {
    struct Settings {
        /// Which AI service and model to ask, with its key.
        var ai: AIConfig
        var aiEnabled: Bool
        /// Learned match weights per app bundle ID.
        var weights: [String: MatchWeights] = [:]
        /// Look at the screen for apps that don't describe their buttons. Needs Screen Recording.
        var visionEnabled = false
        /// Confirm each step changed the screen the way it did when recorded.
        var checkSteps = true
        var findTimeout: Double = 6
    }

    struct Callbacks {
        /// Index of the step about to run.
        var progress: (Int) -> Void
        /// Ask the user for text (passwords, "ask each run" steps). Return nil to cancel.
        var askText: (_ prompt: String, _ secret: Bool) async -> String?
        /// A click step's locator was refreshed. `byAI` is true when the AI found it.
        var learned: (_ stepIndex: Int, _ locator: ElementLocator, _ byAI: Bool) -> Void
        /// What a step actually did, shown under it after the run.
        var note: (_ stepIndex: Int, _ text: String) -> Void
        /// Match weights for an app were tuned after an AI fix.
        var tuned: (_ bundleID: String, _ weights: MatchWeights) -> Void
    }

    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cancelled }
        set { lock.lock(); _cancelled = newValue; lock.unlock() }
    }

    func cancel() { isCancelled = true }

    private var weights: [String: MatchWeights] = [:]
    /// What each step did this run, joined into one line under the step.
    private var notes: [Int: [String]] = [:]
    private var noteSink: ((Int, String) -> Void)?

    func run(_ automation: Automation, settings: Settings, callbacks: Callbacks,
             values: [String: String] = [:]) async throws {
        isCancelled = false
        weights = settings.weights
        notes = [:]
        noteSink = callbacks.note
        guard AXIsProcessTrusted() else { throw ReplayError("Deja Do needs Accessibility permission to run automations.") }
        // When what gets typed changes from run to run, text that came from
        // typing during the recording can't be expected to show up again.
        let typingVaries = automation.steps.contains { step in
            if case .type(let text, let ask, let secret, _) = step.kind {
                return ask || secret || !Variables.names(in: text).isEmpty
            }
            return false
        }
        // A moment to let go of the mouse.
        try await pause(0.5)

        for (i, step) in automation.steps.enumerated() {
            try checkCancelled()
            callbacks.progress(i)

            // Read the screen before steps that will be checked afterwards.
            var expectation = settings.checkSteps ? step.expect.flatMap { $0.changed ? $0 : nil } : nil
            if typingVaries { expectation = expectation?.withoutTyped() }
            if expectation != nil, !Self.isCheckable(step) { expectation = nil }
            var before: ScreenState?
            if let e = expectation {
                before = await ScreenStateReader.read(pid: nil, ocr: settings.visionEnabled && e.usedOCR,
                                                      pixels: settings.visionEnabled)
            }

            try await perform(step, index: i, settings: settings, callbacks: callbacks, values: values)
            // Move on as soon as the screen stops changing, not after a fixed guess.
            try await pause(0.08)
            await settleFrontmost(maxWait: 2.0)

            if let expectation {
                try await confirm(step, index: i, expectation: expectation, before: before,
                                  settings: settings, callbacks: callbacks, values: values)
            }
        }
    }

    /// Clicks and key presses are what change screens, and the only steps
    /// safe to repeat when one plainly didn't land.
    static func isCheckable(_ step: Step) -> Bool {
        switch step.kind {
        case .click, .key: return true
        default: return false
        }
    }

    private func perform(_ step: Step, index i: Int, settings: Settings, callbacks: Callbacks,
                         values: [String: String]) async throws {
        switch step.kind {
        case .activate(let bundleID, let name):
            try await activate(bundleID: bundleID, name: name)

        case .click(let target, let button, let count, let modifiers):
            // Apps that don't describe their buttons: find the spot by how it looks.
            // A click recorded only by position has nothing else to go on, so it
            // gets the full wait. One big unlabelled element falls back to Accessibility sooner.
            if target.prefersVisual, settings.visionEnabled,
               let point = await locateVisually(target, stepIndex: i,
                                                timeout: target.role == AX.positionRole ? settings.findTimeout : 3) {
                Input.click(at: point, button: button, count: count, modifiers: modifiers)
                break
            }
            if target.role == AX.positionRole {
                try await clickPosition(target, button: button, count: count, modifiers: modifiers)
                note(i, target.visual != nil && settings.visionEnabled
                     ? "Clicked by position: couldn't find it on screen with confidence"
                     : "Clicked by position: the app didn't say what was here when recorded")
                break
            }
            switch try await locate(target, stepIndex: i, settings: settings, callbacks: callbacks) {
            case .element(let match):
                try click(match: match, target: target, button: button, count: count, modifiers: modifiers)
            case .point(let p):
                Input.click(at: p, button: button, count: count, modifiers: modifiers)
            }

        case .type(let text, let ask, let secret, let prompt):
            var toType = Variables.fill(text, with: values)
            if ask || secret {
                let front = NSWorkspace.shared.frontmostApplication
                let label = prompt.isEmpty ? "Text to type" : prompt
                guard let answer = await callbacks.askText(label, secret) else { throw ReplayError("Stopped.") }
                toType = answer
                front?.activate(options: [.activateIgnoringOtherApps])
                try await pause(0.4)
            }
            Input.type(toType)

        case .key(let code, let modifiers, _):
            Input.key(code, modifiers: modifiers)

        case .wait(let seconds):
            try await pause(seconds)
        }
    }

    // MARK: Checking

    /// Compares the screen after a step with how it looked after the same
    /// step when recorded. Waits a little if the app is slow, repeats the step
    /// once if nothing at all happened, and stops the run if it still doesn't match.
    private func confirm(_ step: Step, index i: Int, expectation e: StepExpectation, before: ScreenState?,
                         settings: Settings, callbacks: Callbacks, values: [String: String]) async throws {
        var loop = StepCheckLoop(policy: step.onMismatch ?? .default, canRedo: Self.isCheckable(step))
        let ocr = settings.visionEnabled && e.usedOCR
        while true {
            try checkCancelled()
            let after = await ScreenStateReader.read(pid: nil, ocr: ocr, pixels: settings.visionEnabled)
            let result = StepVerifier.check(e, before: before, after: after)
            switch loop.next(result) {
            case .proceed(let extra):
                if result.verdict == .passed, e.hasChecks { note(i, "Screen matched") }
                if let extra { note(i, extra) }
                return
            case .recheck(let delay):
                try await pause(delay)
                await settleFrontmost(maxWait: 1.0)
            case .redo:
                note(i, "Didn't seem to take, trying once more")
                try await perform(step, index: i, settings: settings, callbacks: callbacks, values: values)
                try await pause(0.08)
                await settleFrontmost(maxWait: 2.0)
            case .stop(let reason):
                note(i, reason)
                throw ReplayError("Stopped at step \(i + 1): \(reason). Change what happens on a mismatch under the step if this is expected.")
            }
        }
    }

    private func note(_ i: Int, _ text: String) {
        notes[i, default: []].append(text)
        noteSink?(i, notes[i]!.joined(separator: " · "))
    }

    // MARK: Vision

    /// Finds a recorded spot by the text and picture around it. Returns a
    /// screen point to click, or nil when it couldn't be found with confidence in time.
    private func locateVisually(_ target: ElementLocator, stepIndex: Int, timeout: Double) async -> CGPoint? {
        guard let visual = target.visual else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        let matcher = VisualMatcher()
        repeat {
            if isCancelled { return nil }
            await settle(bundleID: target.bundleID, maxWait: 1.0)
            if let root = ElementFinder.root(for: target), let wf = root.windowFrame,
               let read = await ScreenVision.read(windowFrame: wf, ocr: visual.clickedText != nil || !visual.nearby.isEmpty) {
                let report = matcher.match(visual, window: read.image, lines: read.lines, windowSize: wf.size)
                if case .confident(let best) = report.decision {
                    note(stepIndex, "Found on screen \(Self.describe(best, visual)) · \(Int((best.score * 100).rounded()))% match")
                    return CGPoint(x: wf.minX + best.point.x, y: wf.minY + best.point.y)
                }
            }
            try? await pause(0.3)
        } while Date() < deadline
        return nil
    }

    static func describe(_ c: VisualCandidate, _ v: VisualTarget) -> String {
        if let text = v.clickedText?.text, (c.parts[.text] ?? 0) >= 0.75 { return "by its label “\(text.prefix(40))”" }
        if c.source == .anchor || (c.parts[.anchor] ?? 0) >= 0.6 { return "by the text around it" }
        return "by how it looks"
    }

    // MARK: Steps

    private func activate(bundleID: String, name: String) async throws {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        func openWithLaunchServices() async {
            guard let url else { return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        }

        if let app = ElementFinder.runningApp(bundleID) {
            // macOS 14 can ignore activate() from a background app, so also ask
            // through Accessibility, which a trusted app is allowed to do.
            app.activate(options: [.activateIgnoringOtherApps])
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                         kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        } else if url != nil {
            await openWithLaunchServices()
        } else {
            throw ReplayError("Couldn't find the app \(name).")
        }

        var triedLaunchServices = false
        let deadline = Date().addingTimeInterval(10)
        while NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID {
            try checkCancelled()
            if Date() > deadline { throw ReplayError("\(name) didn't come to the front.") }
            if !triedLaunchServices, Date() > deadline.addingTimeInterval(-8.5) {
                triedLaunchServices = true
                await openWithLaunchServices()
            }
            try await pause(0.15)
        }
        await settle(bundleID: bundleID, maxWait: 3)
    }

    private func engine(for bundleID: String) -> MatchEngine {
        MatchEngine(weights: weights[bundleID] ?? MatchWeights())
    }

    /// Where to click: an accessibility element, or a screen point found by vision.
    enum Hit {
        case element(ElementFinder.Match)
        case point(CGPoint)
    }

    private func locate(_ target: ElementLocator, stepIndex: Int, settings: Settings,
                        callbacks: Callbacks) async throws -> Hit {
        let deadline = Date().addingTimeInterval(settings.findTimeout)
        var last: ElementFinder.Outcome?
        repeat {
            try checkCancelled()
            await settle(bundleID: target.bundleID, maxWait: 1.5)
            if let o = ElementFinder.find(target, engine: engine(for: target.bundleID)) {
                last = o
                if case .confident(let best) = o.report.decision {
                    let el = o.element(for: best)
                    // Self healing: a confident but imperfect match means the
                    // element drifted. Remember how it looks now.
                    if best.score < 0.92, let fresh = AX.makeLocator(for: el, pid: AX.pid(el), clickPoint: nil) {
                        var u = fresh
                        u.clickOffset = target.clickOffset
                        u.visual = target.visual
                        callbacks.learned(stepIndex, u, false)
                    }
                    let snap = o.snapshot(for: best)
                    note(stepIndex, "Found \(Self.describe(snap)) · \(Int((best.score * 100).rounded()))% match")
                    return .element(ElementFinder.Match(element: el, windowFrame: o.root.windowFrame))
                }
            }
            try await pause(0.25)
        } while Date() < deadline

        // Before asking the AI, see whether the screen itself shows where it went.
        if settings.visionEnabled, target.visual != nil, !target.prefersVisual,
           let point = await locateVisually(target, stepIndex: stepIndex, timeout: 1.5) {
            return .point(point)
        }

        let what = Step(kind: .click(target: target, button: .left, count: 1, modifiers: 0)).summary
        guard settings.aiEnabled else {
            throw ReplayError("Couldn't find “\(what)” with confidence. Turn on AI in Settings to let it look.")
        }
        if let problem = settings.ai.problem {
            throw ReplayError("Couldn't find “\(what)” with confidence. \(problem)")
        }
        guard let outcome = last, !outcome.snapshots.isEmpty else {
            throw ReplayError("Couldn't read the \(target.appName) window to look for “\(what)”.")
        }

        let shortlist: [RankedCandidate]
        switch outcome.report.decision {
        case .ambiguous(let list), .notFound(let list): shortlist = list
        case .confident(let c): shortlist = [c]
        }
        let choice = try await AIRepair(config: settings.ai)
            .choose(target: target, shortlist: shortlist.map { (snapshot: outcome.snapshot(for: $0), score: $0.score) })
        guard choice.index >= 0, choice.index < shortlist.count else {
            throw ReplayError("Couldn't find “\(what)”, and AI didn't see a match: \(choice.reason ?? "no reason given").")
        }

        let chosen = shortlist[choice.index]
        // Learn from the correction so this app needs the AI less next time.
        var w = weights[target.bundleID] ?? MatchWeights()
        w.learn(chosen: chosen.features, others: shortlist.filter { $0.index != chosen.index }.map(\.features))
        weights[target.bundleID] = w
        callbacks.tuned(target.bundleID, w)

        let el = outcome.element(for: chosen)
        if let updated = AX.makeLocator(for: el, pid: AX.pid(el), clickPoint: nil) {
            var u = updated
            u.clickOffset = target.clickOffset
            u.visual = target.visual
            callbacks.learned(stepIndex, u, true)
        }
        note(stepIndex, "AI picked \(Self.describe(outcome.snapshot(for: chosen))): \(choice.reason ?? "")")
        return .element(ElementFinder.Match(element: el, windowFrame: outcome.root.windowFrame))
    }

    private func click(match: ElementFinder.Match, target: ElementLocator, button: MouseButtonKind,
                       count: Int, modifiers: UInt64) throws {
        let el = match.element
        let role = AX.role(el)
        let actions = AX.actions(el)

        // Menu items work best pressed directly; their menus may not be open.
        if (target.inMenu || role.hasPrefix("AXMenu")), button == .left, actions.contains(kAXPressAction) {
            if AX.perform(el, kAXPressAction) { return }
        }
        if actions.contains("AXScrollToVisible") {
            AX.perform(el, "AXScrollToVisible")
            usleep(250_000)
        }
        guard let f = AX.frame(el), f.width > 0, f.height > 0 else {
            if actions.contains(kAXPressAction), AX.perform(el, kAXPressAction) { return }
            throw ReplayError("Found the element but couldn't tell where it is on screen.")
        }
        let ox = min(max(target.clickOffset.x, 0.1), 0.9)
        let oy = min(max(target.clickOffset.y, 0.1), 0.9)
        let point = CGPoint(x: f.minX + f.width * ox, y: f.minY + f.height * oy)
        Input.click(at: point, button: button, count: count, modifiers: modifiers)
    }

    static func describe(_ s: ElementSnapshot) -> String {
        let role = Step.friendlyRole(s.role, subrole: s.subrole)
        if let l = s.label { return "\(role) “\(l.prefix(40))”" }
        if let f = s.frame { return "\(role) at \(Int(f.midX)), \(Int(f.midY))" }
        return role
    }

    /// Replays a click recorded only by position, scaled if the window was resized.
    private func clickPosition(_ target: ElementLocator, button: MouseButtonKind, count: Int,
                               modifiers: UInt64) async throws {
        await settle(bundleID: target.bundleID, maxWait: 1.5)
        guard let root = ElementFinder.root(for: target), let wf = root.windowFrame,
              let spot = target.frameInWindow else {
            throw ReplayError("Couldn't find the \(target.appName) window to click in.")
        }
        var x = spot.midX, y = spot.midY
        if let old = target.windowSize, old.width > 0, old.height > 0 {
            x = x * wf.width / old.width
            y = y * wf.height / old.height
        }
        Input.click(at: CGPoint(x: wf.minX + x, y: wf.minY + y), button: button, count: count, modifiers: modifiers)
    }

    // MARK: Waiting

    /// Polls the app's focused window until it stops changing.
    private func settle(bundleID: String, maxWait: Double) async {
        guard let app = ElementFinder.runningApp(bundleID) else { return }
        await settle(pid: app.processIdentifier, maxWait: maxWait)
    }

    private func settleFrontmost(maxWait: Double) async {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        await settle(pid: app.processIdentifier, maxWait: maxWait)
    }

    private func settle(pid: pid_t, maxWait: Double) async {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var detector = SettleDetector(quietPeriod: 0.2)
        let start = Date()
        while !isCancelled {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= maxWait { return }
            let root = AX.element(appElement, kAXFocusedWindowAttribute) ?? appElement
            let (hash, busy) = AX.fingerprint(root)
            if detector.observe(fingerprint: hash, busy: busy, at: Date().timeIntervalSince(start)) { return }
            try? await Task.sleep(nanoseconds: 90_000_000)
        }
    }

    // MARK: Helpers

    private func checkCancelled() throws {
        if isCancelled { throw ReplayError("Stopped.") }
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    }
}
