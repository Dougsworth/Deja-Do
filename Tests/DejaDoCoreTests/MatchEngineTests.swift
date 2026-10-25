import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import DejaDoCore

final class MatchEngineTests: XCTestCase {
    private func locator(role: String = "AXButton", label: String? = nil, center: CGPoint? = nil,
                         size: CGSize = CGSize(width: 20, height: 20), path: [PathStep] = [],
                         anchors: [Anchor]? = nil, window: CGSize? = nil, identifier: String? = nil) -> ElementLocator {
        ElementLocator(bundleID: "com.example.app", appName: "Example", windowTitle: "Main", role: role,
                       subrole: nil, title: label, desc: nil, identifier: identifier, help: nil, value: nil,
                       label: label, path: path,
                       frameInWindow: center.map { CGRect(x: $0.x - size.width / 2, y: $0.y - size.height / 2,
                                                          width: size.width, height: size.height) },
                       clickOffset: CGPoint(x: 0.5, y: 0.5), inMenu: false, anchors: anchors, context: nil,
                       windowSize: window)
    }

    private func element(_ role: String = "AXButton", _ label: String? = nil, at center: CGPoint,
                         size: CGSize = CGSize(width: 20, height: 20), identifier: String? = nil) -> ElementSnapshot {
        ElementSnapshot(role: role, title: label, identifier: identifier, label: label,
                        frame: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                      width: size.width, height: size.height))
    }

    func testRenamedPunctuationIsConfident() {
        let target = locator(label: "Save", center: CGPoint(x: 100, y: 100))
        let report = MatchEngine().match(target, among: [
            element("AXButton", "Cancel", at: CGPoint(x: 180, y: 100)),
            element("AXButton", "Save…", at: CGPoint(x: 100, y: 100))
        ])
        guard case .confident(let best) = report.decision else { return XCTFail("expected confident, got \(report.decision)") }
        XCTAssertEqual(best.index, 1)
    }

    func testTwoIdenticalButtonsWithNoPositionAreAmbiguous() {
        let target = locator(label: "Open", center: nil)
        let report = MatchEngine().match(target, among: [
            element("AXButton", "Open", at: CGPoint(x: 100, y: 100)),
            element("AXButton", "Open", at: CGPoint(x: 600, y: 400))
        ])
        guard case .ambiguous(let list) = report.decision else { return XCTFail("expected ambiguous, got \(report.decision)") }
        XCTAssertEqual(list.count, 2)
    }

    func testLabelInsideItsOwnButtonIsNotARival() {
        // A cell and the text inside it carry the same label. That is one
        // target, not two, so the match should still be confident.
        let target = locator(role: "AXCell", label: "Report.pdf", center: CGPoint(x: 200, y: 120),
                             size: CGSize(width: 300, height: 22))
        let report = MatchEngine().match(target, among: [
            element("AXCell", "Report.pdf", at: CGPoint(x: 200, y: 120), size: CGSize(width: 300, height: 22)),
            element("AXStaticText", "Report.pdf", at: CGPoint(x: 150, y: 120), size: CGSize(width: 120, height: 16)),
            element("AXCell", "Notes.txt", at: CGPoint(x: 200, y: 142), size: CGSize(width: 300, height: 22))
        ])
        guard case .confident(let best) = report.decision else { return XCTFail("expected confident, got \(report.decision)") }
        XCTAssertEqual(best.index, 0)
    }

    func testOnlyButtonWithThatLabelIsFoundWhereverItMoved() {
        // A page reflowed: the button moved from the bottom left to the top
        // right, its tree path and neighbours changed, but it's still the one
        // control labelled "Submit".
        let target = locator(label: "Submit", center: CGPoint(x: 80, y: 500),
                             path: [PathStep(role: "AXGroup", index: 0), PathStep(role: "AXGroup", index: 2), PathStep(role: "AXButton", index: 0)],
                             anchors: [Anchor(label: "Email", role: "AXStaticText", offset: CGPoint(x: 0, y: -60))],
                             window: CGSize(width: 900, height: 700))
        let report = MatchEngine().match(target, among: [
            ElementSnapshot(role: "AXStaticText", label: "Email", frame: CGRect(x: 60, y: 300, width: 40, height: 16)),
            ElementSnapshot(role: "AXStaticText", label: "Name", frame: CGRect(x: 60, y: 400, width: 40, height: 16)),
            ElementSnapshot(role: "AXTextField", label: "Name", frame: CGRect(x: 60, y: 420, width: 300, height: 30)),
            ElementSnapshot(role: "AXButton", label: "Submit", frame: CGRect(x: 760, y: 120, width: 90, height: 32),
                            path: [PathStep(role: "AXGroup", index: 0), PathStep(role: "AXGroup", index: 0), PathStep(role: "AXGroup", index: 1), PathStep(role: "AXButton", index: 0)])
        ], windowSize: CGSize(width: 900, height: 700))
        guard case .confident(let best) = report.decision else { return XCTFail("expected confident, got \(report.decision)") }
        XCTAssertEqual(best.index, 3)

        // With a second "Submit" anywhere, that shortcut must not apply.
        let twins = MatchEngine().match(target, among: [
            ElementSnapshot(role: "AXButton", label: "Submit", frame: CGRect(x: 760, y: 120, width: 90, height: 32)),
            ElementSnapshot(role: "AXButton", label: "Submit", frame: CGRect(x: 760, y: 420, width: 90, height: 32))
        ], windowSize: CGSize(width: 900, height: 700))
        if case .confident = twins.decision { XCTFail("two buttons with the same label far from the spot are a guess") }
    }

    func testUnrelatedRenameIsNotTrusted() {
        let target = locator(label: "Send", center: CGPoint(x: 100, y: 100))
        let report = MatchEngine().match(target, among: [
            element("AXButton", "Submit", at: CGPoint(x: 100, y: 100)),
            element("AXButton", "Cancel", at: CGPoint(x: 200, y: 100))
        ])
        if case .confident = report.decision { XCTFail("a different label in the same spot must go to the AI") }
    }

    func testIconButtonFoundThroughAnchorAfterLayoutShift() {
        // An unlabelled button sat 80pt right of the "Email" label. The whole
        // panel then moved 200pt right, and a different icon now sits where
        // the button used to be.
        let target = locator(center: CGPoint(x: 300, y: 50),
                             anchors: [Anchor(label: "Email", role: "AXStaticText", offset: CGPoint(x: -80, y: 0))],
                             window: CGSize(width: 1000, height: 700))
        let report = MatchEngine().match(target, among: [
            element("AXButton", nil, at: CGPoint(x: 300, y: 50)),
            element("AXStaticText", "Email", at: CGPoint(x: 420, y: 50), size: CGSize(width: 40, height: 16)),
            element("AXButton", nil, at: CGPoint(x: 500, y: 50))
        ], windowSize: CGSize(width: 1000, height: 700))
        XCTAssertEqual(report.anchorsMatched, 1)
        XCTAssertEqual(report.shift?.dx ?? 0, 200, accuracy: 0.5)
        guard case .confident(let best) = report.decision else { return XCTFail("expected confident, got \(report.decision)") }
        XCTAssertEqual(best.index, 2)
    }

    func testStableIdentifierBeatsPosition() {
        let target = locator(label: "Go", center: CGPoint(x: 100, y: 100), identifier: "primaryAction")
        let report = MatchEngine().match(target, among: [
            element("AXButton", "Go", at: CGPoint(x: 100, y: 100), identifier: "secondaryAction"),
            element("AXButton", "Go", at: CGPoint(x: 140, y: 100), identifier: "primaryAction")
        ])
        XCTAssertEqual(report.best?.index, 1)
    }

    func testConsensusShiftIgnoresAnOutlier() {
        let a = Anchor(label: "A", role: "AXStaticText", offset: .zero)
        let fits = [
            MatchEngine.AnchorFit(anchor: a, now: .zero, displacement: CGVector(dx: 100, dy: 0)),
            MatchEngine.AnchorFit(anchor: a, now: .zero, displacement: CGVector(dx: 104, dy: 2)),
            MatchEngine.AnchorFit(anchor: a, now: .zero, displacement: CGVector(dx: -300, dy: 250))
        ]
        let shift = MatchEngine.consensusShift(fits)
        XCTAssertEqual(shift?.dx ?? 0, 102, accuracy: 0.01)
        XCTAssertEqual(shift?.dy ?? 0, 1, accuracy: 0.01)
    }

    func testConsensusNeedsAgreementWhenAnchorsDisagree() {
        let a = Anchor(label: "A", role: "AXStaticText", offset: .zero)
        let fits = [
            MatchEngine.AnchorFit(anchor: a, now: .zero, displacement: CGVector(dx: 100, dy: 0)),
            MatchEngine.AnchorFit(anchor: a, now: .zero, displacement: CGVector(dx: -300, dy: 250))
        ]
        XCTAssertNil(MatchEngine.consensusShift(fits))
    }

    func testRightPinnedControlFollowsWindowResize() {
        let s = MatchEngine.spatialScore(recorded: CGPoint(x: 950, y: 30), candidate: CGPoint(x: 1350, y: 30),
                                         shift: nil, recordedWindow: CGSize(width: 1000, height: 700),
                                         currentWindow: CGSize(width: 1400, height: 700))
        XCTAssertGreaterThan(s, 0.99)
    }

    func testPathSimilarityPrefersIndexShiftOverRoleChange() {
        let base = [PathStep(role: "AXGroup", index: 0), PathStep(role: "AXButton", index: 2)]
        let shifted = [PathStep(role: "AXGroup", index: 0), PathStep(role: "AXButton", index: 3)]
        let changed = [PathStep(role: "AXGroup", index: 0), PathStep(role: "AXCheckBox", index: 2)]
        XCTAssertEqual(MatchEngine.pathSimilarity(base, base), 1)
        XCTAssertGreaterThan(MatchEngine.pathSimilarity(base, shifted), MatchEngine.pathSimilarity(base, changed))
    }

    func testLearningFromAnAIFixReordersTheRanking() {
        // Position says "Exit", meaning says "Export PDF". The AI picks the
        // latter, and after one update the engine agrees on its own.
        let target = locator(label: "Export", center: CGPoint(x: 100, y: 100))
        let candidates = [
            element("AXButton", "Export PDF", at: CGPoint(x: 400, y: 100)),
            element("AXButton", "Exit", at: CGPoint(x: 100, y: 100))
        ]
        var engine = MatchEngine()
        let before = engine.match(target, among: candidates)
        XCTAssertEqual(before.best?.index, 1)

        let chosen = before.ranked.first { $0.index == 0 }!
        let others = before.ranked.filter { $0.index != 0 }.map(\.features)
        engine.weights.learn(chosen: chosen.features, others: others)

        XCTAssertGreaterThan(engine.weights[.text], MatchWeights.defaults[.text]!)
        XCTAssertLessThan(engine.weights[.spatial], MatchWeights.defaults[.spatial]!)
        XCTAssertEqual(engine.match(target, among: candidates).best?.index, 0)
    }

    func testWeightsStayWithinBounds() {
        var w = MatchWeights()
        for _ in 0..<100 {
            w.learn(chosen: [.text: 1, .spatial: 0], others: [[.text: 0, .spatial: 1]])
        }
        XCTAssertLessThanOrEqual(w[.text], MatchWeights.ceiling)
        XCTAssertGreaterThanOrEqual(w[.spatial], MatchWeights.floor)
    }
}
