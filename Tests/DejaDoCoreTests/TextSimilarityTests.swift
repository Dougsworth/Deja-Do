import XCTest
@testable import DejaDoCore

final class TextSimilarityTests: XCTestCase {
    func testNormalizeFoldsCaseAccentsAndPunctuation() {
        XCTAssertEqual(TextSimilarity.normalize("  Café — Save…  "), "cafe save")
        XCTAssertEqual(TextSimilarity.normalize("Export as PDF"), "export as pdf")
    }

    func testIdenticalAfterNormalizingScoresOne() {
        XCTAssertEqual(TextSimilarity.similarity("Save…", "save"), 1)
    }

    func testChangingCountersStillMatch() {
        let s = TextSimilarity.similarity("Inbox (3)", "Inbox (12)")
        XCTAssertEqual(s ?? 0, 0.93, accuracy: 0.001)
    }

    func testAddedWordsScoreHigh() {
        let s = TextSimilarity.similarity("Export", "Export as PDF") ?? 0
        XCTAssertGreaterThan(s, 0.75)
    }

    func testTypoFixScoresHigh() {
        let s = TextSimilarity.similarity("Recieve", "Receive") ?? 0
        XCTAssertGreaterThan(s, 0.7)
    }

    func testUnrelatedLabelsScoreLow() {
        XCTAssertLessThan(TextSimilarity.similarity("Send", "Cancel") ?? 1, 0.4)
        XCTAssertLessThan(TextSimilarity.similarity("Send", "Submit") ?? 1, 0.4)
    }

    func testMissingTextIsUnknownNotZero() {
        XCTAssertNil(TextSimilarity.similarity(nil, "Save"))
        XCTAssertNil(TextSimilarity.similarity("…", "Save"))
    }

    func testLevenshtein() {
        XCTAssertEqual(TextSimilarity.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(TextSimilarity.levenshtein("", "abc"), 3)
        XCTAssertEqual(TextSimilarity.levenshtein("same", "same"), 0)
    }

    func testGeneratedIdentifiersAreIgnored() {
        XCTAssertFalse(TextSimilarity.isStableIdentifier("_NS:123"))
        XCTAssertFalse(TextSimilarity.isStableIdentifier("cell-482913"))
        XCTAssertFalse(TextSimilarity.isStableIdentifier("3F2504E0-4F89-11D3-9A0C-0305E82C3301"))
        XCTAssertFalse(TextSimilarity.isStableIdentifier(nil))
        XCTAssertTrue(TextSimilarity.isStableIdentifier("saveButton"))
        XCTAssertTrue(TextSimilarity.isStableIdentifier("toolbar.export"))
        // Web ids made up at load time.
        XCTAssertFalse(TextSimilarity.isStableIdentifier("mui-12"))
        XCTAssertFalse(TextSimilarity.isStableIdentifier(":r3:"))
        XCTAssertFalse(TextSimilarity.isStableIdentifier("ember123"))
        XCTAssertFalse(TextSimilarity.isStableIdentifier("field-12"))
        XCTAssertFalse(TextSimilarity.isStableIdentifier("item_307"))
        XCTAssertTrue(TextSimilarity.isStableIdentifier("submit"))
        XCTAssertTrue(TextSimilarity.isStableIdentifier("email-field"))
        XCTAssertTrue(TextSimilarity.isStableIdentifier("step-2"), "a single digit is usually a real name")
    }

    func testSymbolLabelsAreTheirOwnText() {
        // Calculator style buttons: the symbol is the whole label.
        XCTAssertEqual(TextSimilarity.normalize("+"), "+")
        XCTAssertEqual(TextSimilarity.similarity("=", "="), 1)
        XCTAssertLessThan(TextSimilarity.similarity("+", "=") ?? 1, 0.5)
        XCTAssertEqual(TextSimilarity.normalize("Save…"), "save", "words still drop their punctuation")
        XCTAssertNil(TextSimilarity.similarity("  ", "+"), "blank is still no text")
    }
}
