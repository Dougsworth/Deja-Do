import XCTest
import CoreGraphics
@testable import DejaDoCore

final class SettleDetectorTests: XCTestCase {
    func testSettlesAfterQuietPeriod() {
        var d = SettleDetector(quietPeriod: 0.25)
        XCTAssertFalse(d.observe(fingerprint: 1, busy: false, at: 0))
        XCTAssertFalse(d.observe(fingerprint: 1, busy: false, at: 0.1))
        XCTAssertTrue(d.observe(fingerprint: 1, busy: false, at: 0.3))
    }

    func testChangeRestartsTheClock() {
        var d = SettleDetector(quietPeriod: 0.25)
        _ = d.observe(fingerprint: 1, busy: false, at: 0)
        XCTAssertFalse(d.observe(fingerprint: 2, busy: false, at: 0.3))
        XCTAssertFalse(d.observe(fingerprint: 2, busy: false, at: 0.4))
        XCTAssertTrue(d.observe(fingerprint: 2, busy: false, at: 0.6))
    }

    func testBusyIndicatorBlocksSettling() {
        var d = SettleDetector(quietPeriod: 0.1)
        _ = d.observe(fingerprint: 1, busy: true, at: 0)
        XCTAssertFalse(d.observe(fingerprint: 1, busy: true, at: 1))
    }

    func testFingerprintIgnoresSubPointJitter() {
        var a = TreeFingerprint(), b = TreeFingerprint(), c = TreeFingerprint()
        a.add(role: "AXButton", childCount: 0, x: 100, y: 50, w: 80, h: 20)
        b.add(role: "AXButton", childCount: 0, x: 100.4, y: 50.3, w: 80, h: 20)
        c.add(role: "AXButton", childCount: 0, x: 140, y: 50, w: 80, h: 20)
        XCTAssertEqual(a.finalize(), b.finalize())
        XCTAssertNotEqual(a.finalize(), c.finalize())
    }
}

final class ModelTests: XCTestCase {
    private func sample() -> Automation {
        let target = ElementLocator(bundleID: "com.example", appName: "Example", windowTitle: nil, role: "AXButton",
                                    subrole: nil, title: "Save", desc: nil, identifier: nil, help: nil, value: nil,
                                    label: "Save", path: [PathStep(role: "AXButton", index: 0)],
                                    frameInWindow: CGRect(x: 10, y: 10, width: 60, height: 20),
                                    clickOffset: CGPoint(x: 0.5, y: 0.5), inMenu: false)
        return Automation(name: "Test", steps: [
            Step(kind: .activate(bundleID: "com.example", name: "Example")),
            Step(kind: .click(target: target, button: .left, count: 1, modifiers: 0)),
            Step(kind: .type(text: "hello", askEachRun: false, secret: false, prompt: ""))
        ])
    }

    func testLocatorsSavedBeforeAnchorsExistStillLoad() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sample())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("anchors"), "nil fields should be left out, like files from the Once days")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(Automation.self, from: data)
        XCTAssertEqual(back.steps.count, 3)
        if case .click(let t, _, _, _) = back.steps[1].kind {
            XCTAssertNil(t.anchors)
            XCTAssertEqual(t.label, "Save")
        } else {
            XCTFail("second step should be a click")
        }
    }

    func testAutomationsFromOnceAreMigrated() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("Once/Automations", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)

        let a = sample()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(a).write(to: old.appendingPathComponent("\(a.id.uuidString).json"))

        let store = Persistence(base: base)
        XCTAssertEqual(store.loadAll().map(\.id), [a.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent("\(a.id.uuidString).json").path),
                      "the original file must be left in place")
    }

    func testWeightStoreRoundTrips() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = WeightStore(base: base)
        var w = MatchWeights()
        w[.text] = 5.5
        store.save(["com.example": w])
        XCTAssertEqual(store.load()["com.example"]?[.text], 5.5)
    }

    func testSummariesReadNaturally() {
        let steps = sample().steps
        XCTAssertEqual(steps[0].summary, "Switch to Example")
        XCTAssertEqual(steps[1].summary, "Click button “Save”")
        XCTAssertEqual(steps[2].summary, "Type “hello”")
        XCTAssertEqual(Step(kind: .wait(seconds: 2)).summary, "Wait 2 seconds")
        XCTAssertEqual(Step(kind: .wait(seconds: 1.5)).summary, "Wait 1.5 seconds")
    }
}
