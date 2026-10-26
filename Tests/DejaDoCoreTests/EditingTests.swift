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

    func testRenameKeepsAnUnrelatedIdentifier() {
        XCTAssertEqual(chat("Kris", identifier: "row-7").renamed(to: "Mum").identifier, "row-7")
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
