import AppKit
import ApplicationServices
@preconcurrency import DejaDoCore

/// Typing into Excel's grid, which describes very little of itself through
/// Accessibility. Records 1234, Tab, 4321, Tab, =A1+B1, Return in a new
/// workbook, replays it into another new workbook, and reads the screen for
/// 5555. (Not 7 + 8: row 15's label is always on screen.)
///
/// Only the workbooks the test makes are closed, without saving. Skipped,
/// without failing, when Excel isn't installed or won't open a workbook
/// (a sign-in or licence screen, say).
enum ExcelSelfTest {
    static let excelID = "com.microsoft.Excel"
    static let total = "5555"
    /// What Excel calls a new workbook, in English and Spanish.
    static let newNames = ["Book", "Libro", "Workbook"]

    static func run(_ log: SelfTest.Log, vision: Bool) async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: excelID) else {
            log.check("Excel: record and replay", true, "Excel isn't installed, skipped", counted: false)
            return
        }
        guard vision else {
            log.check("Excel: record and replay", true, "needs Screen Recording to read the result, skipped", counted: false)
            return
        }
        log.line("Excel")
        let wasRunning = ElementFinder.runningApp(excelID) != nil
        let previous = NSWorkspace.shared.frontmostApplication
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let a = ElementFinder.runningApp(excelID), a.isFinishedLaunching { break }
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        var mine = Set<String>()
        guard let first = await newWorkbook() else {
            log.check("Excel: record and replay", true, "Excel didn't open a blank workbook (sign-in or start screen?), skipped", counted: false)
            await finish(mine, wasRunning: wasRunning, previous: previous)
            return
        }
        mine.insert(first)
        log.check("Excel opens a blank workbook", true, first)

        // Record.
        let recorder = await MainActor.run { () -> Recorder in
            let r = Recorder()
            r.visionEnabled = vision
            r.checkSteps = true
            _ = r.start()
            return r
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        var acted = type("1234")
        key(48)                       // Tab
        acted = type("4321") && acted
        key(48)
        acted = type("=A1+B1") && acted
        key(36)                       // Return
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let steps: [Step] = await withCheckedContinuation { cont in
            DispatchQueue.main.async { recorder.finish { cont.resume(returning: $0) } }
        }
        let shown = await shows(total)
        log.check("Excel: recording shows \(total)", acted && shown)
        let typed = steps.filter { if case .type = $0.kind { return true }; return false }.count
        let keys = steps.filter { if case .key = $0.kind { return true }; return false }.count
        log.check("Excel: recorded three typed values and three keys", typed == 3 && keys == 3,
                  steps.map(\.summary).joined(separator: " | "))
        let task = Automation(name: "Self test Excel", steps: steps)
        guard acted, shown else { await finish(mine, wasRunning: wasRunning, previous: previous); return }

        // Replay into a second workbook.
        guard let second = await newWorkbook() else {
            log.check("Excel: a second workbook opens", false)
            await finish(mine, wasRunning: wasRunning, previous: previous)
            return
        }
        mine.insert(second)
        let before = await shows(total)
        let (error, notes) = await SelfTest.runTask(task, vision: vision)
        let after = await shows(total)
        log.check("Excel: replay into a new workbook shows \(total)", !before && error == nil && after,
                  (error ?? "finished") + (before ? " · it was already showing before the replay" : ""))
        log.line("      notes: \(notes)")
        await finish(mine, wasRunning: wasRunning, previous: previous)
    }

    static func appElement() -> AXUIElement? {
        guard let a = ElementFinder.runningApp(excelID) else { return nil }
        let el = AXUIElementCreateApplication(a.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 2.0)
        return el
    }

    static func titles() -> [String] {
        guard let el = appElement() else { return [] }
        return AX.elements(AX.raw(el, kAXWindowsAttribute)).compactMap { AX.string($0, kAXTitleAttribute) }
    }

    static func frontWindow() -> AXUIElement? {
        guard let el = appElement() else { return nil }
        return AX.element(el, kAXFocusedWindowAttribute)
    }

    /// ⌘N, then the title of the new workbook once it's in front.
    static func newWorkbook() async -> String? {
        ElementFinder.runningApp(excelID)?.activate(options: [.activateIgnoringOtherApps])
        try? await Task.sleep(nanoseconds: 600_000_000)
        let before = Set(titles())
        TestInput.key(45, modifiers: CGEventFlags.maskCommand.rawValue, in: excelID)   // ⌘N
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let w = frontWindow(), let t = AX.string(w, kAXTitleAttribute), !before.contains(t),
                  newNames.contains(where: { t.hasPrefix($0) }) else { continue }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return t
        }
        return nil
    }

    static func type(_ text: String) -> Bool {
        let ok = TestInput.type(text, in: excelID)
        usleep(700_000)
        return ok
    }

    static func key(_ code: UInt16) {
        TestInput.key(code, in: excelID)
        usleep(700_000)
    }

    /// Whether the front workbook shows the text as a cell of its own, read from the screen.
    static func shows(_ text: String) async -> Bool {
        guard let w = frontWindow(), let f = AX.frame(w) else { return false }
        for _ in 0..<4 {
            if let read = await ScreenVision.read(windowFrame: f, ocr: true),
               read.lines.contains(where: { $0.text.trimmingCharacters(in: .whitespaces) == text }) { return true }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        return false
    }

    /// Closes the workbooks this test made without saving, and quits Excel if the test opened it.
    static func finish(_ mine: Set<String>, wasRunning: Bool, previous: NSRunningApplication?) async {
        if let el = appElement() {
            for w in AX.elements(AX.raw(el, kAXWindowsAttribute)) {
                guard let t = AX.string(w, kAXTitleAttribute), mine.contains(t) else { continue }
                AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
                ElementFinder.runningApp(excelID)?.activate(options: [.activateIgnoringOtherApps])
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let close = AX.element(w, kAXCloseButtonAttribute) else { continue }
                AX.perform(close, kAXPressAction)
                for _ in 0..<16 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    let places = AX.elements(AX.raw(w, kAXChildrenAttribute)).filter { AX.role($0) == "AXSheet" }
                        + AX.elements(AX.raw(el, kAXWindowsAttribute)).filter { AX.string($0, kAXSubroleAttribute) == "AXDialog" }
                    let buttons = places.flatMap { AX.collect(from: $0, origin: nil, limit: 200) { $0 == "AXButton" } }
                    if let dont = buttons.first(where: { b in
                        let l = (b.node.label ?? "").lowercased().replacingOccurrences(of: "’", with: "'")
                        return l == "don't save" || l == "no guardar" || l == "delete" || l == "eliminar"
                    }) {
                        AX.perform(dont.element, kAXPressAction)
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        if !wasRunning, titles().allSatisfy({ t in mine.contains(t) || t.isEmpty }) {
            ElementFinder.runningApp(excelID)?.terminate()
        }
        previous?.activate(options: [.activateIgnoringOtherApps])
    }
}
