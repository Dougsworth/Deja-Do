import AppKit
import ApplicationServices
import DejaDoCore

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

        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            line("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : " · " + detail)")
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
        try? await Task.sleep(nanoseconds: 400_000_000)
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

        // 4. A wrong expectation must stop the run instead of carrying on.
        await setMode(basic: true)
        var broken = task
        if let i = broken.steps.lastIndex(where: { if case .click = $0.kind { return true }; return false }) {
            broken.steps[i].expect = StepExpectation(appeared: [ExpectedText("98765")], changed: true)
            broken.steps[i].onMismatch = .retryThenStop
        }
        let (error, notes) = await runTask(broken, vision: vision)
        log.check("Step check stops a run that didn't do what it should",
                  error?.contains("Stopped at step") == true, error ?? "the run finished, it should have stopped")
        log.line("      notes: \(notes)")

        // 5. Only the screen: forget what Accessibility said and find each button by its picture and text.
        if vision {
            var screenOnly = task
            for i in screenOnly.steps.indices {
                guard case .click(var t, let b, let c, let m) = screenOnly.steps[i].kind, t.visual != nil else { continue }
                t.role = AX.positionRole
                t.title = nil; t.desc = nil; t.label = nil; t.identifier = nil; t.value = nil; t.help = nil
                t.path = []; t.anchors = nil; t.context = nil
                screenOnly.steps[i].kind = .click(target: t, button: b, count: c, modifiers: m)
            }
            await setMode(basic: false)
            await replay(screenOnly, name: "Screen only replay in Scientific layout", expect: "15", vision: true, log: log)
            await setMode(basic: true)
        }

        return log.failures == 0
    }

    static func replay(_ a: Automation, name: String, expect: String, vision: Bool, log: Log) async {
        await press(["all clear", "clear", "ac", "c"])
        let (error, notes) = await runTask(a, vision: vision)
        log.check(name + " finishes", error == nil, error ?? "")
        log.check(name + " shows \(expect)", displayShows(expect), "display: \(displayText())")
        log.line("      notes: \(notes)")
    }

    static func runTask(_ a: Automation, vision: Bool) async -> (error: String?, notes: String) {
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
            try await Replayer().run(a, settings: settings, callbacks: callbacks)
            return (nil, collected.summary)
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
        let wanted = Set(labels.map(TextSimilarity.normalize))
        let buttons = AX.collect(from: w, origin: nil, limit: 800) { $0 == "AXButton" }
        let hit = buttons.first { f in
            [f.node.label, f.node.title, f.node.desc].contains { $0.map { wanted.contains(TextSimilarity.normalize($0)) } ?? false }
        }
        guard let frame = hit?.node.frame else { return false }
        Input.click(at: CGPoint(x: frame.midX, y: frame.midY), button: .left, count: 1, modifiers: 0)
        try? await Task.sleep(nanoseconds: 600_000_000)
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
