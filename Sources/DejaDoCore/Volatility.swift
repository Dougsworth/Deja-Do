import Foundation

/// Text that changes by itself and so can't be expected to look the same on
/// the next run: clocks, "3 days ago", counters, recent dates, fragments.
///
/// Ported from OpenAdapt's volatility classifier (openadapt_flow/volatility.py,
/// MIT licence, Copyright (c) 2026 OpenAdapt.AI). Like theirs it treats a date
/// near the recording date as volatile (a "last updated" stamp, a message
/// list) and a far one as stable (a date of birth, a contract date).
public enum Volatility {
    static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }

    static let clock = re(#"(?<!\d)\d{1,2}:\d{2}(?::\d{2})?(?!\d)|(?<![\w:]):\d{2}(?!\d)"#)
    static let dotClock = re(#"(?<![\w.])(?:[01]\d|2[0-3])\.[0-5]\d(?![\d.])|(?<![\w.])(?:[01]?\d|2[0-3])\.[0-5]\d\s*(?:am|pm)\b|\b(?:at|updated?|update[ds]|time)\s+(?:[01]?\d|2[0-3])\.[0-5]\d(?![\d.])"#)
    static let relative = re(#"(?<!\d)\d+\s*(?:sec(?:ond)?s?|min(?:ute)?s?|h(?:ou)?rs?|days?|w(?:ee)?ks?|months?|mos?|y(?:ea)?rs?|[smhdw])\s*ago(?![a-z])|\bjust\s*now\b|\bmoments?\s*ago\b"#)
    static let count = re(#"(?<!\d)\d[\d,]*\s*(?:to\s*\d[\d,]*\s*)?of\s*\d[\d,]*(?!\d)|(?<!\d)\d[\d,]*\s*(?:(?:total|new|unread|more)\s*)?(?:entr(?:y|ies)|results?|records?|rows?|items?|matches|messages?|notifications?|unread)(?![a-z\d])|\bpage\s*\d+(?!\d)"#)
    static let counterParen = re(#"\(\s*\d+\s*\)"#)
    static let numericDate = re(#"(?<!\d)\d{4}[-/.]\d{1,2}[-/.]\d{1,2}(?!\d)|(?<!\d)\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4}(?!\d)"#)
    static let monthDate = re(#"\b(?:(?:mon|tues?|wed(?:nes)?|thu(?:rs?)?|fri|sat(?:ur)?|sun)(?:day)?[,\s]*)?(?:(?<!\d)(\d{1,2})(?:st|nd|rd|th)?[\s.]*)?(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?(?:\s*(\d{1,2})(?:st|nd|rd|th)?)?(?:,?\s*(\d{4}))?\b"#)
    static let relativeDays: Set<String> = ["today", "yesterday", "tomorrow", "now"]
    static let states: Set<String> = [
        "just now", "typing", "online", "offline", "loading", "please wait", "sending", "sent", "delivered",
        "read", "seen", "connecting", "updating", "syncing", "saving", "saved", "away", "busy", "active now"
    ]
    static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                         "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    static let windowDays = 366.0

    /// Why the text is volatile, or nil when it's stable enough to expect again.
    public static func reason(_ text: String, reference: Date? = Date()) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let squashed = trimmed.lowercased().filter { !$0.isWhitespace }
        guard squashed.count >= 2, trimmed.count <= 80 else { return "length" }
        let lower = trimmed.lowercased()
        let words = lower.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?…")).trimmingCharacters(in: .whitespaces)
        if relativeDays.contains(words) || states.contains(words) { return "state" }
        if lower.hasPrefix("last seen") || lower.hasPrefix("loading") || lower.hasPrefix("typing") { return "state" }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if clock.firstMatch(in: trimmed, range: range) != nil { return "clock" }
        if dotClock.firstMatch(in: trimmed, range: range) != nil { return "clock" }
        if relative.firstMatch(in: trimmed, range: range) != nil { return "relative time" }
        if count.firstMatch(in: trimmed, range: range) != nil { return "count" }
        if counterParen.firstMatch(in: trimmed, range: range) != nil { return "counter" }
        if datesNear(trimmed, reference: reference) == true { return "recent date" }
        let letters = squashed.filter { $0.isLetter }.count
        if letters < 2 { return "mostly digits" }
        if Set(squashed).count < 2 { return "low variety" }
        return nil
    }

    public static func isVolatile(_ text: String, reference: Date? = Date()) -> Bool {
        reason(text, reference: reference) != nil
    }

    /// true when any date in the text is within a year of the reference (or can't be read),
    /// false when all are far, nil when there's no date. With no reference, every date is near.
    static func datesNear(_ text: String, reference: Date?) -> Bool? {
        let range = NSRange(text.startIndex..., in: text)
        var found = false
        let calendar = Calendar(identifier: .gregorian)
        func near(_ y: Int, _ m: Int, _ d: Int) -> Bool? {
            guard let reference else { return true }
            guard (1...12).contains(m), (1...31).contains(d),
                  let date = calendar.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
            return abs(date.timeIntervalSince(reference)) <= windowDays * 86_400
        }
        for m in numericDate.matches(in: text, range: range) {
            found = true
            guard let r = Range(m.range, in: text) else { return true }
            let nums = text[r].split { !$0.isNumber }.compactMap { Int($0) }
            guard nums.count == 3 else { return true }
            var candidates: [Bool?] = []
            if nums[0] >= 1000 {
                candidates = [near(nums[0], nums[1], nums[2]), near(nums[0], nums[2], nums[1])]
            } else {
                let y = nums[2] < 100 ? nums[2] + 2000 : nums[2]
                candidates = [near(y, nums[1], nums[0]), near(y, nums[0], nums[1])]
            }
            let valid = candidates.compactMap { $0 }
            if valid.isEmpty || valid.contains(true) { return true }
        }
        for m in monthDate.matches(in: text, range: range) {
            func group(_ i: Int) -> String? {
                guard m.range(at: i).location != NSNotFound, let r = Range(m.range(at: i), in: text) else { return nil }
                return String(text[r])
            }
            let day = group(1) ?? group(3)
            let year = group(4)
            // A bare month word ("May I help", a "March" menu) isn't a date.
            guard day != nil || year != nil else { continue }
            found = true
            guard let y = year.flatMap(Int.init) else { return true }   // "Jul 8" recurs every year
            let month = months[String((group(2) ?? "").lowercased().prefix(3))] ?? 0
            if let d = day.flatMap(Int.init) {
                if near(y, month, d) != false { return true }
            } else if near(y, month, 15) != false {
                return true
            }
        }
        return found ? false : nil
    }
}
