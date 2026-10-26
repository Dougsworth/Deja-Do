import XCTest
@testable import DejaDoCore

final class ScheduleTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Jamaica")!
        return c
    }()

    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // Monday 26 October 2026.
    func testWeekdaysSkipTheWeekend() {
        let s = Schedule(repeats: .weekdays, hour: 9, minute: 0)
        XCTAssertEqual(s.next(after: date(2026, 10, 26, 8), calendar: cal), date(2026, 10, 26, 9))
        XCTAssertEqual(s.next(after: date(2026, 10, 26, 9), calendar: cal), date(2026, 10, 27, 9))
        XCTAssertEqual(s.next(after: date(2026, 10, 30, 10), calendar: cal), date(2026, 11, 2, 9), "Friday after 9 goes to Monday")
        XCTAssertTrue(s.slots(onDayOf: date(2026, 10, 31, 12), calendar: cal).isEmpty, "Saturday")
    }

    func testDailyIncludesWeekends() {
        let s = Schedule(repeats: .daily, hour: 7, minute: 30)
        XCTAssertEqual(s.next(after: date(2026, 10, 30, 10), calendar: cal), date(2026, 10, 31, 7, 30))
    }

    func testHourlyWithinHours() {
        let s = Schedule(repeats: .hourly, hour: 9, minute: 15, everyHours: 3, untilHour: 18)
        XCTAssertEqual(s.slots(onDayOf: date(2026, 10, 26, 0), calendar: cal),
                       [date(2026, 10, 26, 9, 15), date(2026, 10, 26, 12, 15), date(2026, 10, 26, 15, 15), date(2026, 10, 26, 18, 15)])
        XCTAssertEqual(s.next(after: date(2026, 10, 26, 18, 20), calendar: cal), date(2026, 10, 27, 9, 15))
    }

    func testOffNeverRuns() {
        let s = Schedule(on: false)
        XCTAssertNil(s.next(after: Date(), calendar: cal))
        XCTAssertEqual(s.due(at: date(2026, 10, 26, 9, 5), calendar: cal, since: date(2026, 10, 1, 0)), .none)
    }

    func testDueRightOnTimeAndAfterwardsNotAgain() {
        var s = Schedule(repeats: .weekdays, hour: 9)
        let created = date(2026, 10, 25, 20)
        XCTAssertEqual(s.due(at: date(2026, 10, 26, 8, 59), calendar: cal, since: created), .none)
        XCTAssertEqual(s.due(at: date(2026, 10, 26, 9, 0), calendar: cal, since: created), .run(date(2026, 10, 26, 9)))
        s.lastSlot = date(2026, 10, 26, 9)
        XCTAssertEqual(s.due(at: date(2026, 10, 26, 9, 1), calendar: cal, since: created), .none, "once per slot")
    }

    func testLateWithinAnHourStillRuns() {
        let s = Schedule(repeats: .weekdays, hour: 9)
        XCTAssertEqual(s.due(at: date(2026, 10, 26, 9, 50), calendar: cal, since: date(2026, 10, 25, 0)), .run(date(2026, 10, 26, 9)))
    }

    func testAsleepAllMorningIsMissedNotRunLate() {
        let s = Schedule(repeats: .weekdays, hour: 9)
        XCTAssertEqual(s.due(at: date(2026, 10, 26, 13), calendar: cal, since: date(2026, 10, 25, 0)), .missed([date(2026, 10, 26, 9)]))
    }

    func testAsleepForDaysRunsOnlyOnce() {
        // Every two hours from 8 to 18; asleep from Monday night to Wednesday 10:30.
        var s = Schedule(repeats: .hourly, hour: 8, minute: 0, everyHours: 2, untilHour: 18)
        s.lastSlot = date(2026, 10, 26, 18)
        guard case .run(let t) = s.due(at: date(2026, 10, 28, 10, 30), calendar: cal, since: date(2026, 10, 1, 0)) else {
            return XCTFail("the 10:00 slot is within the hour and should run")
        }
        XCTAssertEqual(t, date(2026, 10, 28, 10))
    }

    func testSummary() {
        XCTAssertEqual(Schedule(repeats: .weekdays, hour: 9, minute: 5).summary(calendar: cal), "Weekdays at 9:05")
        XCTAssertEqual(Schedule(repeats: .hourly, hour: 8, minute: 0, everyHours: 1, untilHour: 17).summary(calendar: cal), "Every hour from 8:00 to 17:00")
    }

    func testTasksThatCantRunAlone() {
        let ask = Automation(name: "a", steps: [Step(kind: .type(text: "", askEachRun: true, secret: false, prompt: ""))])
        XCTAssertNotNil(Schedule.problem(for: ask, values: [:]))
        let vars = Automation(name: "b", steps: [Step(kind: .type(text: "Hi {{name}}", askEachRun: false, secret: false, prompt: ""))])
        XCTAssertEqual(Schedule.problem(for: vars, values: [:]), "Fill in {{name}} first.")
        XCTAssertNil(Schedule.problem(for: vars, values: ["Name": "Ana"]))
    }

    func testOldFilesWithoutAScheduleStillLoad() throws {
        let a = Automation(name: "x", steps: [])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as! [String: Any]
        json.removeValue(forKey: "schedule")
        let back = try JSONDecoder().decode(Automation.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(back.schedule)
    }
}

final class ReadStepTests: XCTestCase {
    func locator() -> ElementLocator {
        ElementLocator(bundleID: "com.apple.calculator", appName: "Calculator", windowTitle: nil, role: "AXStaticText",
                       subrole: nil, title: nil, desc: nil, identifier: nil, help: nil, value: nil, label: nil, path: [],
                       frameInWindow: CGRect(x: 10, y: 10, width: 200, height: 40), clickOffset: CGPoint(x: 0.5, y: 0.5),
                       inMenu: false, anchors: [Anchor(label: "Total:", role: "AXStaticText", offset: CGPoint(x: -80, y: 0))])
    }

    func testReadNamesAreNotInputs() {
        let a = Automation(name: "t", steps: [
            Step(kind: .read(target: locator(), name: "total")),
            Step(kind: .type(text: "Total is {{Total}} for {{client}}", askEachRun: false, secret: false, prompt: ""))
        ])
        XCTAssertEqual(a.variableNames, ["client"])
        XCTAssertEqual(a.readNames, ["total"])
    }

    func testAVariableTypedBeforeItsReadIsStillAnInput() {
        let a = Automation(name: "t", steps: [
            Step(kind: .type(text: "{{total}}", askEachRun: false, secret: false, prompt: "")),
            Step(kind: .read(target: locator(), name: "total"))
        ])
        XCTAssertEqual(a.variableNames, ["total"])
    }

    func testSummaryAndRoundTrip() throws {
        let step = Step(kind: .read(target: locator(), name: "total"))
        XCTAssertEqual(step.summary, "Read the text near “Total:” into {{total}}")
        let back = try JSONDecoder().decode(Step.self, from: JSONEncoder().encode(step))
        XCTAssertEqual(back, step)
    }

    func testSuggestedNames() {
        XCTAssertEqual(Variables.suggestName(near: "Total:", taken: []), "total")
        XCTAssertEqual(Variables.suggestName(near: "Order number", taken: ["order number"]), "order number 2")
        XCTAssertEqual(Variables.suggestName(near: nil, taken: ["value"]), "value 2")
        XCTAssertEqual(Variables.suggestName(near: "12", taken: []), "value")
        XCTAssertEqual(Variables.suggestName(near: "Amount due (JMD)", taken: []), "amount due jmd")
    }
}
