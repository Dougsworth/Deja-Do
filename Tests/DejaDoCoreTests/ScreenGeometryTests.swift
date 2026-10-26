import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import DejaDoCore

final class ScreenGeometryTests: XCTestCase {
    // A laptop at the origin and a taller external display to its left, top aligned.
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let left = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
    // An external display above the laptop.
    let above = CGRect(x: -200, y: -1080, width: 1920, height: 1080)

    func testWindowOnOneDisplay() {
        let w = CGRect(x: -2000, y: 300, width: 800, height: 600)
        XCTAssertEqual(ScreenGeometry.mainDisplay(for: w, on: [laptop, left]), 1)
        XCTAssertEqual(ScreenGeometry.pieces(of: w, on: [laptop, left]), [.init(display: 1, rect: w)])
    }

    func testWindowAcrossTwoDisplaysGetsBothHalves() {
        let w = CGRect(x: -300, y: 100, width: 1000, height: 500)
        let parts = ScreenGeometry.pieces(of: w, on: [laptop, left])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].display, 0, "more of it is on the laptop")
        XCTAssertEqual(parts[0].rect, CGRect(x: 0, y: 100, width: 700, height: 500))
        XCTAssertEqual(parts[1].rect, CGRect(x: -300, y: 100, width: 300, height: 500))
        XCTAssertEqual(ScreenGeometry.visible(w, on: [laptop, left]), w)
    }

    func testCentreInTheGapStillFindsTheDisplays() {
        // The left display is taller. A window low down on the laptop with its
        // centre below the laptop's bottom edge and right of the left display,
        // where there is no display at all.
        let w = CGRect(x: -100, y: 800, width: 900, height: 600)
        let centre = CGPoint(x: w.midX, y: w.midY)
        XCTAssertFalse(laptop.contains(centre))
        XCTAssertFalse(left.contains(centre))
        let parts = ScreenGeometry.pieces(of: w, on: [laptop, left])
        XCTAssertEqual(parts.map(\.display), [0, 1], "800×182 on the laptop beats 100×600 on the left display")
    }

    func testDisplayAboveHasNegativeY() {
        let w = CGRect(x: 100, y: -700, width: 600, height: 400)
        XCTAssertEqual(ScreenGeometry.mainDisplay(for: w, on: [laptop, above]), 1)
        let corner = CGRect(x: 100, y: -300, width: 600, height: 400)
        let parts = ScreenGeometry.pieces(of: corner, on: [laptop, above])
        XCTAssertEqual(parts.map(\.display), [1, 0])
        XCTAssertEqual(parts[1].rect, CGRect(x: 100, y: 0, width: 600, height: 100))
    }

    func testOffEveryDisplay() {
        let w = CGRect(x: 5000, y: 5000, width: 100, height: 100)
        XCTAssertNil(ScreenGeometry.mainDisplay(for: w, on: [laptop, left]))
        XCTAssertNil(ScreenGeometry.visible(w, on: [laptop, left]))
        XCTAssertTrue(ScreenGeometry.pieces(of: CGRect(x: 1512, y: 0, width: 0, height: 10), on: [laptop]).isEmpty)
    }

    func testFlipIsItsOwnInverse() {
        let p = CGPoint(x: -1000, y: 1200)
        XCTAssertEqual(ScreenGeometry.flip(p, mainDisplayHeight: 982), CGPoint(x: -1000, y: -218))
        XCTAssertEqual(ScreenGeometry.flip(ScreenGeometry.flip(p, mainDisplayHeight: 982), mainDisplayHeight: 982), p)
    }
}
