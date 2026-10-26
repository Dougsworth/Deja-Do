import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import DejaDoCore

/// Draws fake windows: a flat background with "icons", which are patches of
/// seeded noise. Every seed looks different, like real icons do, and the same
/// seed always draws the same icon.
struct Canvas {
    var image: GrayImage

    init(width: Int, height: Int, background: UInt8 = 236, scale: Double = 1) {
        image = GrayImage(width: width, height: height, fill: background, scale: scale)
    }

    /// An icon whose centre sits at (x, y) points. `cell` is the size of each
    /// block of the pattern; real icons and text have strokes a few points wide.
    mutating func icon(seed: UInt64, at x: Int, _ y: Int, size: Int = 24, cell: Int = 1) {
        var rng = seed &* 6364136223846793005 &+ 1442695040888963407
        let s = image.scale
        let side = Int(Double(size) * s)
        let left = Int(Double(x) * s) - side / 2, top = Int(Double(y) * s) - side / 2
        // Draw at one pixel per point, then scale, so a Retina canvas holds the same icon.
        var cells = [UInt8]()
        for _ in 0..<(size * size) {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            cells.append(UInt8(truncatingIfNeeded: (rng >> 33) % 200))
        }
        for py in 0..<side {
            for px in 0..<side {
                let cx = min(size - 1, Int(Double(px) / s) / cell * cell)
                let cy = min(size - 1, Int(Double(py) / s) / cell * cell)
                let ix = left + px, iy = top + py
                guard ix >= 0, iy >= 0, ix < image.width, iy < image.height else { continue }
                image[ix, iy] = cells[cy * size + cx]
            }
        }
    }
}

final class GrayImageTests: XCTestCase {
    func testCropIsClippedToTheImage() {
        let img = GrayImage(width: 10, height: 8, fill: 9)
        let c = img.cropped(x: -3, y: 6, width: 6, height: 6)
        XCTAssertEqual(c.width, 3)
        XCTAssertEqual(c.height, 2)
        XCTAssertTrue(img.cropped(x: 20, y: 20, width: 4, height: 4).isEmpty)
    }

    func testShrinkingAveragesPixels() {
        let img = GrayImage(width: 2, height: 2, pixels: [0, 100, 200, 100])
        let small = img.resized(width: 1, height: 1)
        XCTAssertEqual(small.pixels, [100])
        XCTAssertEqual(small.scale, 0.5, accuracy: 1e-9)
    }

    func testSurvivesJSON() throws {
        var c = Canvas(width: 30, height: 20, scale: 2)
        c.icon(seed: 7, at: 7, 5, size: 6)
        let data = try JSONEncoder().encode(c.image)
        let back = try JSONDecoder().decode(GrayImage.self, from: data)
        XCTAssertEqual(back, c.image)
    }

    func testRejectsDataOfTheWrongSize() {
        let json = #"{"width":4,"height":4,"scale":1,"data":"AAAA"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(GrayImage.self, from: Data(json.utf8)))
    }

    func testDifference() {
        let black = GrayImage(width: 4, height: 4, fill: 0)
        let white = GrayImage(width: 8, height: 8, fill: 255)
        XCTAssertEqual(black.difference(from: black), 0)
        XCTAssertEqual(black.difference(from: white), 1, accuracy: 1e-9)
    }
}

final class TemplateSearchTests: XCTestCase {
    func testFindsAPatchWhereItIs() {
        var c = Canvas(width: 300, height: 200)
        c.icon(seed: 1, at: 60, 50)
        c.icon(seed: 2, at: 210, 140)
        c.icon(seed: 3, at: 120, 160)
        let template = c.image.cropped(x: 210 - 16, y: 140 - 16, width: 32, height: 32)
        let peaks = TemplateSearch.search(template: template, in: c.image)
        XCTAssertEqual(peaks.first?.x, 194)
        XCTAssertEqual(peaks.first?.y, 124)
        XCTAssertEqual(peaks.first?.score ?? 0, 1, accuracy: 0.001)
    }

    func testIgnoresBrightnessAndContrastChanges() {
        var c = Canvas(width: 200, height: 150)
        c.icon(seed: 11, at: 140, 90)
        let template = c.image.cropped(x: 124, y: 74, width: 32, height: 32)
        // Dark mode tint: every pixel dimmed and lifted.
        let tinted = GrayImage(width: c.image.width, height: c.image.height,
                               pixels: c.image.pixels.map { UInt8(Double($0) * 0.6 + 30) })
        let best = TemplateSearch.search(template: template, in: tinted).first
        XCTAssertEqual(best?.x ?? 0, 124, accuracy: 1)
        XCTAssertEqual(best?.y ?? 0, 74, accuracy: 1)
        XCTAssertGreaterThan(best?.score ?? 0, 0.95)
    }

    func testFlatTemplateFindsNothing() {
        let c = Canvas(width: 120, height: 120)
        let flat = c.image.cropped(x: 10, y: 10, width: 30, height: 30)
        XCTAssertTrue(TemplateSearch.search(template: flat, in: c.image).isEmpty)
    }

    func testFindsASlightlyLargerCopy() {
        var small = Canvas(width: 200, height: 160)
        small.icon(seed: 21, at: 50, 50, size: 30)
        let template = small.image.cropped(x: 30, y: 30, width: 40, height: 40)

        // Same icon drawn 10% larger elsewhere.
        var big = Canvas(width: 260, height: 200)
        let scaled = template.resized(width: 44, height: 44)
        for y in 0..<44 { for x in 0..<44 { big.image[150 + x, 100 + y] = scaled[x, y] } }
        let best = TemplateSearch.search(template: template, in: big.image).first
        XCTAssertEqual(best?.scale, 1.1)
        XCTAssertEqual(best?.x ?? 0, 150, accuracy: 2)
        XCTAssertEqual(best?.y ?? 0, 100, accuracy: 2)
    }
}

final class VisualMatcherTests: XCTestCase {
    private let size = CGSize(width: 480, height: 320)

    private func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 90) -> OCRLine {
        OCRLine(text: text, frame: CGRect(x: x, y: y - 8, width: width, height: 16))
    }

    private func assertConfident(_ r: VisualReport, near p: CGPoint, within d: CGFloat = 3,
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard case .confident(let best) = r.decision else {
            return XCTFail("expected confident, got \(r.decision)", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(hypot(best.point.x - p.x, best.point.y - p.y), d,
                                 "found \(best.point), wanted \(p)", file: file, line: line)
    }

    func testCanvasIconFoundAfterItMoves() {
        // A drawing app with no accessibility and no text: only pixels.
        var before = Canvas(width: 480, height: 320)
        before.icon(seed: 5, at: 100, 80)
        before.icon(seed: 6, at: 300, 200)
        before.icon(seed: 7, at: 380, 60)
        let target = VisualTarget.make(window: before.image, lines: [], click: CGPoint(x: 100, y: 80), windowSize: size)

        var after = Canvas(width: 480, height: 320)
        after.icon(seed: 6, at: 100, 80)   // a different icon now sits in the old spot
        after.icon(seed: 5, at: 220, 120)
        after.icon(seed: 7, at: 380, 260)
        let r = VisualMatcher().match(target, window: after.image, lines: [], windowSize: size)
        assertConfident(r, near: CGPoint(x: 220, y: 120))
    }

    func testLabelFoundAgainAfterTheListReorders() {
        // A custom drawn chat list: text only, nothing distinctive in the pixels.
        let flat = Canvas(width: 480, height: 320).image
        let lines = [line("Chats", x: 20, y: 30), line("Ana Lopez", x: 20, y: 100), line("Ben Carter", x: 20, y: 140)]
        let target = VisualTarget.make(window: flat, lines: lines, click: CGPoint(x: 45, y: 100), windowSize: size)
        XCTAssertEqual(target.clickedText?.text, "Ana Lopez")

        let now = [line("Chats", x: 20, y: 30), line("Ben Carter", x: 20, y: 100), line("Ana Lopez", x: 20, y: 140)]
        let r = VisualMatcher().match(target, window: flat, lines: now, windowSize: size)
        assertConfident(r, near: CGPoint(x: 45, y: 140))
    }

    func testLabelOCRMissedDoesNotSinkAPerfectPicture() {
        // A one character label like "7" often isn't read back by OCR. The picture still decides.
        var c = Canvas(width: 480, height: 320)
        c.icon(seed: 61, at: 120, 120)
        c.icon(seed: 62, at: 300, 200)
        let target = VisualTarget.make(window: c.image, lines: [line("7", x: 110, y: 120, width: 20)],
                                       click: CGPoint(x: 120, y: 120), windowSize: size)
        let r = VisualMatcher().match(target, window: c.image, lines: [line("Clear", x: 300, y: 40)], windowSize: size)
        assertConfident(r, near: CGPoint(x: 120, y: 120))
    }

    func testTwoIdenticalLabelsAreNotGuessedBetween() {
        let flat = Canvas(width: 480, height: 320).image
        let target = VisualTarget.make(window: flat, lines: [line("Reply", x: 300, y: 100, width: 40)],
                                       click: CGPoint(x: 315, y: 100), windowSize: nil)
        let now = [line("Reply", x: 40, y: 60, width: 40), line("Reply", x: 40, y: 260, width: 40)]
        let r = VisualMatcher().match(target, window: flat, lines: now, windowSize: nil)
        if case .confident = r.decision { XCTFail("two equal Reply buttons far from the old spot must not be guessed") }
    }

    func testNearbyTextPicksTheRightCopy() {
        let flat = Canvas(width: 480, height: 320).image
        let recorded = [line("From Ana", x: 20, y: 60), line("Reply", x: 20, y: 90, width: 40),
                        line("From Ben", x: 20, y: 180), line("Reply", x: 20, y: 210, width: 40)]
        let target = VisualTarget.make(window: flat, lines: recorded, click: CGPoint(x: 35, y: 90), windowSize: size)

        // Ben's message moved to the top, Ana's below it.
        let now = [line("From Ben", x: 20, y: 60), line("Reply", x: 20, y: 90, width: 40),
                   line("From Ana", x: 20, y: 160), line("Reply", x: 20, y: 190, width: 40)]
        let r = VisualMatcher().match(target, window: flat, lines: now, windowSize: size)
        assertConfident(r, near: CGPoint(x: 35, y: 190))
    }

    func testDifferentLabelInTheSameSpotIsNotTrusted() {
        let flat = Canvas(width: 480, height: 320).image
        let target = VisualTarget.make(window: flat, lines: [line("Send", x: 380, y: 290, width: 50)],
                                       click: CGPoint(x: 400, y: 290), windowSize: size)
        let r = VisualMatcher().match(target, window: flat, lines: [line("Delete", x: 380, y: 290, width: 50)],
                                      windowSize: size)
        if case .confident = r.decision { XCTFail("Delete where Send used to be must not be clicked") }
    }

    func testRetinaRecordingMatchesNonRetinaScreen() {
        var retina = Canvas(width: 960, height: 640, scale: 2)
        retina.icon(seed: 31, at: 150, 100)
        retina.icon(seed: 32, at: 330, 220)
        let target = VisualTarget.make(window: retina.image, lines: [], click: CGPoint(x: 330, y: 220), windowSize: size)
        XCTAssertEqual(target.crop.scale, 1, "crops are stored at one pixel per point")
        XCTAssertEqual(target.crop.width, 64)

        var plain = Canvas(width: 480, height: 320)
        plain.icon(seed: 31, at: 150, 100)
        plain.icon(seed: 32, at: 260, 180)
        let r = VisualMatcher().match(target, window: plain.image, lines: [], windowSize: size)
        assertConfident(r, near: CGPoint(x: 260, y: 180))
    }

    func testIconAndLabelTogetherSurviveAWindowResize() {
        // A VM's toolbar: icon with a label under it, pinned to the right edge.
        var before = Canvas(width: 480, height: 320)
        before.icon(seed: 41, at: 420, 40)
        before.icon(seed: 42, at: 60, 40)
        let target = VisualTarget.make(window: before.image, lines: [line("Shared", x: 400, y: 64, width: 40)],
                                       click: CGPoint(x: 420, y: 40), windowSize: size)
        let wider = CGSize(width: 640, height: 320)
        var after = Canvas(width: 640, height: 320)
        after.icon(seed: 41, at: 580, 40)
        after.icon(seed: 42, at: 60, 40)
        let r = VisualMatcher().match(target, window: after.image, lines: [line("Shared", x: 560, y: 64, width: 40)],
                                      windowSize: wider)
        assertConfident(r, near: CGPoint(x: 580, y: 40))
    }

    func testSlightlySofterRenderingStillMatches() {
        // Scaling in a VM viewer or a different display softens edges a little.
        var before = Canvas(width: 480, height: 320)
        before.icon(seed: 51, at: 140, 90, cell: 3)
        before.icon(seed: 52, at: 300, 200, cell: 3)
        let target = VisualTarget.make(window: before.image, lines: [], click: CGPoint(x: 300, y: 200), windowSize: size)

        var after = Canvas(width: 480, height: 320)
        after.icon(seed: 51, at: 140, 90, cell: 3)
        after.icon(seed: 52, at: 320, 210, cell: 3)
        let img = after.image
        var soft = img
        for y in 1..<(img.height - 1) {
            for x in 1..<(img.width - 1) {
                var s = 0
                for dy in -1...1 { for dx in -1...1 { s += Int(img[x + dx, y + dy]) } }
                soft[x, y] = UInt8(s / 9)
            }
        }
        let r = VisualMatcher().match(target, window: soft, lines: [], windowSize: size)
        assertConfident(r, near: CGPoint(x: 320, y: 210))
    }

    func testLookalikeButtonsDifferingOnlyInTheMiddleAreNotConfused() {
        // Two round keys with the same face, told apart only by the symbol in the middle.
        func key(_ c: inout Canvas, at x: Int, _ y: Int, symbol: UInt64) {
            c.icon(seed: 99, at: x, y, size: 40)       // shared face
            c.icon(seed: symbol, at: x, y, size: 12)   // the symbol
        }
        var before = Canvas(width: 480, height: 320)
        key(&before, at: 100, 100, symbol: 1)   // "+"
        key(&before, at: 100, 160, symbol: 2)   // "−"
        let target = VisualTarget.make(window: before.image, lines: [], click: CGPoint(x: 100, y: 100), windowSize: size)

        // New layout: the keys moved and swapped order.
        var after = Canvas(width: 480, height: 320)
        key(&after, at: 300, 100, symbol: 2)
        key(&after, at: 300, 200, symbol: 1)
        let r = VisualMatcher().match(target, window: after.image, lines: [], windowSize: size)
        if case .confident(let best) = r.decision {
            XCTAssertLessThan(hypot(best.point.x - 300, best.point.y - 200), 4, "picked the lookalike at \(best.point)")
        }
    }

    func testMakeKeepsTheClosestDistinctLabels() {
        let flat = Canvas(width: 480, height: 320).image
        var lines = [line("Target", x: 100, y: 100)]
        for i in 0..<10 { lines.append(line("Label \(i)", x: 100, y: CGFloat(120 + i * 20))) }
        lines.append(line("Far away", x: 470, y: 310))
        lines.append(line("Label 0", x: 300, y: 300))   // duplicate text
        let t = VisualTarget.make(window: flat, lines: lines, click: CGPoint(x: 120, y: 100), windowSize: size)
        XCTAssertEqual(t.clickedText?.text, "Target")
        XCTAssertEqual(t.nearby.count, 6)
        XCTAssertEqual(t.nearby.first?.label, "Label 0")
        XCTAssertFalse(t.nearby.contains { $0.label == "Target" || $0.label == "Far away" })
        XCTAssertEqual(Set(t.nearby.map(\.label)).count, t.nearby.count)
    }

    func testCropNearTheEdgeIsClipped() {
        var c = Canvas(width: 200, height: 100)
        c.icon(seed: 3, at: 10, 10)
        let t = VisualTarget.make(window: c.image, lines: [], click: CGPoint(x: 5, y: 5), windowSize: nil)
        XCTAssertEqual(t.cropOrigin, .zero)
        XCTAssertEqual(t.crop.width, 37)
        XCTAssertEqual(t.clickInCrop, CGPoint(x: 5, y: 5))
    }
}

final class PrefersVisualTests: XCTestCase {
    private func locator(role: String, label: String?, frame: CGRect?, visual: Bool) -> ElementLocator {
        let v = visual ? VisualTarget(crop: GrayImage(width: 2, height: 2, fill: 1), cropOrigin: .zero,
                                      click: .zero, clickedText: nil, nearby: [], windowSize: nil) : nil
        return ElementLocator(bundleID: "b", appName: "A", windowTitle: nil, role: role, subrole: nil, title: label,
                              desc: nil, identifier: nil, help: nil, value: nil, label: label, path: [],
                              frameInWindow: frame, clickOffset: CGPoint(x: 0.5, y: 0.5), inMenu: false, visual: v)
    }

    func testPositionOnlyClicksUseTheScreen() {
        XCTAssertTrue(locator(role: "AXPosition", label: nil, frame: CGRect(x: 0, y: 0, width: 8, height: 8), visual: true).prefersVisual)
        XCTAssertFalse(locator(role: "AXPosition", label: nil, frame: nil, visual: false).prefersVisual)
    }

    func testOneBigUnlabelledElementUsesTheScreen() {
        // The guest display of a VM is one huge AXGroup.
        XCTAssertTrue(locator(role: "AXGroup", label: nil, frame: CGRect(x: 0, y: 30, width: 1024, height: 768), visual: true).prefersVisual)
        XCTAssertFalse(locator(role: "AXButton", label: nil, frame: CGRect(x: 0, y: 0, width: 24, height: 24), visual: true).prefersVisual)
        XCTAssertFalse(locator(role: "AXGroup", label: "Canvas", frame: CGRect(x: 0, y: 30, width: 1024, height: 768), visual: true).prefersVisual)
    }

    func testVisualSurvivesSavingAndOlderFilesStillLoad() throws {
        var c = Canvas(width: 100, height: 100)
        c.icon(seed: 1, at: 50, 50)
        var l = locator(role: "AXPosition", label: nil, frame: CGRect(x: 46, y: 46, width: 8, height: 8), visual: false)
        l.visual = VisualTarget.make(window: c.image, lines: [OCRLine(text: "Go", frame: CGRect(x: 40, y: 70, width: 20, height: 12))],
                                     click: CGPoint(x: 50, y: 50), windowSize: CGSize(width: 100, height: 100))
        let data = try JSONEncoder().encode(l)
        XCTAssertEqual(try JSONDecoder().decode(ElementLocator.self, from: data), l)

        var plain = l
        plain.visual = nil
        let old = try JSONEncoder().encode(plain)
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("visual"))
        XCTAssertNil(try JSONDecoder().decode(ElementLocator.self, from: old).visual)
    }
}
