import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - What the screen showed

/// A piece of text seen on screen, with where it was in the window if known.
public struct SeenText: Codable, Equatable {
    public var text: String
    public var frame: CGRect?
    /// Read from the pixels rather than reported by the app. OCR varies a
    /// little from one frame to the next, so these are weaker evidence.
    public var ocr: Bool

    public init(_ text: String, frame: CGRect? = nil, ocr: Bool = false) {
        self.text = text
        self.frame = frame
        self.ocr = ocr
    }
}

/// A quick read of the front window: which app, its title, the text on it
/// (from Accessibility, plus OCR for apps that don't describe themselves)
/// and a tiny greyscale thumbnail to tell whether anything changed at all.
/// Taken before and after each step. Never saved as is.
public struct ScreenState: Equatable {
    public var bundleID: String?
    public var windowTitle: String?
    public var windowSize: CGSize?
    public var texts: [SeenText]
    public var thumbnail: GrayImage?
    public var usedOCR: Bool

    public init(bundleID: String? = nil, windowTitle: String? = nil, windowSize: CGSize? = nil,
                texts: [SeenText] = [], thumbnail: GrayImage? = nil, usedOCR: Bool = false) {
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.windowSize = windowSize
        self.texts = texts
        self.thumbnail = thumbnail
        self.usedOCR = usedOCR
    }

    /// How many times a text shows. Same words ignoring case and punctuation,
    /// or a near identical rendering of them.
    func count(of text: String) -> Int {
        let key = TextSimilarity.normalize(text)
        guard !key.isEmpty else { return 0 }
        return texts.filter { StepVerifier.sameText(key, TextSimilarity.normalize($0.text)) }.count
    }

    func instances(of text: String) -> [SeenText] {
        let key = TextSimilarity.normalize(text)
        return texts.filter { StepVerifier.sameText(key, TextSimilarity.normalize($0.text)) }
    }

    /// Adds OCR text for anything Accessibility didn't already report.
    /// Repeats within the OCR text are kept: a name in a list and again in a
    /// header is exactly how many steps show their result.
    public mutating func merge(ocr lines: [OCRLine]) {
        let fromAX = Set(texts.map { TextSimilarity.normalize($0.text) })
        for line in lines {
            let key = TextSimilarity.normalize(line.text)
            guard !key.isEmpty, !fromAX.contains(key) else { continue }
            texts.append(SeenText(line.text, frame: line.frame, ocr: true))
        }
        usedOCR = true
    }
}

// MARK: - What a step is expected to do

/// A text that showed up after the step, and where.
public struct ExpectedText: Codable, Equatable {
    public var text: String
    public var frame: CGRect?
    /// The text contains something typed during the recording, like a sent
    /// message. Skipped when typing comes from {{variables}} or is asked each run.
    public var typed: Bool?

    public init(_ text: String, frame: CGRect? = nil, typed: Bool? = nil) {
        self.text = text
        self.frame = frame
        self.typed = typed
    }
}

/// How the screen changed after a step when it was recorded. Only a handful
/// of short labels are kept, never a copy of the screen.
public struct StepExpectation: Codable, Equatable {
    /// Text that showed up, most telling first. For a click on a chat this is
    /// typically the person's name appearing in the conversation header.
    public var appeared: [ExpectedText]
    /// Text that went away, like a dialog's title after pressing OK.
    public var vanished: [String]
    /// The window's title afterwards, when the step changed it.
    public var windowTitle: String?
    /// The app in front afterwards, when the step switched apps.
    public var bundleID: String?
    /// Whether anything visibly changed.
    public var changed: Bool
    /// Whether text read by OCR was part of the recording, so a run should read it too.
    public var usedOCR: Bool
    public var windowSize: CGSize?

    public init(appeared: [ExpectedText] = [], vanished: [String] = [], windowTitle: String? = nil,
                bundleID: String? = nil, changed: Bool = false, usedOCR: Bool = false, windowSize: CGSize? = nil) {
        self.appeared = appeared
        self.vanished = vanished
        self.windowTitle = windowTitle
        self.bundleID = bundleID
        self.changed = changed
        self.usedOCR = usedOCR
        self.windowSize = windowSize
    }

    /// Something specific to look for, beyond "the screen changed".
    public var hasChecks: Bool { !appeared.isEmpty || !vanished.isEmpty || windowTitle != nil || bundleID != nil }

    /// One line for the step list.
    public var summary: String? {
        if let first = appeared.first {
            let more = appeared.count > 1 ? " and \(appeared.count - 1) more" : ""
            return "Then expects “\(first.text.prefix(40))”\(more)"
        }
        if let t = windowTitle { return "Then expects the window “\(t.prefix(40))”" }
        if let v = vanished.first { return "Then expects “\(v.prefix(40))” to go away" }
        if bundleID != nil { return "Then expects another app in front" }
        if changed { return "Then expects the screen to change" }
        return nil
    }

    public static let maxAppeared = 6
    public static let maxVanished = 3
    /// This many texts from Accessibility means the app describes itself and OCR is only a backstop.
    public static let describedWell = 8

    /// The same expectation without text that came from typing, for runs
    /// where what gets typed changes ({{variables}}, ask each run).
    public func withoutTyped() -> StepExpectation {
        var e = self
        e.appeared.removeAll { $0.typed == true }
        return e
    }

    /// Drops text that had already gone again by the time of the next action.
    /// A browser's autofill list, a tooltip, a "Saved" toast: they show up after
    /// a step and vanish on their own, so a run can't be expected to catch them.
    /// A menu or dialog that the next step acts on is still open at that point,
    /// so those stay.
    public func droppingTransient(goneBy later: ScreenState) -> StepExpectation {
        var e = self
        e.appeared.removeAll { later.count(of: $0.text) == 0 }
        return e
    }

    /// Works out what a step did by comparing the screen before and after it.
    /// - Parameter typed: text typed during the recording. Expected text that
    ///   contains it is marked, so runs that type something else can skip it.
    public static func derive(before: ScreenState, after: ScreenState, typed: [String] = []) -> StepExpectation {
        let typedKeys = typed.map(TextSimilarity.normalize).filter { $0.count >= 3 }
        // When the app describes itself, what it says is the evidence. OCR of
        // the same screen comes out slightly differently each time ("G Google",
        // "Google"), and treating that jitter as a result makes runs stop for nothing.
        let describesItself = after.texts.filter { !$0.ocr }.count >= describedWell
        let usable = { (t: SeenText) in !(describesItself && t.ocr) }
        let beforeCounts = counts(before.texts.filter(usable)), afterCounts = counts(after.texts.filter(usable))
        // Text that only changed a number ("Inbox 3" → "Inbox 2") is a counter, not a result.
        let goneDigitless = Set(beforeCounts.keys.filter { (afterCounts[$0] ?? 0) == 0 }.map(digitless))
        let newDigitless = Set(afterCounts.keys.filter { (beforeCounts[$0] ?? 0) == 0 }.map(digitless))

        var appeared: [(ExpectedText, Double, Int)] = []
        var seen = Set<String>()
        for (i, t) in after.texts.enumerated() where usable(t) {
            let key = TextSimilarity.normalize(t.text)
            guard !seen.contains(key), !StepVerifier.isVolatile(t.text) else { continue }
            guard (afterCounts[key] ?? 0) > (beforeCounts[key] ?? 0) else { continue }
            if (beforeCounts[key] ?? 0) == 0, goneDigitless.contains(digitless(key)), !digitless(key).isEmpty { continue }
            seen.insert(key)
            // Of several copies, the new one is the copy farthest from the old ones.
            let olds = before.texts.filter { TextSimilarity.normalize($0.text) == key }.compactMap(\.frame)
            let copies = after.texts.filter { TextSimilarity.normalize($0.text) == key }
            let pick = copies.max { a, b in distance(a.frame, olds) < distance(b.frame, olds) } ?? t
            let fromTyping = typedKeys.contains { key.contains($0) || $0.contains(key) }
            appeared.append((ExpectedText(t.text, frame: pick.frame, typed: fromTyping ? true : nil),
                             salience(t, window: after.windowSize), i))
        }
        appeared.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }

        var vanished: [String] = []
        var seenGone = Set<String>()
        for t in before.texts where usable(t) {
            let key = TextSimilarity.normalize(t.text)
            guard !seenGone.contains(key), !StepVerifier.isVolatile(t.text), t.text.count <= 50 else { continue }
            guard (beforeCounts[key] ?? 0) > 0, (afterCounts[key] ?? 0) == 0 else { continue }
            if newDigitless.contains(digitless(key)), !digitless(key).isEmpty { continue }
            seenGone.insert(key)
            vanished.append(t.text)
            if vanished.count >= maxVanished { break }
        }

        var title: String?
        if let a = after.windowTitle, !StepVerifier.isVolatile(a),
           TextSimilarity.normalize(a) != TextSimilarity.normalize(before.windowTitle ?? ""),
           digitless(TextSimilarity.normalize(a)) != digitless(TextSimilarity.normalize(before.windowTitle ?? "")) {
            title = a
        }
        var app: String?
        if let a = after.bundleID, a != before.bundleID { app = a }

        let pixelsChanged: Bool = {
            guard let x = before.thumbnail, let y = after.thumbnail else { return false }
            return x.changedFraction(from: y) > StepVerifier.pixelChange
        }()
        let textsChanged = beforeCounts != afterCounts || counts(before.texts) != counts(after.texts)
        let changed = textsChanged || pixelsChanged || title != nil || app != nil
            || TextSimilarity.normalize(before.windowTitle ?? "") != TextSimilarity.normalize(after.windowTitle ?? "")

        return StepExpectation(appeared: appeared.prefix(maxAppeared).map(\.0), vanished: vanished,
                               windowTitle: title, bundleID: app, changed: changed,
                               usedOCR: after.usedOCR, windowSize: after.windowSize)
    }

    static func counts(_ texts: [SeenText]) -> [String: Int] {
        var out: [String: Int] = [:]
        for t in texts {
            let k = TextSimilarity.normalize(t.text)
            if !k.isEmpty { out[k, default: 0] += 1 }
        }
        return out
    }

    static func digitless(_ key: String) -> String { TextSimilarity.withoutDigits(key) }

    static func distance(_ f: CGRect?, _ others: [CGRect]) -> CGFloat {
        guard let f else { return 0 }
        guard !others.isEmpty else { return .greatestFiniteMagnitude }
        return others.map { hypot($0.midX - f.midX, $0.midY - f.midY) }.min() ?? 0
    }

    /// Short labels near the top of the window say most about what happened:
    /// headers, titles, the name of what opened. Long paragraphs say least.
    static func salience(_ t: SeenText, window: CGSize?) -> Double {
        let n = t.text.count
        var s = 1.0
        if (3...32).contains(n) { s += 0.6 } else if n > 50 { s -= 0.6 }
        if t.text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) { s += 0.2 }
        if let f = t.frame, let w = window, w.height > 0 {
            s += 0.4 * Double(max(0, 1 - f.midY / w.height))
        }
        return s
    }
}

// MARK: - Checking a step

/// What to do when a step doesn't change the screen the way it did when recorded.
public enum MismatchPolicy: String, Codable, CaseIterable {
    /// Wait a little longer, try the step once more if nothing happened, then stop.
    case retryThenStop
    /// Stop right away.
    case stop
    /// Note it and carry on.
    case keepGoing

    public static let `default` = MismatchPolicy.retryThenStop

    public var label: String {
        switch self {
        case .retryThenStop: return "Try again, then stop"
        case .stop: return "Stop"
        case .keepGoing: return "Keep going"
        }
    }
}

public struct StepCheckResult: Equatable {
    public enum Verdict: Equatable { case passed, uncertain, failed, skipped }

    public let verdict: Verdict
    /// Share of the expected evidence found, 0...1.
    public let score: Double
    /// Expected text that wasn't there.
    public let missing: [String]
    /// The screen didn't change at all, which usually means the step didn't land.
    public let nothingHappened: Bool
    public let summary: String
}

public enum StepVerifier {
    /// Share of thumbnail pixels that must change to count as "the screen changed".
    /// At 128 × 80 that is about 20 pixels, enough for one changed digit.
    public static let pixelChange = 0.002

    /// Compares the screen after a step with what the recording expects.
    /// - Parameter before: the screen just before the step, if read. It lets
    ///   the check tell text that newly appeared from text that was already there.
    public static func check(_ e: StepExpectation, before: ScreenState?, after: ScreenState) -> StepCheckResult {
        let nothing = before.map { unchanged($0, after) } ?? false
        var total = 0.0, hit = 0.0
        var missing: [String] = []

        // The most telling piece of evidence: the new window title, or else
        // the first text that appeared (a chat's header, a dialog's title).
        var primaryMissing = false
        if let app = e.bundleID {
            total += 1
            if after.bundleID == app { hit += 1 } else { missing.append("another app in front") }
        }
        if let title = e.windowTitle {
            total += 2
            if (TextSimilarity.similarity(title, after.windowTitle) ?? 0) >= 0.8 {
                hit += 2
            } else {
                missing.append("window “\(title)”")
                primaryMissing = true
            }
        }
        for (i, want) in e.appeared.enumerated() {
            let w = i == 0 ? 1.5 : 1
            total += w
            let found = presence(of: want, before: before, after: after, recordedWindow: e.windowSize)
            hit += w * found
            if found < 0.5 {
                missing.append("“\(want.text)”")
                if i == 0 && e.windowTitle == nil { primaryMissing = true }
            }
        }
        for gone in e.vanished {
            total += 0.5
            if after.count(of: gone) == 0 { hit += 0.5 } else { missing.append("“\(gone)” gone") }
        }

        guard total > 0 else {
            guard e.changed, before != nil else {
                return StepCheckResult(verdict: .skipped, score: 1, missing: [], nothingHappened: nothing, summary: "Nothing to check")
            }
            return nothing
                ? StepCheckResult(verdict: .failed, score: 0, missing: [], nothingHappened: true,
                                  summary: "Nothing on screen changed after this step")
                : StepCheckResult(verdict: .passed, score: 1, missing: [], nothingHappened: false, summary: "The screen changed")
        }

        let score = hit / total
        if score >= 0.6 && (!primaryMissing || score >= 0.85) {
            return StepCheckResult(verdict: .passed, score: score, missing: missing, nothingHappened: nothing,
                                   summary: "Screen matched · \(Int((score * 100).rounded()))%")
        }
        if nothing && e.changed {
            return StepCheckResult(verdict: .failed, score: score, missing: missing, nothingHappened: true,
                                   summary: "Nothing on screen changed after this step")
        }
        let list = missing.prefix(3).joined(separator: ", ")
        if score >= 0.35 && !primaryMissing {
            return StepCheckResult(verdict: .uncertain, score: score, missing: missing, nothingHappened: nothing,
                                   summary: "Partly matched, didn't see \(list)")
        }
        return StepCheckResult(verdict: .failed, score: score, missing: missing, nothingHappened: nothing,
                               summary: "Expected \(list) after this step, but didn't see it\(insteadSaw(before: before, after: after))")
    }

    /// What did show up instead, so a person can see at a glance what the app
    /// did (an error, a different dialog) without opening it.
    static func insteadSaw(before: ScreenState?, after: ScreenState) -> String {
        guard let before else { return "" }
        let fresh = StepExpectation.derive(before: before, after: after).appeared.prefix(3).map { "“\($0.text.prefix(40))”" }
        return fresh.isEmpty ? "" : ". Instead saw \(fresh.joined(separator: ", "))"
    }

    /// 1 when the text newly showed up, or was already showing right where
    /// the recording saw it appear. 0.25 when it is on screen but neither new
    /// nor in that place (a contact's name still only in the list, say). 0 when absent.
    static func presence(of want: ExpectedText, before: ScreenState?, after: ScreenState, recordedWindow: CGSize?) -> Double {
        let now = after.instances(of: want.text)
        guard !now.isEmpty else { return 0 }
        if let before, now.count > before.count(of: want.text) { return 1 }
        if before == nil { return 1 }
        // Already showing before the step, e.g. the chat was already open. Fine
        // if it sits where the recording saw it appear.
        if let f = want.frame {
            let sx = scaleFactor(recordedWindow?.width, after.windowSize?.width)
            let sy = scaleFactor(recordedWindow?.height, after.windowSize?.height)
            let expected = CGPoint(x: f.midX * sx, y: f.midY * sy)
            let near = now.contains { t in
                guard let g = t.frame else { return false }
                return hypot(g.midX - expected.x, g.midY - expected.y) <= 60
            }
            if near { return 1 }
        }
        return 0.25
    }

    static func scaleFactor(_ old: CGFloat?, _ new: CGFloat?) -> CGFloat {
        guard let old, let new, old > 0, new > 0 else { return 1 }
        return new / old
    }

    /// Nothing at all changed between the two reads.
    static func unchanged(_ a: ScreenState, _ b: ScreenState) -> Bool {
        guard a.bundleID == b.bundleID,
              TextSimilarity.normalize(a.windowTitle ?? "") == TextSimilarity.normalize(b.windowTitle ?? ""),
              StepExpectation.counts(a.texts) == StepExpectation.counts(b.texts) else { return false }
        if let x = a.thumbnail, let y = b.thumbnail { return x.changedFraction(from: y) <= pixelChange }
        return true
    }

    /// Same words, or near identical ones (a fixed typo, a trailing ellipsis).
    static func sameText(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard !a.isEmpty, !b.isEmpty, abs(a.count - b.count) <= 3 else { return false }
        // Numbers must match exactly: "Inbox 3" and "Inbox 4" are different screens.
        func digits(_ s: String) -> String { String(s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }) }
        guard digits(a) == digits(b) else { return false }
        return TextSimilarity.editRatio(a, b) >= 0.9 || (TextSimilarity.similarity(a, b) ?? 0) >= 0.93
    }

    /// Text that changes by itself and says nothing about whether a step
    /// worked: clocks, "2 min ago", "typing…", counters, recent dates.
    public static func isVolatile(_ text: String) -> Bool {
        Volatility.isVolatile(text)
    }
}

// MARK: - Deciding what to do next

/// Turns check results into actions: look again a little later in case the
/// app is slow, repeat the step once if it plainly didn't land, then stop.
///
/// A step is only repeated when nothing at all changed. If the screen changed
/// in some other way, repeating could do harm (a second click on a toggle, a
/// second Send), so the run stops and says what it expected instead.
public struct StepCheckLoop {
    public enum Action: Equatable {
        case proceed(note: String?)
        case recheck(after: Double)
        case redo
        case stop(String)
    }

    public let policy: MismatchPolicy
    public let canRedo: Bool
    /// Risky steps (send, save, delete) are never repeated, and a half match stops instead of carrying on.
    public let risky: Bool
    /// Six seconds of patience in all, because a form that takes a few seconds
    /// to answer is ordinary, and repeating a click into a slow page is how
    /// things get sent twice.
    public var maxRechecks = 5
    public var maxRedos = 1
    public private(set) var rechecks = 0
    public private(set) var redos = 0

    public init(policy: MismatchPolicy, canRedo: Bool, risky: Bool = false) {
        self.policy = policy
        self.canRedo = canRedo && !risky
        self.risky = risky
    }

    public mutating func next(_ r: StepCheckResult) -> Action {
        switch r.verdict {
        case .passed, .skipped:
            return .proceed(note: redos > 0 ? "Worked on the second try" : nil)
        case .uncertain:
            if rechecks < maxRechecks { return recheck() }
            if risky && policy != .keepGoing {
                return .stop("\(r.summary). This step sends, saves or deletes, so Deja Do won't guess")
            }
            return .proceed(note: r.summary)
        case .failed:
            if rechecks < maxRechecks { return recheck() }
            switch policy {
            case .keepGoing:
                return .proceed(note: r.summary)
            case .retryThenStop where canRedo && r.nothingHappened && redos < maxRedos:
                redos += 1
                rechecks = 0
                return .redo
            default:
                return .stop(redos > 0 ? "\(r.summary), even after trying again" : r.summary)
            }
        }
    }

    private mutating func recheck() -> Action {
        rechecks += 1
        let delays = [0.4, 0.8, 1.2, 1.6, 2.0]
        return .recheck(after: delays[min(rechecks, delays.count) - 1])
    }
}
