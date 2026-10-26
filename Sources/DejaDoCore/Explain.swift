import Foundation

/// Something the person can do straight from an explanation.
public enum FixAction: String, Codable, Equatable, CaseIterable {
    case accessibilitySettings, inputMonitoringSettings, screenRecordingSettings
    case somethingInTheWay, keepGoingOnMismatch, openSettings, runHistory, runAgain, checkSteps

    public var label: String {
        switch self {
        case .accessibilitySettings: return "Open Accessibility settings"
        case .inputMonitoringSettings: return "Open Input Monitoring settings"
        case .screenRecordingSettings: return "Open Screen Recording settings"
        case .somethingInTheWay: return "Something in the way?"
        case .keepGoingOnMismatch: return "Keep going when it looks different"
        case .openSettings: return "Open Deja Do settings"
        case .runHistory: return "Run history"
        case .runAgain: return "Run again"
        case .checkSteps: return "Check"
        }
    }
}

/// A message from Deja Do, said again in plain terms: what it means, why it
/// tends to happen, and what to do about it.
public struct Explanation: Equatable {
    /// One short line, like "Couldn't find a button".
    public var headline: String
    /// Why this usually happens.
    public var why: String
    /// What to do, in order.
    public var steps: [String]
    /// Buttons worth offering, most useful first.
    public var actions: [FixAction]
    /// Whether anything may already have been sent or saved.
    public var mayHaveActed: Bool

    public init(headline: String, why: String, steps: [String], actions: [FixAction], mayHaveActed: Bool = false) {
        self.headline = headline
        self.why = why
        self.steps = steps
        self.actions = actions
        self.mayHaveActed = mayHaveActed
    }
}

public enum Explainer {
    /// Explains any status or stop message the app shows. Never fails: an
    /// unknown message gets general advice.
    public static func explain(_ message: String) -> Explanation {
        let m = message.lowercased().replacingOccurrences(of: "’", with: "'")
        func has(_ words: String...) -> Bool { words.contains { m.contains($0) } }
        let acted = has("may already have sent", "may already have saved", "may already have", "may have sent or saved")
        var e = match(m, has)
        if acted {
            e.mayHaveActed = true
            e.steps.insert("Look in the app first: a step that sends or saves had already run, so running again could do it twice.", at: 0)
        }
        return e
    }

    private static func match(_ m: String, _ has: (String...) -> Bool) -> Explanation {
        // Not problems: what Check found, and things that went fine.
        if m.hasPrefix("check:") {
            return Explanation(
                headline: "What Check found",
                why: "Check looks for each click on the screen as it is right now, without clicking or typing. A step that only shows up after earlier steps run can't be seen yet, so “not on screen right now” is often fine.",
                steps: ["Each step shows what Check found under it.",
                        "If a step should be visible but wasn't found, open the app on that screen, or open the step and change “Looks for”."],
                actions: [])
        }
        if has("imported") {
            return Explanation(
                headline: "New tasks to look over",
                why: "A task from someone else can click and type anything, so read it before running it.",
                steps: ["Read each step, especially ones marked as sending, saving or deleting.", "Press Check to see what it would click."],
                actions: [.checkSteps])
        }
        if m.hasPrefix("done") || m.hasPrefix("saved") || m.hasPrefix("got it") || m.hasPrefix("added") || m.hasPrefix("copied")
            || m.hasPrefix("exported") || m.hasPrefix("running") || m.hasPrefix("step ") && has("will now keep going") {
            return Explanation(headline: "All good", why: "", steps: [], actions: [])
        }

        // Permissions. macOS turns these off again when the app changes, after an update or a new build.
        if has("accessibility") {
            return Explanation(
                headline: "Deja Do isn't allowed to control the Mac",
                why: "macOS needs your say so before an app can click and type for you. It also switches that off again when Deja Do is updated or rebuilt.",
                steps: ["Open Accessibility settings.", "Turn Deja Do off and on again (or add it with +).", "Run the task again."],
                actions: [.accessibilitySettings, .runAgain])
        }
        if has("input monitoring") {
            return Explanation(
                headline: "Deja Do can't watch what you do",
                why: "Recording, and teaching it to close a popup, need Input Monitoring. macOS switches it off again after an update or a new build.",
                steps: ["Open Input Monitoring settings.", "Turn Deja Do off and on again.", "Quit and reopen Deja Do, then try again."],
                actions: [.inputMonitoringSettings])
        }
        if has("screen recording") {
            return Explanation(
                headline: "Deja Do can't see the screen",
                why: "Without Screen Recording it can only find things apps describe themselves, which many web and chat apps don't.",
                steps: ["Open Screen Recording settings.", "Turn Deja Do on, then quit and reopen it."],
                actions: [.screenRecordingSettings])
        }

        // Stopped by the person.
        if m.hasPrefix("stopped.") || has("as asked", "you chose not to") {
            return Explanation(
                headline: "You stopped it",
                why: "The run was stopped with Esc, the Stop button, or by answering no.",
                steps: ["Run it again when you're ready."],
                actions: [.runAgain])
        }

        // A different website.
        if has("different website") {
            return Explanation(
                headline: "It's on a different website",
                why: "The browser was showing another site than the one the task was recorded on, and Deja Do never clicks on a site it wasn't shown.",
                steps: ["Open the website the task was recorded on, in the same browser.", "Run the task again."],
                actions: [.runAgain])
        }

        // Something covering the target.
        if has("is covering", "covering the spot") {
            return Explanation(
                headline: "Something was on top of what it needed to click",
                why: "A notification, dialog or another app's window was over the spot, so clicking would have hit the wrong thing.",
                steps: ["Close whatever is on top.", "Turn on Do Not Disturb while tasks run, so banners don't cover things.",
                        "If it's a popup that keeps showing up, use Something in the way? to teach Deja Do to close it."],
                actions: [.somethingInTheWay, .runAgain])
        }

        // A learned popup rule that didn't work.
        if has("is in the way and") {
            return Explanation(
                headline: "A popup it knows got in the way, and closing it didn't work",
                why: "The popup changed since you showed Deja Do how to close it.",
                steps: ["Remove that popup rule under the task's steps.", "Run again, and when it stops, use Something in the way? to show it the new way to close it."],
                actions: [.somethingInTheWay])
        }

        // Another app came to the front.
        if has("isn't in front", "lost focus", "didn't come to the front") {
            return Explanation(
                headline: "Another app came to the front",
                why: "Deja Do only clicks and types into the app the step is for, so it stopped rather than type into the wrong place.",
                steps: ["Leave the Mac alone while a task runs.", "Turn on Do Not Disturb, or quit apps that pop up on their own.", "Run the task again."],
                actions: [.runAgain])
        }

        // Typing problems.
        if has("only part of the text", "typing didn't reach") {
            return Explanation(
                headline: "The typing didn't all land",
                why: "The field wasn't ready, or lost the cursor part way through. Some apps take a moment after a click before they accept typing.",
                steps: ["Look at the field and clear anything half typed.", "Right click the step before the typing and choose Add a 2 second wait after.", "Run again."],
                actions: [.runAgain])
        }

        // A read step found nothing.
        if has("no text there") {
            return Explanation(
                headline: "The text it reads was empty",
                why: "The place it reads from was found, but had nothing in it at that moment, often because the app was still loading.",
                steps: ["Add a short wait before the read step.", "Run again."],
                actions: [.runAgain])
        }

        // Missing app or window.
        if has("couldn't find the app") {
            return Explanation(
                headline: "The app isn't on this Mac",
                why: "The task uses an app that isn't installed, or was renamed or moved.",
                steps: ["Install or open the app.", "If it was replaced by another app, record that part again."],
                actions: [])
        }
        if has("window to click in", "window is on screen", "couldn't read the", "where in the") {
            return Explanation(
                headline: "The app's window wasn't there",
                why: "The app was open but its window was closed, minimised or on another desktop.",
                steps: ["Open the app's window on this desktop, not minimised.", "Run again."],
                actions: [.runAgain])
        }

        // The screen afterwards didn't match.
        if has("expected", "didn't see", "instead saw") && has("stopped at step", "after this step") {
            return Explanation(
                headline: "It worked, but the screen looked different afterwards",
                why: "Deja Do checks each step did what it did when you recorded it. This time the screen showed something else, so it stopped in case something went wrong.",
                steps: ["Look at what it saw instead (in Details).", "If that's fine, open the step and set “If it doesn't match” to Keep going.",
                        "If it's wrong, fix the app's screen and run again."],
                actions: [.keepGoingOnMismatch, .runAgain])
        }

        // Window resized: position guesses refused.
        if has("changed size") {
            return Explanation(
                headline: "Couldn't find a step, and the window is a different size",
                why: "The button has no name Deja Do can look for, and the window isn't the size it was when recorded, so clicking the old spot would be a guess.",
                steps: ["Make the app's window the size it was when you recorded (or full screen if it was).", "Run again, or turn on AI in Settings so it can look properly."],
                actions: [.checkSteps, .openSettings])
        }

        // Couldn't find something.
        if has("couldn't find", "could only be found by how the screen looks") {
            let sends = has("sends, saves or deletes")
            return Explanation(
                headline: "Couldn't find what to click",
                why: "The button, chat or link wasn't on screen the way it was when recorded. Usually a different chat or page is open, the list has scrolled, or it's been renamed."
                    + (sends ? " This step sends or saves, so Deja Do won't guess." : ""),
                steps: ["Open the app on the same screen you recorded from, with the button or chat visible.",
                        "Press Check to see which steps it can find right now.",
                        "If the name changed, open the step and change “Looks for”.",
                        "Turn on AI in Settings so it can find things that moved or were renamed."],
                actions: [.checkSteps, .openSettings, .somethingInTheWay])
        }

        // Teaching a popup found nothing.
        if has("couldn't see a popup") {
            return Explanation(
                headline: "Nothing was in the way",
                why: "It looked at the app and couldn't find a popup or banner to learn, so the run stopped for another reason.",
                steps: ["Open Run history to see why it stopped."],
                actions: [.runHistory])
        }

        // Schedules.
        if has("missed the scheduled run") {
            return Explanation(
                headline: "A scheduled run was missed",
                why: "The Mac was asleep, off, or Deja Do wasn't open at that time. Deja Do runs a missed task up to an hour late, but not after that.",
                steps: ["Keep Deja Do open, and turn on Open Deja Do when you log in.", "Set the Mac not to sleep at the times the task runs."],
                actions: [.openSettings])
        }
        if has("didn't run on schedule") {
            return Explanation(
                headline: "The schedule couldn't run it",
                why: "Nobody is there to answer when a task runs on its own, so it can't ask for text, a password or a missing value.",
                steps: ["Fill in the task's values in its schedule, or change “Ask each run” steps to fixed text.", "Passwords can't be scheduled."],
                actions: [])
        }
        if has("open deja do when you log in") {
            return Explanation(
                headline: "Schedules stop after a restart",
                why: "Deja Do has to be open to run a scheduled task.",
                steps: ["Turn on Open Deja Do when you log in, in Settings."],
                actions: [.openSettings])
        }

        // Spreadsheets.
        if has("no column for", "no rows under") {
            return Explanation(
                headline: "The spreadsheet doesn't fit the task",
                why: "Each {{name}} in the task needs a column with that name in the first row of the file.",
                steps: ["Add a header row whose names match the task's {{names}}.", "Save as CSV and choose it again."],
                actions: [])
        }
        if has("couldn't read") && has(".csv", ".tsv", ".txt") {
            return Explanation(
                headline: "Couldn't read the file",
                why: "Deja Do reads CSV or tab separated text.",
                steps: ["In your spreadsheet app, export or save as CSV.", "Choose that file."],
                actions: [])
        }

        // Recording.
        if has("nothing was recorded") {
            return Explanation(
                headline: "Nothing was recorded",
                why: "No clicks or typing reached Deja Do while it was recording, often because Input Monitoring is off.",
                steps: ["Check Input Monitoring is on for Deja Do.", "Start a new recording and do the task in another app."],
                actions: [.inputMonitoringSettings])
        }
        if has("blocked recording", "blocked watching") {
            return Explanation(
                headline: "macOS blocked Deja Do from watching",
                why: "Input Monitoring is off, often after an update or a new build.",
                steps: ["Open Input Monitoring settings.", "Turn Deja Do off and on, then quit and reopen it."],
                actions: [.inputMonitoringSettings])
        }

        // Saving and exporting.
        if has("couldn't save", "couldn't export", "couldn't write") {
            return Explanation(
                headline: "Couldn't save the file",
                why: "The folder may be read only, full, or need permission.",
                steps: ["Try saving somewhere else, like Documents or the Desktop."],
                actions: [])
        }

        return Explanation(
            headline: "It stopped",
            why: "Deja Do stops whenever it isn't sure, rather than click the wrong thing.",
            steps: ["Look at the step it stopped at and what it saw (in Details).", "Run history keeps the notes from every run."],
            actions: [.runHistory, .runAgain])
    }
}
