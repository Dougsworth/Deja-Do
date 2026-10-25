import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import DejaDoCore

final class StepExpectationTests: XCTestCase {
    private let window = CGSize(width: 900, height: 600)

    private func t(_ s: String, _ x: CGFloat, _ y: CGFloat) -> SeenText {
        SeenText(s, frame: CGRect(x: x, y: y, width: 120, height: 18))
    }

    /// A chat app before clicking a contact: the list, no conversation open.
    private var chatList: ScreenState {
        ScreenState(bundleID: "com.chat", windowTitle: "Chat", windowSize: window, texts: [
            t("Chats", 20, 20), t("Ana Lopez", 20, 80), t("Ben Carter", 20, 120), t("Cara Diaz", 20, 160),
            t("Pick a conversation", 400, 300)
        ])
    }

    private func chatOpen(with name: String, on base: ScreenState? = nil) -> ScreenState {
        var s = base ?? chatList
        s.texts.removeAll { $0.text == "Pick a conversation" }
        s.texts.append(t(name, 400, 20))         // the conversation header
        s.texts.append(t("Type a message", 400, 560))
        return s
    }

    func testClickingAContactExpectsTheNameInTheHeader() {
        let e = StepExpectation.derive(before: chatList, after: chatOpen(with: "Ana Lopez"))
        // The name was already in the list, but a second copy appeared at the top.
        XCTAssertEqual(e.appeared.first?.text, "Ana Lopez")
        XCTAssertEqual(e.appeared.first?.frame?.minX, 400)
        XCTAssertTrue(e.appeared.contains { $0.text == "Type a message" })
        XCTAssertEqual(e.vanished, ["Pick a conversation"])
        XCTAssertTrue(e.changed)
        XCTAssertEqual(e.summary, "Then expects “Ana Lopez” and 1 more")
    }

    func testRunThatOpensTheRightChatPasses() {
        let e = StepExpectation.derive(before: chatList, after: chatOpen(with: "Ana Lopez"))
        let r = StepVerifier.check(e, before: chatList, after: chatOpen(with: "Ana Lopez"))
        XCTAssertEqual(r.verdict, .passed)
        XCTAssertEqual(r.score, 1, accuracy: 1e-9)
    }

    func testRunThatOpensTheWrongChatFails() {
        let e = StepExpectation.derive(before: chatList, after: chatOpen(with: "Ana Lopez"))
        let r = StepVerifier.check(e, before: chatList, after: chatOpen(with: "Ben Carter"))
        XCTAssertEqual(r.verdict, .failed)
        XCTAssertTrue(r.missing.contains("“Ana Lopez”"))
        XCTAssertFalse(r.nothingHappened)
    }

    func testClickThatDidNothingIsCaught() {
        let e = StepExpectation.derive(before: chatList, after: chatOpen(with: "Ana Lopez"))
        let r = StepVerifier.check(e, before: chatList, after: chatList)
        XCTAssertEqual(r.verdict, .failed)
        XCTAssertTrue(r.nothingHappened)
        XCTAssertEqual(r.summary, "Nothing on screen changed after this step")
    }

    func testChatAlreadyOpenStillPasses() {
        // Ana's chat was left open from last time, so clicking her changes nothing,
        // but the screen is exactly where the recording ended up.
        let e = StepExpectation.derive(before: chatList, after: chatOpen(with: "Ana Lopez"))
        let open = chatOpen(with: "Ana Lopez")
        let r = StepVerifier.check(e, before: open, after: open)
        XCTAssertEqual(r.verdict, .passed)
    }

    func testClocksCountersAndTypingNoticesAreIgnored() {
        let before = ScreenState(texts: [SeenText("Inbox 3"), SeenText("Drafts")])
        let after = ScreenState(texts: [SeenText("Inbox 2"), SeenText("Drafts"), SeenText("10:42 AM"),
                                        SeenText("2 min ago"), SeenText("typing…"), SeenText("42")])
        let e = StepExpectation.derive(before: before, after: after)
        XCTAssertTrue(e.appeared.isEmpty, "got \(e.appeared)")
        XCTAssertTrue(e.vanished.isEmpty, "a counter changing isn't text going away: \(e.vanished)")
        XCTAssertTrue(e.changed)
    }

    func testVolatileText() {
        for s in ["10:42", "10:42 pm", "3m", "5 mins ago", "Yesterday", "Last seen today at 9", "Loading…", "• 12", ""] {
            XCTAssertTrue(StepVerifier.isVolatile(s), s)
        }
        for s in ["Ana Lopez", "Invoice 2024-11", "Send", "Q3 report.pdf"] {
            XCTAssertFalse(StepVerifier.isVolatile(s), s)
        }
    }

    func testWindowTitleAndAppSwitch() {
        let before = ScreenState(bundleID: "com.finder", windowTitle: "Downloads")
        let after = ScreenState(bundleID: "com.preview", windowTitle: "Report.pdf")
        let e = StepExpectation.derive(before: before, after: after)
        XCTAssertEqual(e.windowTitle, "Report.pdf")
        XCTAssertEqual(e.bundleID, "com.preview")

        XCTAssertEqual(StepVerifier.check(e, before: before, after: after).verdict, .passed)
        let wrong = ScreenState(bundleID: "com.preview", windowTitle: "Other.pdf")
        XCTAssertNotEqual(StepVerifier.check(e, before: before, after: wrong).verdict, .passed)
    }

    func testUnreadCountInTitleIsNotATitleChange() {
        let e = StepExpectation.derive(before: ScreenState(windowTitle: "Inbox (3)"),
                                       after: ScreenState(windowTitle: "Inbox (2)"))
        XCTAssertNil(e.windowTitle)
    }

    func testDialogClosingExpectsItsTextToGo() {
        let before = ScreenState(texts: [SeenText("Delete “notes.txt”?"), SeenText("Cancel"), SeenText("Delete"), SeenText("Files")])
        let after = ScreenState(texts: [SeenText("Files")])
        let e = StepExpectation.derive(before: before, after: after)
        XCTAssertEqual(e.vanished.count, StepExpectation.maxVanished)
        XCTAssertEqual(StepVerifier.check(e, before: before, after: after).verdict, .passed)
        XCTAssertEqual(StepVerifier.check(e, before: before, after: before).verdict, .failed)
    }

    func testThumbnailCatchesChangesWithNoText() {
        // A canvas app: no text at all, only pixels.
        let a = GrayImage(width: 8, height: 8, fill: 200)
        var b = a
        for i in 0..<16 { b.pixels[i] = 0 }
        let e = StepExpectation.derive(before: ScreenState(thumbnail: a), after: ScreenState(thumbnail: b))
        XCTAssertTrue(e.changed)
        XCTAssertFalse(e.hasChecks)
        XCTAssertEqual(StepVerifier.check(e, before: ScreenState(thumbnail: a), after: ScreenState(thumbnail: b)).verdict, .passed)
        XCTAssertTrue(StepVerifier.check(e, before: ScreenState(thumbnail: a), after: ScreenState(thumbnail: a)).nothingHappened)
    }

    func testNoChangeRecordedMeansNothingToCheck() {
        let s = ScreenState(texts: [SeenText("Same")])
        let e = StepExpectation.derive(before: s, after: s)
        XCTAssertFalse(e.changed)
        XCTAssertNil(e.summary)
        XCTAssertEqual(StepVerifier.check(e, before: s, after: s).verdict, .skipped)
    }

    func testHeaderFoundWhereItWasAfterAResize() {
        let e = StepExpectation(appeared: [ExpectedText("Ana Lopez", frame: CGRect(x: 400, y: 20, width: 120, height: 18))],
                                changed: true, windowSize: CGSize(width: 900, height: 600))
        // Window is now twice as wide, and the header was already showing.
        let wide = ScreenState(windowSize: CGSize(width: 1800, height: 600),
                               texts: [SeenText("Ana Lopez", frame: CGRect(x: 860, y: 20, width: 120, height: 18))])
        XCTAssertEqual(StepVerifier.presence(of: e.appeared[0], before: wide, after: wide,
                                             recordedWindow: e.windowSize), 1)
        let elsewhere = ScreenState(windowSize: CGSize(width: 1800, height: 600),
                                    texts: [SeenText("Ana Lopez", frame: CGRect(x: 20, y: 400, width: 120, height: 18))])
        XCTAssertEqual(StepVerifier.presence(of: e.appeared[0], before: elsewhere, after: elsewhere,
                                             recordedWindow: e.windowSize), 0.25)
    }

    func testSentMessageIsSkippedWhenTypingChangesEachRun() {
        let before = ScreenState(texts: [SeenText("Ana Lopez")])
        let after = ScreenState(texts: [SeenText("Ana Lopez"), SeenText("See you at 6, Ana"), SeenText("Delivered to Ana")])
        let e = StepExpectation.derive(before: before, after: after, typed: ["see you at 6"])
        XCTAssertEqual(e.appeared.first { $0.text == "See you at 6, Ana" }?.typed, true)
        XCTAssertNil(e.appeared.first { $0.text == "Delivered to Ana" }?.typed)
        XCTAssertEqual(e.withoutTyped().appeared.map(\.text), ["Delivered to Ana"])
    }

    func testOCRMergeAddsOnlyNewText() {
        var s = ScreenState(texts: [SeenText("Send")])
        s.merge(ocr: [OCRLine(text: "send", frame: .zero), OCRLine(text: "Ana Lopez", frame: .zero),
                      OCRLine(text: "Ana Lopez", frame: CGRect(x: 400, y: 20, width: 80, height: 16))])
        XCTAssertEqual(s.texts.map(\.text), ["Send", "Ana Lopez", "Ana Lopez"])
        XCTAssertTrue(s.usedOCR)
    }
}

final class StepCheckLoopTests: XCTestCase {
    private func result(_ v: StepCheckResult.Verdict, nothing: Bool = false) -> StepCheckResult {
        StepCheckResult(verdict: v, score: v == .passed ? 1 : 0, missing: [], nothingHappened: nothing, summary: "why")
    }

    func testPassProceeds() {
        var loop = StepCheckLoop(policy: .retryThenStop, canRedo: true)
        XCTAssertEqual(loop.next(result(.passed)), .proceed(note: nil))
    }

    func testStepThatDidNothingIsWaitedOnThenRepeatedOnceThenStops() {
        var loop = StepCheckLoop(policy: .retryThenStop, canRedo: true)
        let failed = result(.failed, nothing: true)
        XCTAssertEqual(loop.next(failed), .recheck(after: 0.4))
        XCTAssertEqual(loop.next(failed), .recheck(after: 0.8))
        XCTAssertEqual(loop.next(failed), .recheck(after: 1.2))
        XCTAssertEqual(loop.next(failed), .redo)
        XCTAssertEqual(loop.next(failed), .recheck(after: 0.4))
        XCTAssertEqual(loop.next(failed), .recheck(after: 0.8))
        XCTAssertEqual(loop.next(failed), .recheck(after: 1.2))
        XCTAssertEqual(loop.next(failed), .stop("why, even after trying again"))
    }

    func testSecondTryThatWorksSaysSo() {
        var loop = StepCheckLoop(policy: .retryThenStop, canRedo: true)
        loop.maxRechecks = 0
        XCTAssertEqual(loop.next(result(.failed, nothing: true)), .redo)
        XCTAssertEqual(loop.next(result(.passed)), .proceed(note: "Worked on the second try"))
    }

    func testDifferentChangeIsNeverRepeated() {
        // Something happened, just not what was expected. Clicking again
        // could toggle something back or send twice, so stop instead.
        var loop = StepCheckLoop(policy: .retryThenStop, canRedo: true)
        loop.maxRechecks = 1
        XCTAssertEqual(loop.next(result(.failed)), .recheck(after: 0.4))
        XCTAssertEqual(loop.next(result(.failed)), .stop("why"))
    }

    func testStepsThatCannotBeRepeatedStop() {
        var loop = StepCheckLoop(policy: .retryThenStop, canRedo: false)
        loop.maxRechecks = 0
        XCTAssertEqual(loop.next(result(.failed, nothing: true)), .stop("why"))
    }

    func testStopPolicyNeverRepeats() {
        var loop = StepCheckLoop(policy: .stop, canRedo: true)
        loop.maxRechecks = 0
        XCTAssertEqual(loop.next(result(.failed, nothing: true)), .stop("why"))
    }

    func testKeepGoingNotesAndCarriesOn() {
        var loop = StepCheckLoop(policy: .keepGoing, canRedo: true)
        loop.maxRechecks = 0
        XCTAssertEqual(loop.next(result(.failed)), .proceed(note: "why"))
    }

    func testPartialMatchWaitsThenCarriesOnWithANote() {
        var loop = StepCheckLoop(policy: .stop, canRedo: true)
        loop.maxRechecks = 1
        XCTAssertEqual(loop.next(result(.uncertain)), .recheck(after: 0.4))
        XCTAssertEqual(loop.next(result(.uncertain)), .proceed(note: "why"))
    }
}

final class StepCheckStorageTests: XCTestCase {
    private func automation() -> Automation {
        let target = ElementLocator(bundleID: "com.chat", appName: "Chat", windowTitle: nil, role: "AXPosition", subrole: nil,
                                    title: nil, desc: nil, identifier: nil, help: nil, value: nil, label: nil, path: [],
                                    frameInWindow: CGRect(x: 40, y: 76, width: 8, height: 8),
                                    clickOffset: CGPoint(x: 0.5, y: 0.5), inMenu: false,
                                    visual: VisualTarget(crop: GrayImage(width: 4, height: 4, fill: 9), cropOrigin: .zero,
                                                         click: CGPoint(x: 44, y: 80),
                                                         clickedText: OCRLine(text: "Ana Lopez", frame: CGRect(x: 20, y: 72, width: 80, height: 16)),
                                                         nearby: [], windowSize: CGSize(width: 900, height: 600)))
        let expect = StepExpectation(appeared: [ExpectedText("Ana Lopez", frame: CGRect(x: 400, y: 20, width: 80, height: 16))],
                                     changed: true, usedOCR: true)
        return Automation(name: "Message Ana", steps: [
            Step(kind: .click(target: target, button: .left, count: 1, modifiers: 0), expect: expect, onMismatch: .stop)
        ])
    }

    func testExpectationsAndPicturesSurviveExportAndImport() throws {
        let a = automation()
        let back = try TaskFile.decode(TaskFile.encode(a))
        XCTAssertNotEqual(back.steps[0].id, a.steps[0].id, "imported steps still get fresh IDs")
        XCTAssertEqual(back.steps[0].expect, a.steps[0].expect)
        XCTAssertEqual(back.steps[0].onMismatch, .stop)
        XCTAssertEqual(back.steps[0].kind, a.steps[0].kind)
    }

    func testPositionClickNamesTheTextItLandedOn() {
        XCTAssertEqual(automation().steps[0].summary, "Click “Ana Lopez” on screen")
    }

    func testStepsSavedBeforeCheckingExistedStillLoad() throws {
        let json = #"{"id":"6F1B0E58-3C5B-4A5E-9F0B-2D7C1C7E8A11","kind":{"wait":{"seconds":1}}}"#
        let step = try JSONDecoder().decode(Step.self, from: Data(json.utf8))
        XCTAssertNil(step.expect)
        XCTAssertNil(step.onMismatch)
        XCTAssertEqual(step.kind, .wait(seconds: 1))
    }
}

final class PixelChangeTests: XCTestCase {
    func testOneDigitChangingCounts() {
        // A 128 × 80 thumbnail where only a 5 × 6 patch changed, like one digit.
        let before = GrayImage(width: 128, height: 80, fill: 230)
        var after = before
        for y in 10..<16 { for x in 100..<105 { after[x, y] = 20 } }
        XCTAssertLessThan(before.difference(from: after), 0.003, "the average barely moves")
        XCTAssertGreaterThan(before.changedFraction(from: after), StepVerifier.pixelChange)
        let a = ScreenState(thumbnail: before), b = ScreenState(thumbnail: after)
        XCTAssertTrue(StepExpectation.derive(before: a, after: b).changed)
        XCTAssertFalse(StepVerifier.unchanged(a, b))
    }

    func testFaintNoiseDoesNot() {
        let before = GrayImage(width: 128, height: 80, fill: 230)
        var after = before
        for i in stride(from: 0, to: after.pixels.count, by: 3) { after.pixels[i] = 238 }
        XCTAssertEqual(before.changedFraction(from: after), 0)
    }
}
