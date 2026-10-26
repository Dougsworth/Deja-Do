import AppKit
import ApplicationServices
@preconcurrency import DejaDoCore

/// Checks on ordinary desktop apps beyond Calculator.
///
/// TextEdit: typing into a document, a ⌘S that must never be repeated, and
/// Esc to close the sheet it opens. Replayed into a fresh document, the text
/// must land exactly once. With the ⌘S step's expectation broken, the run
/// must stop there without pressing ⌘S again.
///
/// Electron: apps built on Chromium only build their accessibility tree when
/// asked. Whatever Electron app is already running (the Claude desktop app
/// counts) must describe its buttons within a few seconds of being asked.
/// Nothing is launched or clicked for this one.
enum AppsSelfTest {
    static let textEditID = "com.apple.TextEdit"
    static let sentence = "Deja Do typed this."
    /// What TextEdit calls a new document, in English and Spanish.
    static let untitled = ["Untitled", "Sin título"]
    static func isUntitled(_ title: String) -> Bool { untitled.contains { title.hasPrefix($0) } }

    static func run(_ log: SelfTest.Log, vision: Bool) async -> Bool {
        let failuresBefore = log.failures
        log.line("Desktop apps")
        await electron(log)
        await textEdit(log, vision: vision)
        await textEditInSpanish(log, vision: vision)
        await SlackSelfTest.run(log, vision: vision)
        await ExcelSelfTest.run(log, vision: vision)
        return log.failures == failuresBefore
    }

    // MARK: Electron

    static func electron(_ log: SelfTest.Log) async {
        let me = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != me, app.activationPolicy == .regular, let id = app.bundleIdentifier else { return false }
            return AX.isElectron(id)
        }
        func windows(_ a: NSRunningApplication) -> [AXUIElement] {
            let e = AXUIElementCreateApplication(a.processIdentifier)
            AXUIElementSetMessagingTimeout(e, 0.5)
            return AX.elements(AX.raw(e, kAXWindowsAttribute))
        }
        // Electron only builds the tree for a window that can be seen, so minimised ones don't count.
        let candidates = running.filter { a in
            windows(a).contains { (AX.raw($0, kAXMinimizedAttribute) as? Bool) != true }
        }
        guard !candidates.isEmpty else {
            let names = running.compactMap(\.localizedName).joined(separator: ", ")
            log.check("An Electron app describes its buttons once asked", true,
                      running.isEmpty ? "no Electron app running, skipped" : "\(names) running without a window, skipped", counted: false)
            return
        }
        var results: [String] = []
        var anyGood = false
        for app in candidates.prefix(4) {
            guard let id = app.bundleIdentifier else { continue }
            let el = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(el, 1.0)
            let manual = AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            let enhanced = AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            var labelled = 0, total = 0
            var activated = false
            let deadline = Date().addingTimeInterval(9)
            repeat {
                // Halfway, bring it to the front once: some builds only fill the tree for a visible window.
                if !activated, Date() > deadline.addingTimeInterval(-4.5) {
                    activated = true
                    app.activate(options: [.activateIgnoringOtherApps])
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                // Every window, since the focused one may be a tiny status popover.
                total = 0; labelled = 0
                for w in AX.elements(AX.raw(el, kAXWindowsAttribute)) {
                    let found = AX.collect(from: w, origin: nil, limit: 1500) { AX.actionableRoles.contains($0) }
                    total += found.count
                    labelled += found.filter { ($0.node.label ?? "").count >= 2 }.count
                }
                if labelled >= 5 { break }
            } while Date() < deadline
            let good = labelled >= 5
            anyGood = anyGood || good
            var why = ""
            if !good {
                // What's actually there, to tell "tree never built" from "built but unlabelled".
                let ws = AX.elements(AX.raw(el, kAXWindowsAttribute))
                let shape = ws.prefix(2).map { w -> String in
                    let mini = (AX.raw(w, kAXMinimizedAttribute) as? Bool) == true ? " minimised" : ""
                    let kids = AX.children(w).map { AX.role($0) }
                    let deeper = AX.children(w).flatMap { AX.children($0) }.prefix(8).map { AX.role($0) }
                    return "[\(kids.joined(separator: ","))\(deeper.isEmpty ? "" : " > " + deeper.joined(separator: ","))\(mini)]"
                }.joined(separator: " ")
                why = " (manual \(manual.rawValue), enhanced \(enhanced.rawValue), \(shape))"
            }
            results.append("\(app.localizedName ?? id) \(labelled) of \(total) named\(good ? "" : " ✗")\(why)")
        }
        log.check("An Electron app describes its buttons once asked", anyGood, results.joined(separator: " · "))
    }

    // MARK: TextEdit

    /// TextEdit opened in Spanish, the way it looks on a Mac set to Spanish.
    /// Only done when none of the person's own TextEdit documents are open,
    /// because TextEdit has to be quit and reopened to change language.
    static func textEditInSpanish(_ log: SelfTest.Log, vision: Bool) async {
        if let running = app() {
            let theirs = windowTitles().filter { !isUntitled($0) }
            guard theirs.isEmpty, windowTitles().isEmpty else {
                log.check("TextEdit in Spanish", true, "your own TextEdit documents are open, skipped so they aren't touched", counted: false)
                return
            }
            running.terminate()
            for _ in 0..<20 where app() != nil { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard app() == nil else {
                log.check("TextEdit in Spanish", true, "TextEdit didn't quit, skipped", counted: false)
                return
            }
        }
        log.line("TextEdit in Spanish")
        await textEdit(log, vision: vision, arguments: ["-AppleLanguages", "(es)"], prefix: "Spanish: ")
        // Leave it closed rather than in Spanish.
        if windowTitles().isEmpty { app()?.terminate() }
    }

    static func textEdit(_ log: SelfTest.Log, vision: Bool, arguments: [String] = [], prefix: String = "") async {
        guard await openTextEdit(arguments: arguments) else {
            log.check(prefix + "TextEdit opens with a new document", false)
            return
        }
        log.check(prefix + "TextEdit opens with a new document", true, frontTitle() ?? "")
        // Only the documents this test makes are ever closed. TextEdit may well
        // have the person's own files open, and those are not touched.
        var mine = Set<String>()
        if let t = frontTitle() { mine.insert(t) }

        // Record: click in the page, type, ⌘S, Esc.
        let recorder = await MainActor.run { () -> Recorder in
            let r = Recorder()
            r.visionEnabled = vision
            r.checkSteps = true
            _ = r.start()
            return r
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        var acted = await clickPage()
        acted = TestInput.type(sentence, in: textEditID) && acted
        try? await Task.sleep(nanoseconds: 900_000_000)
        key(1, command: true)                 // ⌘S
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        let sheetSeen = sheetShowing()
        key(53, command: false)               // Esc
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let steps: [Step] = await withCheckedContinuation { cont in
            DispatchQueue.main.async { recorder.finish { cont.resume(returning: $0) } }
        }
        log.check(prefix + "Found the page while recording", acted)
        log.check(prefix + "⌘S opened the Save sheet while recording", sheetSeen)
        log.check(prefix + "Recording typed the sentence once", occurrences(of: sentence) == 1, "document: “\(documentText().prefix(60))”")
        let kinds = steps.map { step -> String in
            switch step.kind {
            case .click: return "click"
            case .type: return "type"
            case .key: return "key"
            case .activate: return "activate"
            case .wait: return "wait"
            case .read: return "read"
            }
        }
        log.check(prefix + "Recorded a click, typing and two key presses", kinds.filter { $0 == "type" }.count == 1 && kinds.filter { $0 == "key" }.count == 2,
                  steps.map(\.summary).joined(separator: " | "))
        let task = Automation(name: "Self test TextEdit", steps: steps)
        if let i = task.steps.firstIndex(where: { if case .key = $0.kind { return true }; return false }) {
            log.check(prefix + "⌘S is recognised as a risky step", task.risk(at: i).risk == .risky, task.risk(at: i).reason ?? "")
            log.check(prefix + "Recorded that ⌘S opens the sheet", task.steps[i].expect.map { !$0.appeared.isEmpty || $0.windowTitle != nil } == true,
                      task.steps[i].expect?.summary ?? "nothing")
        }
        guard acted, sheetSeen else {
            await closeDocuments(mine)
            return
        }

        // Replay into a fresh document.
        guard await newDocument() else {
            log.check(prefix + "A second document opens", false,
                      "front “\(frontTitle() ?? "none")”, windows: " + windowTitles().map { "“\($0)”" }.joined(separator: ", ")
                      + (sheetShowing() ? ", a Save panel is still up" : ""))
            await closeDocuments(mine); return
        }
        if let t = frontTitle() { mine.insert(t) }
        let (error, notes) = await SelfTest.runTask(task, vision: vision)
        let once = occurrences(of: sentence) == 1
        log.check(prefix + "Replay types the sentence exactly once and closes the sheet", error == nil && once && !sheetShowing(),
                  (error ?? "finished") + " · document: “\(documentText().prefix(60))” · \(sheetReason() ?? "no Save panel")")
        log.line("      notes: \(notes)")
        if sheetShowing() { key(53, command: false); try? await Task.sleep(nanoseconds: 800_000_000) }

        // The ⌘S step with a wrong expectation: the run must stop there and never press it again.
        var broken = task
        if let i = broken.steps.firstIndex(where: { if case .key = $0.kind { return true }; return false }) {
            var e = broken.steps[i].expect ?? StepExpectation(changed: true)
            e.appeared = [ExpectedText("Sent to Ana")]
            e.windowTitle = nil
            broken.steps[i].expect = e
            broken.steps[i].onMismatch = .retryThenStop
        }
        guard await newDocument() else { log.check(prefix + "A third document opens", false); await closeDocuments(mine); return }
        if let t = frontTitle() { mine.insert(t) }
        let (stopError, stopNotes) = await SelfTest.runTask(broken, vision: vision)
        log.check(prefix + "A ⌘S whose result doesn't match stops the run without being repeated",
                  stopError?.contains("Sent to Ana") == true && !stopNotes.contains("trying once more") && occurrences(of: sentence) == 1,
                  (stopError ?? "the run finished, it should have stopped") + " · document: “\(documentText().prefix(60))”")
        log.check(prefix + "…and the stop says it may already have saved", stopError?.contains("may already have") == true, stopError ?? "")
        log.line("      notes: \(stopNotes)")
        if sheetShowing() { key(53, command: false); try? await Task.sleep(nanoseconds: 800_000_000) }

        await closeDocuments(mine)
    }

    static func frontTitle() -> String? {
        guard let el = appElement(), let w = AX.element(el, kAXFocusedWindowAttribute) else { return nil }
        return AX.string(w, kAXTitleAttribute)
    }

    static func app() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: textEditID).first
    }

    static func appElement() -> AXUIElement? {
        guard let a = app() else { return nil }
        let el = AXUIElementCreateApplication(a.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 1.0)
        return el
    }

    static func window() -> AXUIElement? {
        guard let el = appElement() else { return nil }
        return AX.element(el, kAXFocusedWindowAttribute) ?? AX.elements(AX.raw(el, kAXWindowsAttribute)).first
    }

    static func textArea() -> AXUIElement? {
        guard let w = mainWindow() else { return nil }
        return AX.collect(from: w, origin: nil, limit: 400) { $0 == "AXTextArea" }.first?.element
    }

    static func documentText() -> String {
        guard let t = textArea(), let v = AX.raw(t, kAXValueAttribute), CFGetTypeID(v) == CFStringGetTypeID() else { return "" }
        return v as! String
    }

    static func occurrences(of s: String) -> Int {
        documentText().components(separatedBy: s).count - 1
    }

    /// The document window, even while a Save panel has focus.
    static func mainWindow() -> AXUIElement? {
        guard let el = appElement() else { return nil }
        return AX.element(el, kAXMainWindowAttribute) ?? window()
    }

    /// Why a Save panel looks to be showing, or nil when none is.
    static func sheetReason() -> String? {
        guard let el = appElement() else { return nil }
        if let m = mainWindow(), AX.elements(AX.raw(m, kAXChildrenAttribute)).contains(where: { AX.role($0) == "AXSheet" }) {
            return "sheet on \(AX.string(m, kAXTitleAttribute) ?? "the document")"
        }
        if let f = AX.element(el, kAXFocusedWindowAttribute), let m = mainWindow(), !CFEqual(f, m) {
            let texts = AX.collect(from: f, origin: nil, limit: 300) { $0 == "AXStaticText" || $0 == "AXButton" }
            if texts.contains(where: { l in ["Save As", "Guardar como"].contains { (l.node.label ?? "").hasPrefix($0) } }) {
                return "Save window “\(AX.string(f, kAXTitleAttribute) ?? "")” in front"
            }
        }
        return nil
    }

    static func sheetShowing() -> Bool { sheetReason() != nil }

    static func openTextEdit(arguments: [String] = []) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: textEditID) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.arguments = arguments
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let a = app(), a.isFinishedLaunching, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == textEditID { break }
            app()?.activate(options: [.activateIgnoringOtherApps])
        }
        // TextEdit may open with the file chooser instead of a document: cancel it first.
        if let el = appElement(), AX.elements(AX.raw(el, kAXWindowsAttribute)).contains(where: { AX.string($0, kAXSubroleAttribute) == "AXDialog" }) {
            key(53, command: false)
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        return await newDocument()
    }

    /// ⌘N, then wait for a new Untitled document to be in front.
    static func newDocument() async -> Bool {
        app()?.activate(options: [.activateIgnoringOtherApps])
        try? await Task.sleep(nanoseconds: 400_000_000)
        let before = Set(windowTitles())
        key(45, command: true)   // ⌘N
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let t = frontTitle(), isUntitled(t), !before.contains(t), textArea() != nil else { continue }
            try? await Task.sleep(nanoseconds: 500_000_000)
            return true
        }
        return false
    }

    static func windowTitles() -> [String] {
        guard let el = appElement() else { return [] }
        return AX.elements(AX.raw(el, kAXWindowsAttribute)).compactMap { AX.string($0, kAXTitleAttribute) }
    }

    static func clickPage() async -> Bool {
        guard let t = textArea(), let f = AX.frame(t) else { return false }
        guard TestInput.click(CGPoint(x: f.minX + 60, y: f.minY + 30), in: textEditID) else { return false }
        try? await Task.sleep(nanoseconds: 900_000_000)
        return true
    }

    static func key(_ code: UInt16, command: Bool) {
        TestInput.key(code, modifiers: command ? CGEventFlags.maskCommand.rawValue : 0, in: textEditID)
    }

    /// Closes only the Untitled documents this test made, telling TextEdit to
    /// delete each. Anything else open in TextEdit is left exactly as it was.
    static func closeDocuments(_ titles: Set<String>) async {
        guard let el = appElement() else { return }
        for w in AX.elements(AX.raw(el, kAXWindowsAttribute)) {
            guard let title = AX.string(w, kAXTitleAttribute), titles.contains(title), isUntitled(title) else { continue }
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            app()?.activate(options: [.activateIgnoringOtherApps])
            try? await Task.sleep(nanoseconds: 300_000_000)
            // A Save panel still open on the document blocks closing it: cancel it first.
            for sheet in AX.elements(AX.raw(w, kAXChildrenAttribute)) where AX.role(sheet) == "AXSheet" {
                let buttons = AX.collect(from: sheet, origin: nil, limit: 200) { $0 == "AXButton" }
                if let cancel = buttons.first(where: { ["cancel", "cancelar"].contains(($0.node.label ?? "").lowercased()) }) {
                    AX.perform(cancel.element, kAXPressAction)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            if let close = AX.element(w, kAXCloseButtonAttribute) { AX.perform(close, kAXPressAction) } else { continue }
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let sheet = AX.elements(AX.raw(w, kAXChildrenAttribute)).first(where: { AX.role($0) == "AXSheet" }) else { continue }
                let buttons = AX.collect(from: sheet, origin: nil, limit: 200) { $0 == "AXButton" }
                if let delete = buttons.first(where: { ["delete", "eliminar", "borrar"].contains(($0.node.label ?? "").lowercased()) }) {
                    AX.perform(delete.element, kAXPressAction)
                }
                break
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
    }
}
