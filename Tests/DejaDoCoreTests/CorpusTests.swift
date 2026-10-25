import XCTest
@testable import DejaDoCore

final class CorpusTests: XCTestCase {
    func tempCorpus() -> RepairCorpus {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("dejado-corpus-\(UUID().uuidString)")
        return RepairCorpus(base: base)
    }

    func locator(label: String?, identifier: String? = nil) -> ElementLocator {
        ElementLocator(bundleID: "com.example.app", appName: "Example", windowTitle: "Main", role: "AXButton",
                       subrole: nil, title: label, desc: nil, identifier: identifier, help: nil, value: "secret value",
                       label: label, path: [PathStep(role: "AXGroup", index: 0), PathStep(role: "AXButton", index: 2)],
                       frameInWindow: CGRect(x: 10, y: 20, width: 80, height: 30), clickOffset: CGPoint(x: 0.5, y: 0.5),
                       inMenu: false, anchors: [Anchor(label: "Name", role: "AXStaticText", offset: CGPoint(x: -40, y: 0))],
                       context: ["Toolbar"], windowSize: CGSize(width: 800, height: 600))
    }

    func testRecordsAppendAndLoadBack() {
        let c = tempCorpus()
        XCTAssertEqual(c.count, 0)
        let r = RepairRecord(app: "com.example.app", kind: .healed, recorded: .init(locator(label: "Submit")),
                             found: .init(ElementSnapshot(role: "AXButton", label: "Submit request")),
                             signals: ["text": 0.8, "path": 1], score: 0.91, accepted: true)
        c.add(r)
        c.add(RepairRecord(app: "com.example.app", kind: .notFound, recorded: .init(locator(label: "Send")), accepted: false))
        XCTAssertEqual(c.count, 2)
        let back = c.load()
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[0].kind, .healed)
        XCTAssertEqual(back[0].found?.label, "Submit request")
        XCTAssertEqual(back[0].signals["text"], 0.8)
        XCTAssertEqual(back[1].kind, .notFound)
        XCTAssertTrue(c.summary().contains("1 healed"))
        XCTAssertTrue(c.summary().contains("1 not found"))
        c.clear()
        XCTAssertEqual(c.count, 0)
    }

    func testIdentityKeepsNoValuesOrTypedText() {
        let id = RepairRecord.Identity(locator(label: "Submit", identifier: "submitButton"))
        XCTAssertEqual(id.label, "Submit")
        XCTAssertEqual(id.identifier, "submitButton")
        XCTAssertEqual(id.anchors, ["Name"])
        XCTAssertEqual(id.pathLength, 2)
        XCTAssertEqual(id.context, ["Toolbar"])
        let data = try! JSONEncoder().encode(id)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret value"), "field contents never go in")
    }

    func testLongTextIsCut() {
        let long = String(repeating: "x", count: 500)
        let id = RepairRecord.Identity(role: "AXButton", label: long)
        XCTAssertEqual(id.label?.count, 60)
        let r = RepairRecord(app: "a", kind: .vision, recorded: id, accepted: true, note: long)
        XCTAssertEqual(r.note?.count, 200)
    }

    func testTrimKeepsTheNewest() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("dejado-corpus-\(UUID().uuidString)")
        let c = RepairCorpus(base: base, keep: 200)
        for i in 0..<400 {
            c.add(RepairRecord(app: "a", kind: .position, recorded: .init(role: "AXButton", label: "b\(i)"), accepted: true))
        }
        let all = c.load()
        XCTAssertLessThanOrEqual(all.count, 270)
        XCTAssertGreaterThanOrEqual(all.count, 200)
        XCTAssertEqual(all.last?.recorded.label, "b399")
    }
}
