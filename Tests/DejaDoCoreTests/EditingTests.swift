import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import DejaDoCore

final class EditingTests: XCTestCase {
    private func chat(_ name: String, identifier: String? = nil) -> ElementLocator {
        ElementLocator(bundleID: "net.whatsapp.WhatsApp", appName: "WhatsApp", windowTitle: "WhatsApp", role: "AXButton",
                       subrole: nil, title: name, desc: nil, identifier: identifier, help: nil, value: nil,
                       label: name, path: [], frameInWindow: CGRect(x: 10, y: 100, width: 200, height: 40),
                       clickOffset: CGPoint(x: 0.5, y: 0.5), inMenu: false, anchors: nil, context: nil,
                       windowSize: CGSize(width: 900, height: 600))
    }

    func testRenameChangesEveryTextThatSaidTheOldName() {
        let l = chat("Kris", identifier: "chat-kris-row").renamed(to: "  Mum ")
        XCTAssertEqual(l.label, "Mum")
        XCTAssertEqual(l.title, "Mum")
        XCTAssertNil(l.identifier, "an id carrying the old name would lead back to Kris")
        XCTAssertNil(l.visual)
        XCTAssertEqual(l.identity.label, "Mum", "repairs are held to the name the person chose")
        XCTAssertEqual(l.frameInWindow, chat("Kris").frameInWindow)
    }

    func testRenameDropsWhatTiedItToTheOldOne() {
        var l = chat("Kris", identifier: "row-7")
        l.path = [PathStep(role: "AXRow", index: 7)]
        l.anchors = [Anchor(label: "Pinned", role: "AXStaticText", offset: CGPoint(x: 0, y: -30))]
        let r = l.renamed(to: "Mum")
        XCTAssertNil(r.identifier)
        XCTAssertTrue(r.path.isEmpty)
        XCTAssertNil(r.anchors)
        XCTAssertEqual(r.role, "AXButton")
    }

    func testEmptyOrSameNameChangesNothing() {
        XCTAssertEqual(chat("Kris").renamed(to: "   "), chat("Kris"))
        XCTAssertEqual(chat("Kris").renamed(to: "Kris"), chat("Kris"))
    }

    func testPositionClicksHaveNoName() {
        var l = chat("Kris")
        l.role = "AXPosition"
        XCTAssertNil(l.editableName)
    }

    func testRenamingAClickMovesItsExpectationToo() {
        var step = Step(kind: .click(target: chat("Kris"), button: .left, count: 1, modifiers: 0))
        step.expect = StepExpectation(appeared: [ExpectedText("Kris"), ExpectedText("online")], vanished: [],
                                      windowTitle: nil, bundleID: nil, changed: true)
        let renamed = step.renamingTarget(to: "Mum")
        XCTAssertEqual(renamed.targetName, "Mum")
        XCTAssertEqual(renamed.expect?.appeared.map(\.text), ["Mum", "online"])
        XCTAssertEqual(renamed.summary, "Click button “Mum”")
        XCTAssertEqual(renamed.id, step.id)
    }
}

final class EditFollowThroughTests: XCTestCase {
    private func task() -> Automation {
        var click = Step(kind: .key(code: 36, modifiers: 0, label: "Return"))
        click.expect = StepExpectation(appeared: [ExpectedText("thank u cuty", typed: true)], changed: true)
        var first = Step(kind: .type(text: "thank u cuty", askEachRun: false, secret: false, prompt: ""))
        first.expect = StepExpectation(appeared: [ExpectedText("Kris")], changed: true)
        return Automation(name: "t", steps: [Step(kind: .wait(seconds: 1)), first, click])
    }

    func testEditedTextIsWhatLaterStepsExpect() {
        var a = task()
        a.noteEdit(at: 1, replacing: "thank u cuty", with: "on my way")
        XCTAssertEqual(a.steps[2].expect?.appeared.first?.text, "on my way")
        XCTAssertEqual(a.steps[2].recheck, true)
        XCTAssertEqual(a.steps[1].recheck, true)
        XCTAssertNil(a.steps[0].recheck, "steps before the edit keep their checks as they are")
    }

    func testAStructuralEditMarksLaterChecksOnly() {
        var a = task()
        a.noteEdit(at: 2)
        XCTAssertNil(a.steps[1].recheck)
        XCTAssertEqual(a.steps[2].recheck, true)
        XCTAssertEqual(a.steps[2].expect?.appeared.first?.text, "thank u cuty")
    }

    func testOutOfRangeIsIgnored() {
        var a = task()
        let before = a
        a.noteEdit(at: 9)
        XCTAssertEqual(a, before)
    }

    func testOldTasksStillLoad() throws {
        let a = task()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as! [String: Any]
        var steps = json["steps"] as! [[String: Any]]
        for i in steps.indices { steps[i].removeValue(forKey: "recheck") }
        json["steps"] = steps
        let back = try JSONDecoder().decode(Automation.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(back.steps.count, 3)
        XCTAssertNil(back.steps[2].recheck)
    }
}

final class ExpectationSwapTests: XCTestCase {
    func testShortNamesOnlySwapWholeTexts() {
        let e = StepExpectation(appeared: [ExpectedText("8"), ExpectedText("18:05")], changed: true)
        XCTAssertEqual(e.replacing("8", with: "9").appeared.map(\.text), ["9", "18:05"])
    }

    func testLongerTextSwapsInsideOtherText() {
        let e = StepExpectation(appeared: [ExpectedText("You: thank u cuty")], windowTitle: "Kris", changed: true)
        let r = e.replacing("thank u cuty", with: "on my way")
        XCTAssertEqual(r.appeared.first?.text, "You: on my way")
        XCTAssertEqual(r.windowTitle, "Kris")
    }
}
