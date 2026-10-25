import XCTest
import CoreGraphics
@testable import DejaDoCore

final class VariablesTests: XCTestCase {
    func testFindsNamesInOrderWithoutRepeats() {
        XCTAssertEqual(Variables.names(in: "Hi {{ Name }}, your total is {{amount}}. Thanks {{name}}!"), ["Name", "amount"])
        XCTAssertEqual(Variables.names(in: "no placeholders"), [])
    }

    func testFillsIgnoringCaseAndSpaces() {
        let out = Variables.fill("Dear {{First  Name}}, you owe {{amount}}.", with: ["first name": "Kris", "Amount": "$40"])
        XCTAssertEqual(out, "Dear Kris, you owe $40.")
    }

    func testUnknownNamesBecomeEmpty() {
        XCTAssertEqual(Variables.fill("a{{x}}b", with: [:]), "ab")
    }

    func testTextWithoutPlaceholdersIsUntouched() {
        XCTAssertEqual(Variables.fill("plain {text}", with: ["text": "x"]), "plain {text}")
    }

    func testAutomationListsItsVariablesButSkipsSecretsAndAskSteps() {
        let a = Automation(name: "T", steps: [
            Step(kind: .type(text: "Hi {{name}}", askEachRun: false, secret: false, prompt: "")),
            Step(kind: .type(text: "{{ignored}}", askEachRun: true, secret: false, prompt: "")),
            Step(kind: .type(text: "", askEachRun: true, secret: true, prompt: "")),
            Step(kind: .type(text: "{{Amount}} for {{NAME}}", askEachRun: false, secret: false, prompt: ""))
        ])
        XCTAssertEqual(a.variableNames, ["name", "Amount"])
    }

    func testMissingColumns() {
        XCTAssertEqual(Variables.missing(["Name", "amount", "date"], in: ["name", "Amount "]), ["date"])
    }
}

final class CSVTests: XCTestCase {
    func testQuotedCellsWithCommasQuotesAndNewlines() {
        let text = "name,note\r\n\"Smith, Jo\",\"said \"\"hi\"\"\nthen left\"\r\nKris,ok\r\n"
        XCTAssertEqual(CSV.parse(text), [["name", "note"], ["Smith, Jo", "said \"hi\"\nthen left"], ["Kris", "ok"]])
    }

    func testRecordsUseTheHeaderRowAndTolerateShortRows() {
        let (headers, rows) = CSV.records("\u{FEFF}Name,Amount\nKris,40\nJo\n")
        XCTAssertEqual(headers, ["Name", "Amount"])
        XCTAssertEqual(rows, [["Name": "Kris", "Amount": "40"], ["Name": "Jo", "Amount": ""]])
    }

    func testTabAndSemicolonFiles() {
        XCTAssertEqual(CSV.parse("a\tb\n1\t2"), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(CSV.parse("a;b\n1;2"), [["a", "b"], ["1", "2"]])
    }

    func testBlankLinesAreSkipped() {
        XCTAssertEqual(CSV.parse("a,b\n\n1,2\n\n").count, 2)
    }
}

final class TaskFileTests: XCTestCase {
    private func sample() -> Automation {
        Automation(name: "Send report", steps: [
            Step(kind: .activate(bundleID: "com.apple.mail", name: "Mail")),
            Step(kind: .type(text: "Hi {{name}}", askEachRun: false, secret: false, prompt: "")),
            Step(kind: .type(text: "typed last time", askEachRun: true, secret: false, prompt: "")),
            Step(kind: .type(text: "hunter2", askEachRun: true, secret: true, prompt: "Password"))
        ], runs: 9, repairs: 2, lastSucceeded: true, lastDuration: 4.2)
    }

    func testExportStripsHistoryAndPrivateText() throws {
        let data = try TaskFile.encode(sample())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("dejado-task"))
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertFalse(text.contains("typed last time"))
        XCTAssertTrue(text.contains("Hi {{name}}"))
    }

    func testImportGivesFreshIDsAndKeepsSteps() throws {
        let original = sample()
        let imported = try TaskFile.decode(try TaskFile.encode(original))
        XCTAssertNotEqual(imported.id, original.id)
        XCTAssertEqual(imported.name, "Send report")
        XCTAssertEqual(imported.steps.count, 4)
        XCTAssertTrue(Set(imported.steps.map(\.id)).isDisjoint(with: original.steps.map(\.id)))
        XCTAssertEqual(imported.runs, 0)
        XCTAssertNil(imported.lastSucceeded)
        XCTAssertEqual(imported.variableNames, ["name"])
    }

    func testRejectsOtherFiles() {
        XCTAssertThrowsError(try TaskFile.decode(Data("{\"hello\": 1}".utf8))) { error in
            XCTAssertEqual(error as? TaskFile.Failure, .notATask)
        }
    }

    func testRejectsNewerFormats() throws {
        var json = String(decoding: try TaskFile.encode(sample()), as: UTF8.self)
        json = json.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 99")
        XCTAssertThrowsError(try TaskFile.decode(Data(json.utf8))) { error in
            XCTAssertEqual(error as? TaskFile.Failure, .newerVersion(99))
        }
    }
}
