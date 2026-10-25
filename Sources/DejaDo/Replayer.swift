import AppKit
import ApplicationServices
import DejaDoCore

/// Plays an automation back. Runs off the main thread; reports through callbacks.
final class Replayer {
    struct Settings {
        var apiKey: String?
        var model: String
        var aiEnabled: Bool
        /// Learned match weights per app bundle ID.
        var weights: [String: MatchWeights] = [:]
        var findTimeout: Double = 6
    }

    struct Callbacks {
        /// Index of the step about to run.
        var progress: (Int) -> Void
        /// Ask the user for text (passwords, "ask each run" steps). Return nil to cancel.
        var askText: (_ prompt: String, _ secret: Bool) async -> String?
        /// A click step's locator was refreshed. `byAI` is true when the AI found it.
        var learned: (_ stepIndex: Int, _ locator: ElementLocator, _ byAI: Bool) -> Void
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

    func run(_ automation: Automation, settings: Settings, callbacks: Callbacks) async throws {
        isCancelled = false
        weights = settings.weights
        guard AXIsProcessTrusted() else { throw ReplayError("Deja Do needs Accessibility permission to run automations.") }
        // A moment to let go of the mouse.
        try await pause(0.5)

        for (i, step) in automation.steps.enumerated() {
            try checkCancelled()
            callbacks.progress(i)
            switch step.kind {
            case .activate(let bundleID, let name):
                try await activate(bundleID: bundleID, name: name)

            case .click(let target, let button, let count, let modifiers):
                let match = try await locate(target, stepIndex: i, settings: settings, callbacks: callbacks)
                try click(match: match, target: target, button: button, count: count, modifiers: modifiers)

            case .type(let text, let ask, let secret, let prompt):
                var toType = text
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
            // Move on as soon as the screen stops changing, not after a fixed guess.
            try await pause(0.08)
            await settleFrontmost(maxWait: 2.0)
        }
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

    private func locate(_ target: ElementLocator, stepIndex: Int, settings: Settings,
                        callbacks: Callbacks) async throws -> ElementFinder.Match {
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
                        callbacks.learned(stepIndex, u, false)
                    }
                    return ElementFinder.Match(element: el, windowFrame: o.root.windowFrame)
                }
            }
            try await pause(0.25)
        } while Date() < deadline

        let what = Step(kind: .click(target: target, button: .left, count: 1, modifiers: 0)).summary
        guard settings.aiEnabled, let key = settings.apiKey, !key.isEmpty else {
            throw ReplayError("Couldn't find “\(what)” with confidence. Add an API key in Settings to let AI look for it.")
        }
        guard let outcome = last, !outcome.snapshots.isEmpty else {
            throw ReplayError("Couldn't read the \(target.appName) window to look for “\(what)”.")
        }

        let shortlist: [RankedCandidate]
        switch outcome.report.decision {
        case .ambiguous(let list), .notFound(let list): shortlist = list
        case .confident(let c): shortlist = [c]
        }
        let choice = try await AIRepair(apiKey: key, model: settings.model)
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
            callbacks.learned(stepIndex, u, true)
        }
        return ElementFinder.Match(element: el, windowFrame: outcome.root.windowFrame)
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
