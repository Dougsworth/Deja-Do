import AppKit
import ApplicationServices
@preconcurrency import DejaDoCore

/// Why a run stopped, where, and what may already have happened.
struct ReplayStop: LocalizedError {
    let message: String
    let step: Int
    let outcome: RunOutcome
    var errorDescription: String? { message }
}

/// Plays an automation back. Runs off the main thread; reports through callbacks.
final class Replayer: @unchecked Sendable {
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
        /// Ask before every step that sends, saves or deletes.
        var askBeforeRisky = false
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
        /// Ask the person a yes or no question. Return false to stop.
        var confirm: (_ question: String, _ detail: String) async -> Bool = { _, _ in true }
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
    private(set) var notes: [Int: [String]] = [:]
    private var noteSink: ((Int, String) -> Void)?
    /// The app the current step is meant for. Input is only sent while it's in front.
    private var expectedApp: (bundleID: String, name: String)?
    private var goal: String?
    /// The closest the screen search came, for explaining why it didn't click.
    private var lastVisualMiss: String?

    /// Runs the task. Throws `ReplayStop` saying where it stopped and whether a
    /// step that sends, saves or deletes had already run.
    func run(_ automation: Automation, settings: Settings, callbacks: Callbacks,
             values: [String: String] = [:]) async throws {
        isCancelled = false
        weights = settings.weights
        notes = [:]
        noteSink = callbacks.note
        expectedApp = nil
        goal = automation.goal
        guard AXIsProcessTrusted() else {
            throw ReplayStop(message: "Deja Do needs Accessibility permission to run automations.", step: 0,
                             outcome: .stoppedBeforeChanges(atStep: 0))
        }
        // When what gets typed changes from run to run, text that came from
        // typing during the recording can't be expected to show up again.
        let typingVaries = automation.steps.contains { step in
            if case .type(let text, let ask, let secret, _) = step.kind {
                return ask || secret || !Variables.names(in: text).isEmpty
            }
            return false
        }
        var riskyDone: [Int] = []
        var current = 0
        do {
            // A moment to let go of the mouse.
            try await pause(0.5)

            for (i, step) in automation.steps.enumerated() {
                current = i
                try checkCancelled()
                callbacks.progress(i)
                guard step.isEnabled else { note(i, "Skipped"); continue }

                try await closePopups(automation, beforeStep: i)
                let risk = automation.risk(at: i)
                let risky = risk.risk == .risky
                if risky && settings.askBeforeRisky {
                    let ok = await callbacks.confirm("Run step \(i + 1)?", "\(step.safeSummary). \(risk.reason ?? "This step sends, saves or deletes.")")
                    if !ok { throw ReplayError("Stopped before step \(i + 1), as asked.", cancelled: true) }
                }

                // Read the screen before steps that will be checked afterwards.
                var expectation = settings.checkSteps ? step.expect.flatMap { $0.changed ? $0 : nil } : nil
                if typingVaries { expectation = expectation?.withoutTyped() }
                if expectation != nil, !Self.isCheckable(step) { expectation = nil }
                var before: ScreenState?
                if let e = expectation {
                    before = await ScreenStateReader.read(pid: pid(for: step), ocr: settings.visionEnabled && e.usedOCR,
                                                          pixels: settings.visionEnabled)
                }

                try await perform(step, index: i, risky: risky, settings: settings, callbacks: callbacks, values: values)
                if risky { riskyDone.append(i) }
                // Move on as soon as the screen stops changing, not after a fixed guess.
                try await pause(0.08)
                await settleFrontmost(maxWait: 2.0)

                if let expectation {
                    try await confirm(step, index: i, risky: risky, expectation: expectation, before: before,
                                      settings: settings, callbacks: callbacks, values: values)
                }
            }
        } catch {
            let cancelled = isCancelled || (error as? ReplayError)?.cancelled == true
            let outcome = RunOutcome.classify(stoppedAt: current, cancelled: cancelled, riskyDone: riskyDone)
            throw ReplayStop(message: error.localizedDescription, step: current, outcome: outcome)
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

    private func perform(_ step: Step, index i: Int, risky: Bool, settings: Settings, callbacks: Callbacks,
                         values: [String: String]) async throws {
        switch step.kind {
        case .activate(let bundleID, let name):
            try await activate(bundleID: bundleID, name: name)
            expectedApp = (bundleID, name)

        case .click(let target, let button, let count, let modifiers):
            expectedApp = (target.bundleID, target.appName)
            // Apps that don't describe their buttons: find the spot by how it looks.
            // A click recorded only by position has nothing else to go on, so it
            // gets the full wait. One big unlabelled element falls back to Accessibility sooner.
            if target.prefersVisual, settings.visionEnabled,
               let point = await locateVisually(target, stepIndex: i,
                                                timeout: target.role == AX.positionRole ? settings.findTimeout : 3) {
                try await ensureFront()
                Input.click(at: point, button: button, count: count, modifiers: modifiers)
                break
            }
            if target.role == AX.positionRole {
                if risky {
                    throw ReplayError("Couldn't find step \(i + 1) on screen, and it sends, saves or deletes, so Deja Do won't click where it used to be.")
                }
                try await ensureFront()
                try await clickPosition(target, button: button, count: count, modifiers: modifiers)
                note(i, target.visual != nil && settings.visionEnabled
                     ? "Clicked by position: couldn't find it on screen with confidence\(lastVisualMiss.map { " (\($0))" } ?? "")"
                     : "Clicked by position: the app didn't say what was here when recorded")
                break
            }
            var hit = try await locate(target, stepIndex: i, risky: risky, settings: settings, callbacks: callbacks)
            for attempt in 0..<2 {
                try await ensureFront()
                switch hit {
                case .element(let match):
                    if try click(match: match, target: target, button: button, count: count, modifiers: modifiers) { return }
                case .point(let p):
                    Input.click(at: p, button: button, count: count, modifiers: modifiers)
                    return
                }
                // Something covered the target. Give it a moment to go away, then look again once.
                guard attempt == 0 else { break }
                note(i, "Something was covering it, looked again")
                try await pause(0.6)
                await settle(bundleID: target.bundleID, maxWait: 1.5)
                hit = try await locate(target, stepIndex: i, risky: risky, settings: settings, callbacks: callbacks)
            }
            throw ReplayError("Something is covering “\(target.label ?? Step.friendlyRole(target.role, subrole: target.subrole))”, like a notification or a dialog, so Deja Do didn't click.")

        case .type(let text, let ask, let secret, let prompt):
            var toType = Variables.fill(text, with: values)
            if ask || secret {
                let label = prompt.isEmpty ? "Text to type" : prompt
                guard let answer = await callbacks.askText(label, secret) else {
                    throw ReplayError("Stopped.", cancelled: true)
                }
                toType = answer
                try await ensureFront(reactivate: true)
                try await pause(0.4)
            }
            try await typeChecked(toType, index: i)

        case .key(let code, let modifiers, _):
            try await ensureFront()
            Input.key(code, modifiers: modifiers)

        case .wait(let seconds):
            try await pause(seconds)
        }
    }

    // MARK: Safety

    /// The app a step acts on, so checks read its window and not whatever is in front.
    private func pid(for step: Step) -> pid_t? {
        let bundleID: String?
        switch step.kind {
        case .click(let t, _, _, _): bundleID = t.bundleID
        case .activate: bundleID = nil
        default: bundleID = expectedApp?.bundleID
        }
        return bundleID.flatMap { ElementFinder.runningApp($0)?.processIdentifier }
    }

    /// Makes sure the app the step is for is still in front before sending it
    /// any input, so nothing lands in a notification, a chat or another window.
    /// Brings it back once if it slipped behind; stops if that doesn't work.
    /// (From MacTape's verifyTarget, MIT.)
    private func ensureFront(reactivate: Bool = true) async throws {
        guard let want = expectedApp else { return }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == want.bundleID { return }
        if reactivate, let app = ElementFinder.runningApp(want.bundleID) {
            app.activate(options: [.activateIgnoringOtherApps])
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                         kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            for _ in 0..<12 {
                try await pause(0.1)
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == want.bundleID {
                    await settle(bundleID: want.bundleID, maxWait: 0.8)
                    return
                }
            }
        }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "another app"
        throw ReplayError("\(want.name) isn't in front any more (\(front) is), so Deja Do stopped before sending it anything.")
    }

    /// Types, then reads the field back. Nothing arrived: type it once more.
    /// Part of it arrived: stop, because typing again would double it.
    /// (Rules from OpenAdapt's typed input check, MIT.)
    private func typeChecked(_ text: String, index i: Int) async throws {
        try await ensureFront()
        let want = expectedApp?.bundleID
        let stillFront = { want == nil || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == want }
        for attempt in 0..<2 {
            let field = AX.focusedField()
            if !Input.type(text, shouldContinue: stillFront) {
                throw ReplayError("\(expectedApp?.name ?? "The app") lost focus while typing, so Deja Do stopped part way through. Check that field before running again.")
            }
            try await pause(0.15)
            guard let field else { return }   // no readable field: nothing to check
            var after: String?
            if let v = AX.raw(field.element, kAXValueAttribute), CFGetTypeID(v) == CFStringGetTypeID() { after = (v as! String) }
            switch TypingCheck.verdict(before: field.value, after: after, typed: text, secure: field.secure) {
            case .landed, .unknown:
                return
            case .partial:
                throw ReplayError("Only part of the text reached \(field.label.map { "“\($0)”" } ?? "the field"). Stopped so it isn't typed twice.")
            case .nothingTyped:
                if attempt == 0 {
                    note(i, "Typing didn't reach the field, typed it once more")
                    AXUIElementSetAttributeValue(field.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    try await pause(0.2)
                } else {
                    throw ReplayError("Typing didn't reach \(field.label.map { "“\($0)”" } ?? "the field"), even on a second try.")
                }
            }
        }
    }

    /// Closes any taught popup that's showing before a step runs.
    private func closePopups(_ automation: Automation, beforeStep i: Int) async throws {
        guard let rules = automation.popups, !rules.isEmpty else { return }
        let screen = await ScreenStateReader.read(pid: nil, ocr: false, pixels: false)
        for rule in rules where rule.matches(screen) {
            switch rule.dismiss {
            case .key(let code, let mods, _):
                Input.key(code, modifiers: mods)
            case .click(let target):
                guard let o = ElementFinder.find(target, engine: engine(for: target.bundleID)),
                      case .confident(let best) = o.report.decision else {
                    throw ReplayError("“\(rule.name)” is in the way and Deja Do couldn't find how to close it.")
                }
                _ = try click(match: ElementFinder.Match(element: o.element(for: best), windowFrame: o.root.windowFrame),
                              target: target, button: .left, count: 1, modifiers: 0)
            }
            try await pause(0.3)
            await settleFrontmost(maxWait: 1.5)
            let after = await ScreenStateReader.read(pid: nil, ocr: false, pixels: false)
            if rule.matches(after) {
                throw ReplayError("“\(rule.name)” is in the way and closing it the usual way didn't work.")
            }
            note(i, "Closed “\(rule.name)” first")
        }
    }

    // MARK: Checking

    /// Compares the screen after a step with how it looked after the same
    /// step when recorded. Waits a little if the app is slow, repeats the step
    /// once if nothing at all happened, and stops the run if it still doesn't match.
    private func confirm(_ step: Step, index i: Int, risky: Bool, expectation e: StepExpectation, before: ScreenState?,
                         settings: Settings, callbacks: Callbacks, values: [String: String]) async throws {
        var loop = StepCheckLoop(policy: step.onMismatch ?? .default, canRedo: Self.isCheckable(step), risky: risky)
        let ocr = settings.visionEnabled && e.usedOCR
        while true {
            try checkCancelled()
            // Read the step's own app, even if something else has jumped in front.
            let after = await ScreenStateReader.read(pid: pid(for: step), ocr: ocr, pixels: settings.visionEnabled)
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
                try await perform(step, index: i, risky: risky, settings: settings, callbacks: callbacks, values: values)
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
        lastVisualMiss = nil
        repeat {
            if isCancelled { return nil }
            await settle(bundleID: target.bundleID, maxWait: 1.0)
            if let root = ElementFinder.root(for: target), let wf = root.windowFrame,
               let read = await ScreenVision.read(windowFrame: wf, ocr: visual.clickedText != nil || !visual.nearby.isEmpty) {
                let report = matcher.match(visual, window: read.image, lines: read.lines, windowSize: wf.size)
                if case .confident(let best) = report.decision {
                    let evidence = best.parts.sorted { $0.key.rawValue < $1.key.rawValue }
                        .map { "\($0.key.rawValue) \(Int(($0.value * 100).rounded()))" }.joined(separator: ", ")
                    note(stepIndex, "Found on screen \(Self.describe(best, visual)) · \(Int((best.score * 100).rounded()))% match (\(evidence))")
                    return CGPoint(x: wf.minX + best.point.x, y: wf.minY + best.point.y)
                }
                if let best = report.best {
                    let evidence = best.parts.sorted { $0.key.rawValue < $1.key.rawValue }
                        .map { "\($0.key.rawValue) \(Int(($0.value * 100).rounded()))" }.joined(separator: ", ")
                    lastVisualMiss = "closest \(Int((best.score * 100).rounded()))% (\(evidence)), \(report.candidates.count) spots, \(read.lines.count) lines of text read"
                } else {
                    lastVisualMiss = "nothing looked like it, \(read.lines.count) lines of text read"
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
        // A freshly opened app may be in front before it has finished launching.
        if let app = ElementFinder.runningApp(bundleID) {
            for _ in 0..<50 where !app.isFinishedLaunching { try await pause(0.1) }
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

    /// Saves a refreshed locator only if it still means the element first recorded.
    private func learn(_ fresh: ElementLocator, from target: ElementLocator, stepIndex: Int, byAI: Bool,
                       risky: Bool, callbacks: Callbacks) {
        if let kept = HealGuard.repaired(fresh, from: target, risky: risky) {
            callbacks.learned(stepIndex, kept, byAI)
        } else {
            note(stepIndex, "Kept the recorded step: what it found looks different from what was recorded")
        }
    }

    private func locate(_ target: ElementLocator, stepIndex: Int, risky: Bool, settings: Settings,
                        callbacks: Callbacks) async throws -> Hit {
        let deadline = Date().addingTimeInterval(settings.findTimeout)
        var last: ElementFinder.Outcome?
        var scrolled = false
        repeat {
            try checkCancelled()
            await settle(bundleID: target.bundleID, maxWait: 1.5)
            if let o = ElementFinder.find(target, engine: engine(for: target.bundleID)) {
                last = o
                if case .confident(let best) = o.report.decision {
                    return confident(o, best, target: target, stepIndex: stepIndex, risky: risky, callbacks: callbacks)
                }
            }
            // Not there yet: it may be scrolled out of view. Look through the list once.
            if !scrolled {
                scrolled = true
                if let o = await scrollSearch(target, stepIndex: stepIndex), case .confident(let best) = o.report.decision {
                    return confident(o, best, target: target, stepIndex: stepIndex, risky: risky, callbacks: callbacks)
                }
            }
            try await pause(0.25)
        } while Date() < deadline

        // Before asking the AI, see whether the screen itself shows where it went.
        if settings.visionEnabled, target.visual != nil, !target.prefersVisual,
           let point = await locateVisually(target, stepIndex: stepIndex, timeout: 1.5) {
            if risky {
                throw ReplayError("Step \(stepIndex + 1) sends, saves or deletes, and could only be found by how the screen looks, so Deja Do didn't click.")
            }
            return .point(point)
        }

        let what = Step(kind: .click(target: target, button: .left, count: 1, modifiers: 0)).summary
        if last?.truncated == true { note(stepIndex, "The window was too big to read completely") }
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
            .choose(target: target, shortlist: shortlist.map { (snapshot: outcome.snapshot(for: $0), score: $0.score) },
                    goal: goal, stepNumber: stepIndex + 1)
        guard choice.index >= 0, choice.index < shortlist.count else {
            throw ReplayError("Couldn't find “\(what)”, and AI didn't see a match: \(choice.reason ?? "no reason given").")
        }

        let chosen = shortlist[choice.index]
        let picked = Self.describe(outcome.snapshot(for: chosen))
        // AI is never trusted alone with a step that sends, saves or deletes.
        if risky {
            let ok = await callbacks.confirm("Click \(picked)?",
                                             "Step \(stepIndex + 1) sends, saves or deletes, and Deja Do couldn't find it with confidence. AI thinks it's \(picked): \(choice.reason ?? "").")
            if !ok { throw ReplayError("Stopped at step \(stepIndex + 1): you chose not to let AI pick it.", cancelled: true) }
        }
        // Learn from the correction so this app needs the AI less next time.
        var w = weights[target.bundleID] ?? MatchWeights()
        w.learn(chosen: chosen.features, others: shortlist.filter { $0.index != chosen.index }.map(\.features))
        weights[target.bundleID] = w
        callbacks.tuned(target.bundleID, w)

        let el = outcome.element(for: chosen)
        if let updated = AX.makeLocator(for: el, pid: AX.pid(el), clickPoint: nil) {
            learn(updated, from: target, stepIndex: stepIndex, byAI: true, risky: risky, callbacks: callbacks)
        }
        note(stepIndex, "AI picked \(picked): \(choice.reason ?? "")")
        return .element(ElementFinder.Match(element: el, windowFrame: outcome.root.windowFrame))
    }

    private func confident(_ o: ElementFinder.Outcome, _ best: RankedCandidate, target: ElementLocator,
                           stepIndex: Int, risky: Bool, callbacks: Callbacks) -> Hit {
        let el = o.element(for: best)
        // Self healing: a confident but imperfect match means the element drifted.
        // Remember how it looks now, as long as it's still the same element.
        if best.score < 0.92, let fresh = AX.makeLocator(for: el, pid: AX.pid(el), clickPoint: nil) {
            learn(fresh, from: target, stepIndex: stepIndex, byAI: false, risky: risky, callbacks: callbacks)
        }
        note(stepIndex, "Found \(Self.describe(o.snapshot(for: best))) · \(Int((best.score * 100).rounded()))% match")
        return .element(ElementFinder.Match(element: el, windowFrame: o.root.windowFrame))
    }

    /// Scrolls the list the element was recorded in, a few lines at a time, until
    /// it shows up: down first, then back up past where it started.
    /// (Closed loop scrolling with a budget, after OpenAdapt's replayer, MIT.)
    private func scrollSearch(_ target: ElementLocator, stepIndex: Int) async -> ElementFinder.Outcome? {
        guard let cut = target.path.lastIndex(where: { $0.role == "AXScrollArea" }),
              let root = ElementFinder.root(for: target),
              let area = AX.resolve(Array(target.path[...cut]), from: root.element),
              let frame = AX.frame(area), frame.width > 20, frame.height > 20 else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        // Covered by something else: don't scroll that instead.
        if let hit = AX.element(at: center), AX.pid(hit) != AX.pid(area) { return nil }
        for (lines, ticks) in [(Int32(-5), 8), (Int32(5), 16)] {
            for _ in 0..<ticks {
                if isCancelled { return nil }
                Input.scroll(at: center, lines: lines)
                try? await Task.sleep(nanoseconds: 250_000_000)
                await settle(bundleID: target.bundleID, maxWait: 0.6)
                if let o = ElementFinder.find(target, engine: engine(for: target.bundleID)),
                   case .confident = o.report.decision {
                    note(stepIndex, "Scrolled to find it")
                    return o
                }
            }
        }
        return nil
    }

    /// Clicks the element. Returns false, without clicking, when something else
    /// is under the click point, like a notification or a popover.
    private func click(match: ElementFinder.Match, target: ElementLocator, button: MouseButtonKind,
                       count: Int, modifiers: UInt64) throws -> Bool {
        let el = match.element
        let role = AX.role(el)
        let actions = AX.actions(el)

        // Menu items work best pressed directly; their menus may not be open.
        if (target.inMenu || role.hasPrefix("AXMenu")), button == .left, actions.contains(kAXPressAction) {
            if AX.perform(el, kAXPressAction) { return true }
        }
        if actions.contains("AXScrollToVisible") {
            AX.perform(el, "AXScrollToVisible")
            usleep(250_000)
        }
        guard let f = AX.frame(el), f.width > 0, f.height > 0, f.minX.isFinite, f.minY.isFinite else {
            if actions.contains(kAXPressAction), AX.perform(el, kAXPressAction) { return true }
            throw ReplayError("Found the element but couldn't tell where it is on screen.")
        }
        let ox = min(max(target.clickOffset.x, 0.1), 0.9)
        let oy = min(max(target.clickOffset.y, 0.1), 0.9)
        let point = CGPoint(x: f.minX + f.width * ox, y: f.minY + f.height * oy)
        // Look right before clicking: a banner or popover may have just appeared there.
        guard AX.pointReaches(point, target: el) else { return false }
        Input.click(at: point, button: button, count: count, modifiers: modifiers)
        return true
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
        guard let spot = target.frameInWindow else {
            throw ReplayError("The recording doesn't say where in the \(target.appName) window to click.")
        }
        guard let root = ElementFinder.root(for: target) else {
            throw ReplayError("Couldn't find a \(target.appName) window to click in.")
        }
        guard let wf = root.windowFrame else {
            throw ReplayError("Couldn't tell where the \(target.appName) window is on screen.")
        }
        var x = spot.midX, y = spot.midY
        if let old = target.windowSize, old.width > 0, old.height > 0 {
            x = x * wf.width / old.width
            y = y * wf.height / old.height
        }
        let point = CGPoint(x: wf.minX + x, y: wf.minY + y)
        // The spot must still belong to the app's window, not a notification over it.
        if let hit = AX.element(at: point), AX.pid(hit) != AX.pid(root.element) {
            throw ReplayError("Something from another app is covering the spot to click in \(target.appName).")
        }
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
        if isCancelled { throw ReplayError("Stopped.", cancelled: true) }
    }

    /// Sleeps in short slices so Esc stops even a long Wait step right away.
    /// (From MacTape's cancellableSleep, MIT.)
    private func pause(_ seconds: Double) async throws {
        var left = max(seconds, 0)
        while left > 0 {
            try checkCancelled()
            let slice = min(left, 0.1)
            try await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
            left -= slice
        }
        try checkCancelled()
    }
}
