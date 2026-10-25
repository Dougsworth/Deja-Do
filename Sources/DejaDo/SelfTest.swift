import AppKit
import ApplicationServices
@preconcurrency import DejaDoCore

/// End to end checks on a real app, run with:
///
///     open -W "/Applications/Deja Do.app" --args --self-test ~/Desktop/dejado-self-test.txt
///
/// Drives Calculator with real mouse events: records 7 + 8 =, replays it,
/// replays it again after switching Calculator's layout, replays a copy whose
/// expectation is wrong (the step check must stop it), and, when Screen
/// Recording is allowed, replays it using only the screen. Results go to
/// the given file and the app quits with 0 when everything passed.
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--self-test") }

    static var outputPath: String {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--self-test"), i + 1 < args.count, !args[i + 1].hasPrefix("-") {
            return (args[i + 1] as NSString).expandingTildeInPath
        }
        return NSHomeDirectory() + "/Desktop/dejado-self-test.txt"
    }

    static let calculatorID = "com.apple.calculator"

    /// `--suite calculator` or `--suite web` runs one; the default runs both.
    static var suites: Set<String> {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--suite"), i + 1 < args.count { return [args[i + 1].lowercased()] }
        return ["calculator", "web"]
    }

    static func start() {
        Task.detached(priority: .userInitiated) {
            let log = Log(path: outputPath)
            let passed = await run(log)
            log.line(passed ? "ALL PASSED" : "SOME CHECKS FAILED")
            exit(passed ? 0 : 1)
        }
    }

    final class Log: @unchecked Sendable {
        let path: String
        private var text = ""
        private(set) var failures = 0
        init(path: String) { self.path = path }

        func line(_ s: String) {
            let stamped = "\(Date().formatted(date: .omitted, time: .standard))  \(s)"
            print(stamped)
            text += stamped + "\n"
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }

        /// - Parameter counted: false for stretch goals, reported but not failing the run.
        func check(_ name: String, _ ok: Bool, _ detail: String = "", counted: Bool = true) {
            if !ok && counted { failures += 1 }
            let tag = ok ? "PASS" : (counted ? "FAIL" : "MISS")
            line("\(tag)  \(name)\(detail.isEmpty ? "" : " · " + detail)")
        }
    }

    // MARK: The run

    static func run(_ log: Log) async -> Bool {
        log.line("Deja Do self test")
        log.check("Accessibility allowed", AXIsProcessTrusted())
        log.check("Input Monitoring allowed", CGPreflightListenEventAccess())
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else { return false }
        let vision = ScreenVision.hasPermission
        log.line("Screen Recording \(vision ? "allowed, vision checks will run" : "not allowed, vision checks skipped")")

        // Get Deja Do's own window out of the way so clicks land on Calculator.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await MainActor.run {
            NSApp.windows.forEach { $0.orderOut(nil) }
            NSApp.hide(nil)
        }

        var passed = true
        if suites.contains("calculator") { passed = await calculator(log, vision: vision) && passed }
        if suites.contains("web") { passed = await WebSelfTest.run(log, vision: vision) && passed }
        return passed && log.failures == 0
    }

    static func calculator(_ log: Log, vision: Bool) async -> Bool {
        guard await openCalculator() else {
            log.check("Calculator opens", false)
            return false
        }
        log.check("Calculator opens", true)
        await setMode(basic: true)

        // 1. Record 7 + 8 = by really clicking.
        await press(["all clear", "clear", "ac", "c"])
        let recorder = await MainActor.run { () -> Recorder in
            let r = Recorder()
            r.visionEnabled = vision
            r.checkSteps = true
            _ = r.start()
            return r
        }
        // Give the recorder a first look at the screen, as a person switching to the app would.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        var pressedAll = true
        for keys in [["7", "seven"], ["+", "add", "plus"], ["8", "eight"], ["=", "equals", "equal"]] {
            pressedAll = await press(keys) && pressedAll
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        let steps: [Step] = await withCheckedContinuation { cont in
            DispatchQueue.main.async { recorder.finish { cont.resume(returning: $0) } }
        }
        log.check("Found Calculator's buttons to click", pressedAll)
        log.check("Display shows 15 after recording", displayShows("15"), "display: \(displayText())")
        let clicks = steps.filter { if case .click = $0.kind { return true }; return false }
        log.check("Recorded 4 clicks", clicks.count == 4, steps.map(\.summary).joined(separator: " | "))
        let expected = clicks.compactMap(\.expect)
        log.check("Recorded what each click changed", expected.count >= 3,
                  clicks.map { $0.expect?.summary ?? "nothing" }.joined(separator: " | "))
        if vision {
            log.check("Kept a picture for each click", clicks.allSatisfy { step in
                if case .click(let t, _, _, _) = step.kind { return t.visual != nil }
                return false
            })
        }
        let task = Automation(name: "Self test 7 + 8", steps: steps)

        // 2. Replay as recorded.
        await replay(task, name: "Replay", expect: "15", vision: vision, log: log)

        // 3. Replay after the layout changes: buttons move and resize.
        await setMode(basic: false)
        await replay(task, name: "Replay in Scientific layout", expect: "15", vision: vision, log: log)

        // 4. A wrong expectation must stop the run instead of carrying on, and must
        // not repeat the step, because the screen did change, just not as expected.
        await setMode(basic: true)
        var broken = task
        if let i = broken.steps.lastIndex(where: { if case .click = $0.kind { return true }; return false }) {
            var e = broken.steps[i].expect ?? StepExpectation(changed: true, usedOCR: vision)
            e.appeared = [ExpectedText("Sent to Ana")]
            broken.steps[i].expect = e
            broken.steps[i].onMismatch = .retryThenStop
        }
        await press(["all clear", "clear", "ac", "c"])
        let (error, notes) = await runTask(broken, vision: vision)
        log.check("Step check stops a run whose screen doesn't match",
                  error?.contains("Sent to Ana") == true, error ?? "the run finished, it should have stopped")
        log.check("…without repeating the step", !notes.contains("trying once more"))
        log.line("      notes: \(notes)")

        // 4b. A step that sends, saves or deletes is never repeated, even when nothing seemed to happen.
        var riskyBroken = broken
        if let i = riskyBroken.steps.lastIndex(where: { if case .click = $0.kind { return true }; return false }) {
            riskyBroken.steps[i].risk = .risky
        }
        await press(["all clear", "clear", "ac", "c"])
        let (riskyError, riskyNotes) = await runTask(riskyBroken, vision: vision)
        log.check("A risky step stops without being repeated",
                  riskyError != nil && !riskyNotes.contains("trying once more"), riskyError ?? "it finished")
        log.check("…and the stop says it may already have happened", riskyError?.contains("may already have sent") == true,
                  riskyError ?? "")

        // 6. Check finds every button without clicking anything.
        await press(["all clear", "clear", "ac", "c"])
        let shown = displayText()
        var found = 0, clicksToCheck = 0
        for step in task.steps {
            guard case .click(let t, _, _, _) = step.kind else { continue }
            clicksToCheck += 1
            if let o = ElementFinder.find(t, engine: MatchEngine()), case .confident = o.report.decision { found += 1 }
        }
        log.check("Check finds all \(clicksToCheck) buttons", found == clicksToCheck, "found \(found)")
        log.check("…without pressing anything", displayText() == shown, "display before \(shown), after \(displayText())")

        // 7. If another app jumps in front mid run, Deja Do brings Calculator back before the next click.
        var slow = task
        if let i = slow.steps.firstIndex(where: { if case .click = $0.kind { return true }; return false }) {
            slow.steps.insert(Step(kind: .wait(seconds: 2)), at: i + 1)
        }
        await press(["all clear", "clear", "ac", "c"])
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        Task.detached {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: finder, configuration: config)
        }
        let (slowError, _) = await runTask(slow, vision: vision)
        log.check("Brings the app back when another one jumps in front", slowError == nil && displayShows("15"),
                  slowError ?? "display: \(displayText())")

        // 8. Esc stops even a long Wait right away.
        let waiting = Automation(name: "Wait", steps: [Step(kind: .wait(seconds: 30))])
        let replayer = Replayer()
        let stopAt = Date()
        Task.detached {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            replayer.cancel()
        }
        _ = await runTask(waiting, vision: false, replayer: replayer)
        let took = Date().timeIntervalSince(stopAt)
        log.check("Stopping a 30 second wait takes effect at once", took < 2.5, String(format: "stopped after %.1fs", took))

        // 5. Only the screen: forget what Accessibility said and find each button by
        // its picture and text, like in a virtual machine. First with the window moved,
        // which is the everyday case, then in the Scientific layout as a stretch.
        if vision {
            var screenOnly = task
            for i in screenOnly.steps.indices {
                guard case .click(var t, let b, let c, let m) = screenOnly.steps[i].kind, t.visual != nil else { continue }
                t.role = AX.positionRole
                t.title = nil; t.desc = nil; t.label = nil; t.identifier = nil; t.value = nil; t.help = nil
                t.path = []; t.anchors = nil; t.context = nil
                screenOnly.steps[i].kind = .click(target: t, button: b, count: c, modifiers: m)
            }
            let before = window().flatMap { AX.frame($0) }
            if let f = before { await dragWindow(f, by: CGVector(dx: 160, dy: 90)) }
            let after = window().flatMap { AX.frame($0) }
            log.line("      window moved from \(describe(before)) to \(describe(after))")
            await replay(screenOnly, name: "Screen only replay after moving the window", expect: "15", vision: true, log: log)
            if let f = after { await dragWindow(f, by: CGVector(dx: -160, dy: -90)) }

            // Every button changes size and place here. Getting 15 is great; stopping
            // safely is fine; clicking the wrong button and carrying on is the failure.
            await setMode(basic: false)
            await press(["all clear", "clear", "ac", "c"])
            let (sciError, sciNotes) = await runTask(screenOnly, vision: true)
            let right = sciError == nil && displayShows("15")
            let safeStop = sciError != nil
            log.check("Screen only in Scientific layout: right answer or a safe stop, never a wrong result",
                      right || safeStop, right ? "display: 15" : (sciError ?? "finished with display \(displayText())"))
            log.line("      notes: \(sciNotes)")
            await setMode(basic: true)
        }

        return log.failures == 0
    }

    static func replay(_ a: Automation, name: String, expect: String, vision: Bool, log: Log,
                       counted: Bool = true) async {
        await press(["all clear", "clear", "ac", "c"])
        let (error, notes) = await runTask(a, vision: vision)
        log.check(name + " finishes", error == nil, error ?? "", counted: counted)
        log.check(name + " shows \(expect)", displayShows(expect), "display: \(displayText())", counted: counted)
        log.line("      notes: \(notes)")
    }

    /// Moves the window the way a person does: dragging its title bar.
    static func dragWindow(_ frame: CGRect, by d: CGVector) async {
        NSRunningApplication.runningApplications(withBundleIdentifier: calculatorID).first?
            .activate(options: [.activateIgnoringOtherApps])
        try? await Task.sleep(nanoseconds: 300_000_000)
        let start = CGPoint(x: frame.midX, y: frame.minY + 12)
        let source = Input.source
        func post(_ type: CGEventType, _ p: CGPoint) {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        post(.mouseMoved, start)
        usleep(80_000)
        post(.leftMouseDown, start)
        usleep(80_000)
        for i in 1...20 {
            let f = CGFloat(i) / 20
            post(.leftMouseDragged, CGPoint(x: start.x + d.dx * f, y: start.y + d.dy * f))
            usleep(15_000)
        }
        post(.leftMouseUp, CGPoint(x: start.x + d.dx, y: start.y + d.dy))
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    static func describe(_ f: CGRect?) -> String {
        guard let f else {
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: calculatorID).first
            let count = app.map { AX.elements(AX.raw(AXUIElementCreateApplication($0.processIdentifier), kAXWindowsAttribute)).count }
            return "nowhere (Calculator \(app == nil ? "not running" : "has \(count ?? 0) windows"), front app \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"))"
        }
        return "\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height))"
    }

    static func runTask(_ a: Automation, vision: Bool, replayer: Replayer = Replayer()) async -> (error: String?, notes: String) {
        let collected = NotesBox()
        let settings = Replayer.Settings(ai: AIConfig(provider: .anthropic, model: "", key: ""), aiEnabled: false,
                                         visionEnabled: vision, checkSteps: true)
        let callbacks = Replayer.Callbacks(
            progress: { _ in },
            askText: { _, _ in nil },
            learned: { _, _, _ in },
            note: { i, text in collected.set(i, text) },
            tuned: { _, _ in })
        do {
            try await replayer.run(a, settings: settings, callbacks: callbacks)
            return (nil, collected.summary)
        } catch let stop as ReplayStop {
            return ("\(stop.message) \(stop.outcome.advice)", collected.summary)
        } catch {
            return (error.localizedDescription, collected.summary)
        }
    }

    final class NotesBox: @unchecked Sendable {
        private let lock = NSLock()
        private var notes: [Int: String] = [:]
        func set(_ i: Int, _ s: String) { lock.lock(); notes[i] = s; lock.unlock() }
        var summary: String {
            lock.lock(); defer { lock.unlock() }
            return notes.keys.sorted().map { "\($0 + 1): \(notes[$0]!)" }.joined(separator: " | ")
        }
    }

    // MARK: Calculator

    static func openCalculator() async -> Bool {
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        for _ in 0..<40 {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: calculatorID).first {
                app.activate(options: [.activateIgnoringOtherApps])
                if window() != nil, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == calculatorID { return true }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    static func window() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: calculatorID).first else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        return AX.element(el, kAXFocusedWindowAttribute) ?? AX.elements(AX.raw(el, kAXWindowsAttribute)).first
    }

    /// Basic is ⌘1, Scientific is ⌘2 in Calculator.
    static func setMode(basic: Bool) async {
        NSRunningApplication.runningApplications(withBundleIdentifier: calculatorID).first?
            .activate(options: [.activateIgnoringOtherApps])
        try? await Task.sleep(nanoseconds: 300_000_000)
        Input.key(basic ? 18 : 19, modifiers: CGEventFlags.maskCommand.rawValue)
        try? await Task.sleep(nanoseconds: 900_000_000)
    }

    /// Clicks the first button whose label is one of `labels`, with a real mouse event.
    @discardableResult
    static func press(_ labels: [String]) async -> Bool {
        guard let w = window() else { return false }
        // Symbols like + and = must match exactly, so compare the raw text too.
        func key(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }
        let wanted = Set(labels.map(key))
        let buttons = AX.collect(from: w, origin: nil, limit: 800) { $0 == "AXButton" }
        let hit = buttons.first { f in
            [f.node.label, f.node.title, f.node.desc].contains { $0.map { wanted.contains(key($0)) } ?? false }
        }
        guard let frame = hit?.node.frame else { return false }
        Input.click(at: CGPoint(x: frame.midX, y: frame.midY), button: .left, count: 1, modifiers: 0)
        // About the pace a person clicks at, so the recorder sees each result settle.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return true
    }

    /// Everything the Calculator window shows as text.
    static func displayText() -> String {
        guard let w = window() else { return "" }
        return AX.collect(from: w, origin: nil, limit: 800) { $0 == "AXStaticText" }
            .compactMap { $0.node.value ?? $0.node.label }
            .joined(separator: " / ")
    }

    static func displayShows(_ number: String) -> Bool {
        guard let w = window() else { return false }
        return AX.collect(from: w, origin: nil, limit: 800) { $0 == "AXStaticText" }
            .compactMap { $0.node.value ?? $0.node.label }
            .contains { text in
                let digits = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
                return digits == number
            }
    }
}
