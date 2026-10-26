import XCTest
@testable import DejaDoCore

final class ExplainTests: XCTestCase {
    func testPermission() {
        let e = Explainer.explain("Deja Do needs Accessibility permission to run automations. Nothing was sent or saved before it stopped, so it's safe to run again.")
        XCTAssertEqual(e.actions.first, .accessibilitySettings)
        XCTAssertFalse(e.mayHaveActed)
    }

    func testCouldNotFindARiskyStep() {
        let e = Explainer.explain("Couldn't find step 2 on screen, and it sends, saves or deletes, so Deja Do won't click where it used to be.")
        XCTAssertEqual(e.headline, "Couldn't find what to click")
        XCTAssertTrue(e.why.contains("won't guess"))
        XCTAssertTrue(e.actions.contains(.checkSteps))
    }

    func testMismatchOffersKeepGoing() {
        let e = Explainer.explain("Stopped at step 4: Expected “Thanks, Ana” after this step, but didn't see it. Instead saw “Send this request?”. Change what happens on a mismatch under the step if this is expected.")
        XCTAssertEqual(e.actions.first, .keepGoingOnMismatch)
    }

    func testMayHaveActedComesFirst() {
        let e = Explainer.explain("Another app came forward. Step 4 may already have sent or saved something. Check before running this again.")
        XCTAssertTrue(e.mayHaveActed)
        XCTAssertTrue(e.steps[0].hasPrefix("Look in the app first"))
    }

    func testStoppedByThePerson() {
        XCTAssertEqual(Explainer.explain("Stopped. Stopped before anything was sent or saved.").headline, "You stopped it")
    }

    func testDifferentWebsite() {
        XCTAssertEqual(Explainer.explain("Safari is showing example.org, but this step was recorded on shop.example.com. Deja Do doesn't click on a different website.").headline,
                       "It's on a different website")
    }

    func testFocusLost() {
        XCTAssertEqual(Explainer.explain("WhatsApp isn't in front any more (Slack is), so Deja Do stopped before sending it anything.").headline,
                       "Another app came to the front")
    }

    func testSchedules() {
        XCTAssertEqual(Explainer.explain("Missed the scheduled run at 9:00 AM: the Mac was asleep or Deja Do wasn't open.").headline,
                       "A scheduled run was missed")
        XCTAssertEqual(Explainer.explain("“Report” didn't run on schedule. Fill in {{name}} first.").headline,
                       "The schedule couldn't run it")
    }

    func testEverythingGetsSomething() {
        let e = Explainer.explain("A brand new message nobody has seen.")
        XCTAssertFalse(e.steps.isEmpty)
        XCTAssertFalse(e.headline.isEmpty)
    }
}

final class ExplainInfoTests: XCTestCase {
    func testCheckIsNotAProblem() {
        let e = Explainer.explain("Check: found 3 of 4 clicks on screen now. Nothing was clicked or typed.")
        XCTAssertEqual(e.headline, "What Check found")
        XCTAssertFalse(e.mayHaveActed)
    }

    func testGoodNewsHasNothingToDo() {
        XCTAssertTrue(Explainer.explain("Done. Read total: 15.").steps.isEmpty)
        XCTAssertTrue(Explainer.explain("Saved 5 steps.").steps.isEmpty)
    }
}
