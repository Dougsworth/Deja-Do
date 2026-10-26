import Foundation

// MARK: - Typed text

/// Whether typing reached the field, judged from the field's value before
/// and after. Decision rules from OpenAdapt's typed input check
/// (openadapt_flow/runtime/replayer.py, MIT licence, Copyright (c) 2026 OpenAdapt.AI):
/// unchanged means it can be typed again; partly typed means stop, because
/// typing again would double it.
public enum TypingVerdict: Equatable {
    case landed
    /// The field didn't change at all. Safe to type once more.
    case nothingTyped
    /// Some of it landed. Typing again would duplicate it.
    case partial
    /// Can't tell: no readable field, a field that reformats input, or text with Return in it.
    case unknown
}

public enum TypingCheck {
    public static func verdict(before: String?, after: String?, typed: String, secure: Bool) -> TypingVerdict {
        guard let before, let after, !typed.isEmpty else { return .unknown }
        // Return or Tab moves focus or sends, so the field may rightly be empty afterwards.
        if typed.contains("\n") || typed.contains("\r") || typed.contains("\t") { return .unknown }
        if before == after { return .nothingTyped }
        if secure {
            // Password fields only show dots: compare lengths.
            let added = after.count - before.count
            if added == typed.count { return .landed }
            if added > 0 && added < typed.count { return .partial }
            return .unknown
        }
        // Compare letters and digits only, so fields that add their own spaces,
        // brackets or dashes (phone numbers, card numbers) still count as landed.
        func squash(_ s: String) -> String {
            let alnum = s.lowercased().filter { $0.isLetter || $0.isNumber }
            return alnum.isEmpty ? s.lowercased().filter { !$0.isWhitespace } : alnum
        }
        let a = squash(after), t = squash(typed), b = squash(before)
        if t.isEmpty || a.contains(t) { return .landed }
        // Only the start of it arrived: the field is exactly what it was plus part of the text.
        for n in stride(from: t.count - 1, through: 1, by: -1) where a == b + String(t.prefix(n)) {
            return .partial
        }
        // Changed, but not into what was typed: autocomplete or a field that reformats.
        return .unknown
    }
}

// MARK: - Guarded self healing

/// The parts of a recorded element that say what it is, as opposed to where it is.
public struct OriginalIdentity: Codable, Equatable {
    public var role: String
    public var subrole: String?
    public var title: String?
    public var desc: String?
    public var identifier: String?
    public var label: String?

    public init(_ l: ElementLocator) {
        role = l.role; subrole = l.subrole; title = l.title; desc = l.desc; identifier = l.identifier; label = l.label
    }

    var texts: [String?] { [label, title, desc] }
}

/// Decides whether a repaired locator still means the same element. A repair
/// may change how an element is found, never which element it is.
/// Idea from OpenAdapt's repair governance (runtime/healing/governance.py, MIT).
public enum HealGuard {
    public static func accepts(_ new: ElementLocator, original: OriginalIdentity, risky: Bool) -> Bool {
        if original.role != "AXPosition" && MatchEngine.roleCompatibility(original.role, new.role) < 0.6 { return false }
        if TextSimilarity.isStableIdentifier(original.identifier), let id = new.identifier, id != original.identifier {
            return false
        }
        let hasText = original.texts.contains { !($0 ?? "").isEmpty }
        guard hasText else { return !risky }
        let similarity = TextSimilarity.best(original.texts, [new.label, new.title, new.desc]) ?? 0
        return similarity >= (risky ? 0.9 : 0.6)
    }

    /// The locator to save after a repair: the new one with the original identity kept,
    /// or nil when the repair drifted too far and the recording should stay as it was.
    /// - Parameter confirmed: the person looked at this pick and said yes. Their
    ///   say-so stands in for the text check, so a button renamed from "Submit"
    ///   to "Send" is fixed for good instead of asked about every run. It still
    ///   has to be the same kind of control.
    public static func repaired(_ new: ElementLocator, from old: ElementLocator, risky: Bool,
                                confirmed: Bool = false) -> ElementLocator? {
        let identity = old.identity
        if confirmed {
            guard identity.role == "AXPosition" || MatchEngine.roleCompatibility(identity.role, new.role) >= 0.6 else { return nil }
        } else {
            guard accepts(new, original: identity, risky: risky) else { return nil }
        }
        var kept = new
        kept.original = identity
        kept.clickOffset = old.clickOffset
        kept.visual = old.visual
        return kept
    }
}

// MARK: - How a run ended

/// How a run ended, said in terms of what may already have happened.
/// From OpenAdapt's outcome classes (transaction.py, MIT): stopping before any
/// send or save is very different from stopping after one.
public enum RunOutcome: Equatable {
    case finished
    /// Stopped before any risky step ran. Safe to run again from the top.
    case stoppedBeforeChanges(atStep: Int)
    /// Stopped after a risky step ran. Running again could repeat it.
    case stoppedAfterChanges(atStep: Int, lastRiskyStep: Int)
    case cancelled(atStep: Int, riskyDone: Bool)

    public static func classify(stoppedAt: Int?, cancelled: Bool, riskyDone: [Int]) -> RunOutcome {
        guard let at = stoppedAt else { return .finished }
        if cancelled { return .cancelled(atStep: at, riskyDone: !riskyDone.isEmpty) }
        if let last = riskyDone.last { return .stoppedAfterChanges(atStep: at, lastRiskyStep: last) }
        return .stoppedBeforeChanges(atStep: at)
    }

    /// Whether running the same row again from the top could repeat a send or save.
    public var mayRepeatChanges: Bool {
        switch self {
        case .stoppedAfterChanges: return true
        case .cancelled(_, let done): return done
        default: return false
        }
    }

    /// One line for the status bar.
    public var advice: String {
        switch self {
        case .finished: return "Done."
        case .stoppedBeforeChanges: return "Nothing was sent or saved before it stopped, so it's safe to run again."
        case .stoppedAfterChanges(_, let last):
            return "Step \(last + 1) may already have sent or saved something. Check before running this again."
        case .cancelled(_, let done):
            return done ? "Stopped after a step that may have sent or saved something." : "Stopped before anything was sent or saved."
        }
    }
}

// MARK: - Checking a task file

/// Checks a task before trusting it, especially one imported from someone else.
/// Rules from MacTape's SafetyValidator (MIT licence, Copyright (c) 2026 jovial-liu).
public enum TaskValidator {
    public static func problems(_ a: Automation) -> [String] {
        var out: [String] = []
        if a.name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("The task has no name.") }
        if a.steps.count > 2000 { out.append("The task has more than 2,000 steps.") }
        var ids = Set<UUID>()
        for (i, step) in a.steps.enumerated() {
            if !ids.insert(step.id).inserted { out.append("Step \(i + 1) repeats another step's ID.") }
            switch step.kind {
            case .wait(let s) where !s.isFinite || s < 0 || s > 3600:
                out.append("Step \(i + 1) waits \(s) seconds.")
            case .click(_, _, let count, _) where !(1...3).contains(count):
                out.append("Step \(i + 1) clicks \(count) times.")
            case .type(let text, _, _, _) where text.count > 20_000:
                out.append("Step \(i + 1) types more than 20,000 characters.")
            default:
                break
            }
        }
        if (a.format ?? 1) > Automation.currentFormat {
            out.append("Made by a newer Deja Do (format \(a.format ?? 0)). Update the app to use it.")
        }
        return out
    }
}
