import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import DejaDoCore

private func button(_ label: String?, role: String = "AXButton", id: String? = nil) -> ElementLocator {
    ElementLocator(bundleID: "com.chat", appName: "Chat", windowTitle: "Chat", role: role, subrole: nil, title: label,
                   desc: nil, identifier: id, help: nil, value: nil, label: label, path: [],
                   frameInWindow: CGRect(x: 10, y: 10, width: 40, height: 20), clickOffset: CGPoint(x: 0.5, y: 0.5),
                   inMenu: false)
}
private func click(_ label: String?) -> Step { Step(kind: .click(target: button(label), button: .left, count: 1, modifiers: 0)) }
private func type(_ text: String) -> Step { Step(kind: .type(text: text, askEachRun: false, secret: false, prompt: "")) }
private func key(_ code: UInt16, command: Bool = false, label: String = "") -> Step {
    Step(kind: .key(code: code, modifiers: command ? RiskGuesser.commandFlag : 0, label: label))
}

final class RiskTests: XCTestCase {
    func testWriteButtonsAreRisky() {
        for label in ["Send", "Save changes", "Delete", "Pay now", "Submit", "Place order", "Reply all", "Export…"] {
            XCTAssertEqual(RiskGuesser.guess([click(label)], at: 0).risk, .risky, label)
        }
        for label in ["Address", "Inbox", "Search", "Next", "Cancel", "Settings", "Kris", "Notebook", "Add", "+", "Apply filter"] {
            XCTAssertEqual(RiskGuesser.guess([click(label)], at: 0).risk, .normal, label)
        }
    }

    func testReturnAfterTypingSends() {
        let steps = [click("Kris"), type("thank you"), key(36, label: "Return")]
        let g = RiskGuesser.guess(steps, at: 2)
        XCTAssertEqual(g.risk, .risky)
        XCTAssertEqual(g.reason, "Return after typing usually sends or submits")
        XCTAssertEqual(RiskGuesser.guess([click("Kris"), key(36)], at: 1).risk, .normal)
        XCTAssertEqual(RiskGuesser.guess([key(1, command: true)], at: 0).risk, .risky, "⌘S")
        XCTAssertEqual(RiskGuesser.guess([key(48, command: true)], at: 0).risk, .normal, "⌘Tab")
    }

    func testIconButtonAfterTypingCommits() {
        let steps = [click("Note"), type("Lunch at 1"), click(nil), click(nil)]
        XCTAssertEqual(RiskGuesser.guess(steps, at: 2).risk, .risky)
        XCTAssertEqual(RiskGuesser.guess(steps, at: 3).risk, .normal, "only the first icon after typing")
    }

    func testPersonOverridesTheGuess() {
        var a = Automation(name: "t", steps: [click("Send")])
        XCTAssertEqual(a.risk(at: 0).risk, .risky)
        a.steps[0].risk = .normal
        XCTAssertEqual(a.risk(at: 0).risk, .normal)
    }

    func testRiskyStepsAreNeverRepeated() {
        var loop = StepCheckLoop(policy: .retryThenStop, canRedo: true, risky: true)
        loop.maxRechecks = 0
        let nothing = StepCheckResult(verdict: .failed, score: 0, missing: [], nothingHappened: true, summary: "why")
        XCTAssertEqual(loop.next(nothing), .stop("why"))
    }

    func testRiskyHalfMatchStops() {
        var loop = StepCheckLoop(policy: .retryThenStop, canRedo: true, risky: true)
        loop.maxRechecks = 0
        let half = StepCheckResult(verdict: .uncertain, score: 0.4, missing: [], nothingHappened: false, summary: "Partly matched")
        guard case .stop(let why) = loop.next(half) else { return XCTFail("risky uncertain must stop") }
        XCTAssertTrue(why.contains("won't guess"))
        var keepGoing = StepCheckLoop(policy: .keepGoing, canRedo: true, risky: true)
        keepGoing.maxRechecks = 0
        XCTAssertEqual(keepGoing.next(half), .proceed(note: "Partly matched"))
    }
}

final class VolatilityTests: XCTestCase {
    let ref = ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!

    func testChangingTextInsideLongerText() {
        for s in ["Updated 18:38", "Last updated at 8.30 pm", "Posted 3 days ago", "5 unread", "Inbox (12)",
                  "1 to 20 of 56", "Page 2", "Saved", "Delivered", "Mon, Oct 24, 2026", "2026-10-20", "Jul 8"] {
            XCTAssertTrue(Volatility.isVolatile(s, reference: ref), s)
        }
    }

    func testStableText() {
        for s in ["Ana Lopez", "Invoice 2024-11", "Born 1990-04-12", "March", "May I help you", "Q3 report.pdf",
                  "Send", "Order #A1B2"] {
            XCTAssertFalse(Volatility.isVolatile(s, reference: ref), s)
        }
    }
}

final class TypingCheckTests: XCTestCase {
    func testVerdicts() {
        XCTAssertEqual(TypingCheck.verdict(before: "", after: "hello world", typed: "hello world", secure: false), .landed)
        XCTAssertEqual(TypingCheck.verdict(before: "Dear ", after: "Dear Ana", typed: "Ana", secure: false), .landed)
        XCTAssertEqual(TypingCheck.verdict(before: "", after: "", typed: "hello", secure: false), .nothingTyped)
        XCTAssertEqual(TypingCheck.verdict(before: "", after: "hel", typed: "hello", secure: false), .partial)
        XCTAssertEqual(TypingCheck.verdict(before: "", after: "(876) 555-1234", typed: "8765551234", secure: false), .landed,
                       "a field that formats input")
        XCTAssertEqual(TypingCheck.verdict(before: "", after: "Jan 5, 2026", typed: "2026-01-05", secure: false), .unknown,
                       "a field that rewrites input is not a partial")
        XCTAssertEqual(TypingCheck.verdict(before: "Dear ", after: "Dear An", typed: "Ana", secure: false), .partial)
        XCTAssertEqual(TypingCheck.verdict(before: "", after: "", typed: "hi\n", secure: false), .unknown,
                       "Return may send and clear the field")
        XCTAssertEqual(TypingCheck.verdict(before: nil, after: "x", typed: "x", secure: false), .unknown)
    }

    func testPasswordFieldsCompareLength() {
        XCTAssertEqual(TypingCheck.verdict(before: "", after: "••••••", typed: "secret", secure: true), .landed)
        XCTAssertEqual(TypingCheck.verdict(before: "", after: "•••", typed: "secret", secure: true), .partial)
        XCTAssertEqual(TypingCheck.verdict(before: "", after: "", typed: "secret", secure: true), .nothingTyped)
    }
}

final class HealGuardTests: XCTestCase {
    func testSmallRenamesHealButDriftDoesNot() {
        let save = button("Save")
        var renamed = button("Save…")
        XCTAssertNotNil(HealGuard.repaired(renamed, from: save, risky: false))
        renamed = button("Delete")
        XCTAssertNil(HealGuard.repaired(renamed, from: save, risky: false))
    }

    func testRepairsAreHeldToTheOriginalNotTheLastRepair() {
        // Each step looks close to the last, but the chain drifts from "Archive" to "Achieve".
        var current = button("Archive")
        for next in ["Archive", "Archives", "Archived"] {
            guard let r = HealGuard.repaired(button(next), from: current, risky: false) else { return XCTFail(next) }
            current = r
        }
        XCTAssertEqual(current.original?.label, "Archive")
        XCTAssertNil(HealGuard.repaired(button("Achieve all"), from: current, risky: false))
    }

    func testRoleAndIdentifierChangesAreRefused() {
        let send = button("Send", id: "sendButton")
        XCTAssertNil(HealGuard.repaired(button("Send", role: "AXTextField", id: "sendButton"), from: send, risky: false))
        XCTAssertNil(HealGuard.repaired(button("Send", id: "deleteButton"), from: send, risky: false))
    }

    func testRiskyStepsNeedNearIdenticalText() {
        XCTAssertNil(HealGuard.repaired(button("Send later"), from: button("Send"), risky: true))
        XCTAssertNotNil(HealGuard.repaired(button("Send"), from: button("Send"), risky: true))
    }
}

final class OutcomeAndValidationTests: XCTestCase {
    func testOutcomes() {
        XCTAssertEqual(RunOutcome.classify(stoppedAt: nil, cancelled: false, riskyDone: [3]), .finished)
        let before = RunOutcome.classify(stoppedAt: 2, cancelled: false, riskyDone: [])
        XCTAssertFalse(before.mayRepeatChanges)
        let after = RunOutcome.classify(stoppedAt: 6, cancelled: false, riskyDone: [4])
        XCTAssertTrue(after.mayRepeatChanges)
        XCTAssertTrue(after.advice.contains("Step 5"))
    }

    func testValidatorCatchesDamage() {
        let s = Step(kind: .wait(seconds: 1))
        var a = Automation(name: "x", steps: [s, s, Step(kind: .wait(seconds: .nan)),
                                              Step(kind: .click(target: button("Go"), button: .left, count: 9, modifiers: 0))])
        let problems = TaskValidator.problems(a)
        XCTAssertEqual(problems.count, 3, "\(problems)")
        a.steps = [Step(kind: .wait(seconds: 2))]
        XCTAssertTrue(TaskValidator.problems(a).isEmpty)
    }

    func testDamagedFilesAreReportedNotDropped() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = Persistence(base: base)
        XCTAssertTrue(store.save(Automation(name: "Good", steps: [])))
        try Data("{nope".utf8).write(to: store.dir.appendingPathComponent("broken.json"))
        var newer = Automation(name: "Future", steps: [])
        newer.format = 99
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(newer).write(to: store.dir.appendingPathComponent("\(newer.id).json"))
        let result = store.scan()
        XCTAssertEqual(result.automations.map(\.name), ["Good"])
        XCTAssertEqual(result.problems.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.dir.appendingPathComponent("broken.json").path),
                      "never touch a damaged file")
    }

    func testImportRejectsDamagedTasks() throws {
        let s = Step(kind: .wait(seconds: 1))
        let data = try TaskFile.encode(Automation(name: "x", steps: [s, s]))
        XCTAssertThrowsError(try TaskFile.decode(data))
    }
}

final class AssistTests: XCTestCase {
    func testVariablesFromFieldLabels() {
        var t1 = type("INV-2041"); t1.fieldLabel = "Invoice No."
        var t2 = type("ana@example.com")
        let t3 = type("hello")
        var t4 = type("Kingston"); t4.fieldLabel = "Enter your city"
        t2.fieldLabel = nil
        var a = Automation(name: "x", steps: [t1, t2, t3, t4])
        let s = VariableSuggester.suggestions(for: a)
        XCTAssertEqual(s.map(\.name), ["invoice no", "email", "city"])
        VariableSuggester.apply(s[0], to: &a)
        XCTAssertEqual(a.variableNames, ["invoice no"])
        XCTAssertEqual(VariableSuggester.suggestions(for: a).map(\.name), ["email", "city"])
    }

    func testRepeatedLabelsGetDistinctNames() {
        var a1 = type("A"); a1.fieldLabel = "Name"
        var a2 = type("B"); a2.fieldLabel = "Name"
        XCTAssertEqual(VariableSuggester.suggestions(for: Automation(name: "x", steps: [a1, a2])).map(\.name), ["name", "name 2"])
    }

    func testTrimSuggestions() {
        var dead = click("Help"); dead.noEffect = true
        var focus = click("Message"); focus.noEffect = true
        let steps = [Step(kind: .activate(bundleID: "a", name: "A")), dead, focus, type("hi"),
                     key(48, command: true), Step(kind: .activate(bundleID: "b", name: "B"))]
        let ids = StepTrim.suggestions(for: Automation(name: "x", steps: steps)).map(\.stepID)
        XCTAssertEqual(ids, [dead.id, steps[5].id], "focusing click kept; trailing switch flagged")
        let ending = [click("Kris"), key(48, command: true)]
        XCTAssertEqual(StepTrim.suggestions(for: Automation(name: "x", steps: ending)).map(\.stepID), [ending[1].id])
    }

    func testPopupRules() {
        let normal = ScreenState(bundleID: "com.app", windowTitle: "Inbox", texts: [SeenText("Inbox"), SeenText("Compose")])
        let popup = ScreenState(bundleID: "com.app", windowTitle: "Inbox",
                                texts: [SeenText("Inbox"), SeenText("Compose"), SeenText("What's New in 5.2"),
                                        SeenText("Updated 18:38"), SeenText("Continue")])
        let sig = PopupRule.signature(now: popup, normal: normal)
        XCTAssertEqual(sig, ["What's New in 5.2", "Continue"])
        let rule = PopupRule(name: "What's New", bundleID: "com.app", detect: sig, dismiss: .key(code: 53, modifiers: 0, label: "Esc"))
        XCTAssertTrue(rule.matches(popup))
        XCTAssertFalse(rule.matches(normal))
        var otherApp = popup; otherApp.bundleID = "com.other"
        XCTAssertFalse(rule.matches(otherApp))
    }

    func testHistoryKeepsNoTypedText() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let history = RunHistory(base: base)
        var field = type("my secret note"); field.fieldLabel = "Note"
        let steps = [field, type("plain"), type("Hi {{name}}")].enumerated().map {
            RunRecord.StepRun(index: $0.offset, summary: $0.element.safeSummary, note: nil, ran: true)
        }
        let id = UUID()
        for _ in 0..<(RunHistory.keep + 5) {
            history.add(RunRecord(started: Date(), duration: 1, outcome: "Done.", succeeded: true, steps: steps), to: id)
        }
        let loaded = history.load(id)
        XCTAssertEqual(loaded.count, RunHistory.keep)
        let raw = String(decoding: try Data(contentsOf: history.dir.appendingPathComponent("\(id).json")), as: UTF8.self)
        XCTAssertFalse(raw.contains("my secret note"))
        XCTAssertFalse(raw.contains("plain"))
        XCTAssertEqual(loaded[0].steps.map(\.summary), ["Type into “Note”", "Type text", "Type {{name}}"])
    }

    func testSkillExport() {
        var send = key(36, label: "Return")
        send.expect = StepExpectation(appeared: [ExpectedText("Delivered to Ana")], changed: true)
        var a = Automation(name: "Message Kris", steps: [
            Step(kind: .activate(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp")),
            click("Kris"), type("Hi {{name}}"), send, Step(kind: .type(text: "", askEachRun: true, secret: true, prompt: "Password"))
        ])
        a.steps[3].expect = StepExpectation(appeared: [ExpectedText("Sent")], windowTitle: "Kris", changed: true)
        a.goal = "Sends Kris a quick message."
        let md = SkillExport.markdown(a)
        XCTAssertTrue(md.hasPrefix("---\nname: message-kris\ndescription: Sends Kris a quick message.\n---"))
        XCTAssertTrue(md.contains("dejado://run?task=\(a.id.uuidString)&name=VALUE"))
        XCTAssertTrue(md.contains("3. Type Hi {{name}}"))
        XCTAssertTrue(md.contains("4. Press Return"))
        XCTAssertTrue(md.contains("do it once only"))
        XCTAssertTrue(md.contains("the window is titled “Kris”"))
        XCTAssertFalse(md.contains("CGRect") || md.contains("frameInWindow"))
    }
}
