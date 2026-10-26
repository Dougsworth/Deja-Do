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

    /// `--suite calculator`, `web` or `apps` runs one; the default runs all three.
    static var suites: Set<String> {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--suite"), i + 1 < args.count { return [args[i + 1].lowercased()] }
        return ["calculator", "web", "apps"]
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
            let held = SelfTest.Guard.shared.take()
            if !held.isEmpty { line("      held back: " + held.prefix(3).joined(separator: "; ")) }
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
        // Never drive the Mac while someone is using it.
        if idleSeconds < 20 {
            log.check("Nobody is using the Mac", false,
                      String(format: "the mouse or keyboard was used %.0f seconds ago; the test only starts after 20 quiet seconds", idleSeconds))
            return false
        }
        if AppModel.screenLocked {
            log.check("The screen is unlocked", false)
            return false
        }
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
        if suites.contains("web") || suites.contains("chrome") { passed = await WebSelfTest.run(log, vision: vision) && passed }
        if suites.contains("apps") { passed = await AppsSelfTest.run(log, vision: vision) && passed }
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
        await press(clearNames)
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

        // 2b. Edited by hand: the 8 renamed to 9. The click finds 9, and the
        // = step, which expected 15, learns 16 instead of stopping the run.
        var edited = task
        if let i = edited.steps.lastIndex(where: { $0.targetName == "8" }) {
            let old = edited.steps[i].targetName
            edited.steps[i] = edited.steps[i].renamingTarget(to: "9")
            edited.noteEdit(at: i, replacing: old, with: "9")
        }
        log.check("Renaming a click from 8 to 9 changes the step", edited.steps.contains { $0.summary.contains("“9”") },
                  edited.steps.map(\.summary).joined(separator: " | "))
        await replay(edited, name: "Replay after renaming 8 to 9", expect: "16", vision: vision, log: log)

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
        await press(clearNames)
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
        await press(clearNames)
        let (riskyError, riskyNotes) = await runTask(riskyBroken, vision: vision)
        log.check("A risky step stops without being repeated",
                  riskyError != nil && !riskyNotes.contains("trying once more"), riskyError ?? "it finished")
        log.check("…and the stop says it may already have happened", riskyError?.contains("may already have sent") == true,
                  riskyError ?? "")

        // 6. Check finds every button without clicking anything.
        await press(clearNames)
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
        await press(clearNames)
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
            await press(clearNames)
            let (sciError, sciNotes) = await runTask(screenOnly, vision: true)
            let right = sciError == nil && displayShows("15")
            let safeStop = sciError != nil
            log.check("Screen only in Scientific layout: right answer or a safe stop, never a wrong result",
                      right || safeStop, right ? "display: 15" : (sciError ?? "finished with display \(displayText())"))
            log.line("      notes: \(sciNotes)")
            await setMode(basic: true)

            // On a second display: the window dragged onto it, replayed by Accessibility and from the screen alone.
            await otherDisplay(task, screenOnly: screenOnly, log: log)
        }

        let read = await readDisplay(vision: vision, log: log)
        var withRead = task
        if let read { withRead.steps.append(read) }
        await webhook(withRead, vision: vision, log: log)
        await menuChoice(vision: vision, log: log)
        await calculatorInSpanish(log, vision: vision)
        return log.failures == 0
    }

    /// Calculator reopened in Spanish: recorded and replayed with Spanish
    /// labels. Calculator holds nothing of the person's, so it's safe to quit.
    static func calculatorInSpanish(_ log: Log, vision: Bool) async {
        log.line("Calculator in Spanish")
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: calculatorID).first {
            app.terminate()
            for _ in 0..<20 where NSRunningApplication.runningApplications(withBundleIdentifier: calculatorID).first != nil {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        guard await openCalculator(arguments: ["-AppleLanguages", "(es)"]) else {
            log.check("Spanish: Calculator opens", false)
            return
        }
        await setMode(basic: true)
        let names = buttonNames()
        log.check("Spanish: Calculator opens", true, "buttons: " + names.prefix(8).joined(separator: ", "))
        await press(clearNames)
        let recorder = await MainActor.run { () -> Recorder in
            let r = Recorder()
            r.visionEnabled = vision
            r.checkSteps = true
            _ = r.start()
            return r
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        var pressedAll = true
        for keys in [sevenNames, plusNames, eightNames, equalsNames] { pressedAll = await press(keys) && pressedAll }
        try? await Task.sleep(nanoseconds: 800_000_000)
        let steps: [Step] = await withCheckedContinuation { cont in
            DispatchQueue.main.async { recorder.finish { cont.resume(returning: $0) } }
        }
        log.check("Spanish: recorded 7 + 8 =", pressedAll && displayShows("15"), steps.map(\.summary).joined(separator: " | "))
        let task = Automation(name: "Self test Calculator in Spanish", steps: steps)
        log.check("Spanish: no step mistaken for a risky one", task.steps.indices.allSatisfy { task.risk(at: $0).risk == .normal })
        await replay(task, name: "Spanish: replay", expect: "15", vision: vision, log: log)
        await setMode(basic: false)
        await replay(task, name: "Spanish: replay in the Scientific layout", expect: "15", vision: vision, log: log)
        await setMode(basic: true)
        // Leave it closed rather than in Spanish.
        NSRunningApplication.runningApplications(withBundleIdentifier: calculatorID).first?.terminate()
    }

    /// Keeping what the display shows: recorded by pointing at it and pressing
    /// ⌃⌥R, then replayed after two different sums. It must read what's there
    /// each time, not what was there when recorded.
    static func readDisplay(vision: Bool, log: Log) async -> Step? {
        await setMode(basic: true)
        await press(clearNames)
        for keys in [sevenNames, plusNames, eightNames, equalsNames] { await press(keys) }
        guard let display = displayElement(), let f = display.node.frame else {
            log.check("Read: found the display to point at", false, "display: \(displayText())")
            return nil
        }
        let recorder = await MainActor.run { () -> Recorder in
            let r = Recorder()
            r.visionEnabled = vision
            r.checkSteps = true
            _ = r.start()
            return r
        }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let point = CGPoint(x: f.midX, y: f.midY)
        CGEvent(mouseEventSource: Input.source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 400_000_000)
        TestInput.key(15, modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue, in: calculatorID)   // ⌃⌥R
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let steps: [Step] = await withCheckedContinuation { cont in
            DispatchQueue.main.async { recorder.finish { cont.resume(returning: $0) } }
        }
        let reads = steps.filter { if case .read = $0.kind { return true }; return false }
        let keys = steps.filter { if case .key = $0.kind { return true }; return false }
        log.check("Read: ⌃⌥R records a read step, not a key press", reads.count == 1 && keys.isEmpty,
                  steps.map(\.summary).joined(separator: " | "))
        guard let read = reads.first, case .read(let target, let name) = read.kind else { return nil }
        log.check("Read: the step doesn't remember the value itself", target.label == nil && target.value == nil && target.title == nil,
                  "name {{\(name)}}")
        let task = Automation(name: "Self test read", steps: [read])

        let first = await runTaskReading(task, vision: vision)
        log.check("Read: reads 15 after 7 + 8", first.error == nil && digits(first.read[name]) == "15",
                  first.error ?? "read “\(first.read[name] ?? "nothing")”")
        await press(clearNames)
        for keys in [["9", "nine", "nueve"], ["×", "multiply", "times", "*", "multiplicar"], ["9", "nine", "nueve"], equalsNames] {
            await press(keys)
        }
        let second = await runTaskReading(task, vision: vision)
        log.check("Read: reads 81 after 9 × 9, what's showing now", second.error == nil && digits(second.read[name]) == "81",
                  second.error ?? "read “\(second.read[name] ?? "nothing")”")
        return read
    }

    static func digits(_ s: String?) -> String {
        (s ?? "").filter { $0.isNumber || $0 == "." || $0 == "-" }
    }

    /// The display: the text element showing the current number.
    static func displayElement() -> AX.Found? {
        guard let w = window() else { return nil }
        return AX.collect(from: w, origin: nil, limit: 800) { $0 == "AXStaticText" }
            .filter { !digits($0.node.value ?? $0.node.label).isEmpty }
            .max { ($0.node.frame?.height ?? 0) < ($1.node.frame?.height ?? 0) }
    }

    /// Choosing View › Scientific from the menu bar. A menu closes the moment
    /// an item is clicked, so what was clicked has to be read at that instant.
    static func menuChoice(vision: Bool, log: Log) async {
        await setMode(basic: true)
        let basicCount = buttonNames().count
        let recorder = await MainActor.run { () -> Recorder in
            let r = Recorder()
            r.visionEnabled = vision
            r.checkSteps = true
            _ = r.start()
            return r
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let opened = await clickMenuBar("View")
        let chose = opened ? await clickMenuItem("Scientific") : false
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let steps: [Step] = await withCheckedContinuation { cont in
            DispatchQueue.main.async { recorder.finish { cont.resume(returning: $0) } }
        }
        let sciCount = buttonNames().count
        let items = steps.compactMap { step -> ElementLocator? in
            if case .click(let t, _, _, _) = step.kind { return t }
            return nil
        }
        log.check("Recorded View › Scientific from the menu bar", opened && chose && sciCount > basicCount
                    && items.last?.label == "Scientific" && items.last?.inMenu == true,
                  steps.map(\.summary).joined(separator: " | "))
        guard items.last?.label == "Scientific" else { await setMode(basic: true); return }
        await setMode(basic: true)
        let (error, notes) = await runTask(Automation(name: "Self test menu", steps: steps), vision: vision)
        log.check("Replaying the menu choice switches to Scientific", error == nil && buttonNames().count > basicCount,
                  (error ?? "finished") + " · \(buttonNames().count) buttons, Basic has \(basicCount)")
        log.line("      notes: \(notes)")
        await setMode(basic: true)
    }

    static func menuBar() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: calculatorID).first else { return nil }
        app.activate(options: [.activateIgnoringOtherApps])
        return AX.element(AXUIElementCreateApplication(app.processIdentifier), kAXMenuBarAttribute)
    }

    static func clickMenuBar(_ title: String) async -> Bool {
        guard let bar = menuBar(),
              let item = AX.children(bar).first(where: { AX.string($0, kAXTitleAttribute) == title }),
              let f = AX.frame(item) else { return false }
        guard TestInput.click(CGPoint(x: f.midX, y: f.midY), in: calculatorID) else { return false }
        try? await Task.sleep(nanoseconds: 900_000_000)
        return true
    }

    static func clickMenuItem(_ title: String) async -> Bool {
        guard let bar = menuBar() else { return false }
        let items = AX.collect(from: bar, origin: nil, limit: 800) { $0 == "AXMenuItem" }
        guard let item = items.first(where: { $0.node.title == title }), let f = item.node.frame, f.width > 0 else { return false }
        guard TestInput.click(CGPoint(x: f.midX, y: f.midY), in: calculatorID) else { return false }
        try? await Task.sleep(nanoseconds: 900_000_000)
        return true
    }

    // Button names in English and Spanish.
    static let clearNames = ["all clear", "clear", "ac", "c", "borrar todo", "borrar"]
    static let sevenNames = ["7", "seven", "siete"]
    static let eightNames = ["8", "eight", "ocho"]
    static let plusNames = ["+", "add", "plus", "sumar", "más", "mas"]
    static let equalsNames = ["=", "equals", "equal", "igual", "es igual a"]

    static func buttonNames() -> [String] {
        guard let w = window() else { return [] }
        return AX.collect(from: w, origin: nil, limit: 800) { $0 == "AXButton" }.compactMap { $0.node.label ?? $0.node.desc }
    }

    /// Starts the task the way n8n or a script would: an HTTP request to the local address.
    static func webhook(_ task: Automation, vision: Bool, log: Log) async {
        let server = WebhookServer()
        let token = WebhookAPI.newToken()
        let busy = Flag()
        let hooks = WebhookServer.Hooks(
            tasks: { [WebhookAPI.TaskInfo(id: task.id, name: task.name, variables: task.variableNames)] },
            busy: { busy.value },
            start: { _, _, done in
                busy.value = true
                Task.detached {
                    let started = Date()
                    let (error, _, read) = await runTaskReading(task, vision: vision)
                    let record = RunRecord(started: started, duration: Date().timeIntervalSince(started),
                                           outcome: error ?? "Done.", succeeded: error == nil,
                                           steps: task.steps.enumerated().map { .init(index: $0.offset, summary: $0.element.safeSummary, note: nil, ran: true) })
                    let outcome: RunOutcome = error == nil ? .finished : .stoppedBeforeChanges(atStep: 0)
                    DispatchQueue.main.async { busy.value = false; done(record, outcome, read) }
                }
                return true
            })
        // A spare port, so a copy of Deja Do already listening on the usual one doesn't matter.
        guard server.start(port: 0, token: token, hooks: hooks) else {
            log.check("Local web address starts", false, server.lastError ?? "")
            return
        }
        defer { server.stop() }
        log.check("Local web address starts", true, "port \(server.port)")
        let base = "http://127.0.0.1:\(server.port)"

        let (noToken, _) = await http("POST", base + "/run", token: nil, body: ["task": task.name])
        log.check("A request without the token is refused", noToken == 401, "status \(noToken)")

        await press(clearNames)
        // Ask for a second run while the first is going: it must be told Deja Do is busy.
        let second = Task.detached { () -> Int in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            return await http("POST", base + "/run", token: token, body: ["task": task.name]).status
        }
        let (code, reply) = await http("POST", base + "/run", token: token, body: ["task": task.name, "wait": true])
        let status = reply["status"] as? String
        // Give Calculator a moment to answer before reading its display.
        for _ in 0..<10 where !displayShows("15") { try? await Task.sleep(nanoseconds: 200_000_000) }
        log.check("A request with the token runs the task and waits for the result", code == 200 && status == "succeeded" && displayShows("15"),
                  "status \(code), run \(status ?? "none"), display \(displayText())")
        if !task.readNames.isEmpty {
            let values = reply["values"] as? [String: String] ?? [:]
            log.check("…and gets back what the task read off the screen", values.values.contains { digits($0) == "15" },
                      "values \(values)")
        }
        let busyCode = await second.value
        log.check("A second request while it runs is told Deja Do is busy", busyCode == 409, "status \(busyCode)")
        if let id = reply["runId"] as? String {
            let (lookup, again) = await http("GET", base + "/runs/" + id, token: token, body: nil)
            log.check("The run can be looked up afterwards", lookup == 200 && again["status"] as? String == "succeeded", "status \(lookup)")
        }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
    }

    static func http(_ method: String, _ url: String, token: String?, body: [String: Any]?) async -> (status: Int, json: [String: Any]) {
        guard let u = URL(string: url) else { return (0, [:]) }
        var req = URLRequest(url: u, timeoutInterval: 120)
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return (0, [:]) }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
    }

    static func replay(_ a: Automation, name: String, expect: String, vision: Bool, log: Log,
                       counted: Bool = true) async {
        await press(clearNames)
        let (error, notes) = await runTask(a, vision: vision)
        log.check(name + " finishes", error == nil, error ?? "", counted: counted)
        log.check(name + " shows \(expect)", displayShows(expect), "display: \(displayText())", counted: counted)
        log.line("      notes: \(notes)")
    }

    /// Displays in the Accessibility space (origin top left of the main display).
    static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    static func otherDisplay(_ task: Automation, screenOnly: Automation, log: Log) async {
        let displays = displayBounds()
        guard displays.count > 1, let before = window().flatMap({ AX.frame($0) }) else {
            log.check("Works on a second display", true, "only one display connected, skipped", counted: false)
            return
        }
        let home = ScreenGeometry.mainDisplay(for: before, on: displays) ?? 0
        guard let target = displays.indices.first(where: { $0 != home }).map({ displays[$0] }) else { return }
        // Drag the title bar so the window ends up in the middle of the other display.
        let d = CGVector(dx: target.midX - before.midX, dy: target.midY - before.midY)
        await dragWindow(before, by: d)
        let moved = window().flatMap { AX.frame($0) }
        let onTarget = moved.flatMap { ScreenGeometry.mainDisplay(for: $0, on: displays) }.map { displays[$0] == target } ?? false
        log.line("      window moved from \(describe(before)) to \(describe(moved)) on display at \(Int(target.minX)),\(Int(target.minY))")
        guard onTarget else {
            log.check("Works on a second display", false, "couldn't move the window onto it")
            return
        }
        await replay(task, name: "On the second display", expect: "15", vision: true, log: log)
        await replay(screenOnly, name: "On the second display from the screen alone", expect: "15", vision: true, log: log)
        if let now = window().flatMap({ AX.frame($0) }) {
            await dragWindow(now, by: CGVector(dx: before.midX - now.midX, dy: before.midY - now.midY))
        }
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
        guard TestInput.front(calculatorID), let hit = AX.element(at: start), AX.pid(hit) == TestInput.pid(calculatorID) else {
            Guard.shared.blocked("dragging Calculator's title bar, something else was there")
            return
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
        let r = await runTaskReading(a, vision: vision, replayer: replayer)
        return (r.error, r.notes)
    }

    /// Runs the task with the given settings and returns what it read off the screen too.
    static func runTaskReading(_ a: Automation, vision: Bool, replayer: Replayer = Replayer(), ai: AIConfig? = nil,
                               values: [String: String] = [:],
                               confirm: @escaping (String, String) async -> Bool = { _, _ in true },
                               learned: @escaping (Int, ElementLocator, Bool) -> Void = { _, _, _ in })
        async -> (error: String?, notes: String, read: [String: String]) {
        let collected = NotesBox()
        let settings = Replayer.Settings(ai: ai ?? AIConfig(provider: .anthropic, model: "", key: ""), aiEnabled: ai != nil,
                                         visionEnabled: vision, checkSteps: true)
        var callbacks = Replayer.Callbacks(
            progress: { _ in },
            askText: { _, _ in nil },
            learned: learned,
            note: { i, text in collected.set(i, text) },
            tuned: { _, _ in })
        callbacks.confirm = confirm
        do {
            try await replayer.run(a, settings: settings, callbacks: callbacks, values: values)
            return (nil, collected.summary, replayer.readValues)
        } catch let stop as ReplayStop {
            return ("\(stop.message) \(stop.outcome.advice)", collected.summary, replayer.readValues)
        } catch {
            return (error.localizedDescription, collected.summary, replayer.readValues)
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

    static func openCalculator(arguments: [String] = []) async -> Bool {
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.arguments = arguments
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
        TestInput.key(basic ? 18 : 19, modifiers: CGEventFlags.maskCommand.rawValue, in: calculatorID)
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
        guard TestInput.click(CGPoint(x: frame.midX, y: frame.midY), in: calculatorID) else { return false }
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
