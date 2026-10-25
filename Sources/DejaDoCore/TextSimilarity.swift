import Foundation

/// How alike two UI labels are, from 0 (nothing in common) to 1 (same).
///
/// Labels drift between app versions in predictable ways: counts change
/// ("Inbox 3" → "Inbox 12"), punctuation and case change ("Save…" → "save"),
/// words get added ("Export" → "Export as PDF"), and typos get fixed. Each of
/// those is handled explicitly so a renamed button still scores high while
/// a different button does not.
public enum TextSimilarity {
    /// Lowercase, strip accents and punctuation, collapse whitespace.
    /// A label made only of symbols ("+", "=", "…") keeps its symbols, since
    /// they are the whole label, rather than collapsing to nothing.
    public static func normalize(_ s: String) -> String {
        let words = normalizeWords(s)
        if !words.isEmpty { return words }
        return s.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func normalizeWords(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = ""
        out.reserveCapacity(folded.count)
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    public static func tokens(_ normalized: String) -> [String] {
        normalized.split(separator: " ").map(String.init)
    }

    /// Classic edit distance with two rows of memory. Inputs are capped so a
    /// pathological 5,000 character label can't stall a replay.
    public static func levenshtein(_ a: String, _ b: String, cap: Int = 160) -> Int {
        let x = Array(a.prefix(cap)), y = Array(b.prefix(cap))
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = Array(repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }

    /// 1 minus edit distance over the longer length.
    public static func editRatio(_ a: String, _ b: String) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(levenshtein(a, b)) / Double(min(longest, 160))
    }

    public static func jaccard(_ a: [String], _ b: [String]) -> Double {
        let sa = Set(a), sb = Set(b)
        guard !sa.isEmpty || !sb.isEmpty else { return 1 }
        return Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
    }

    /// Sørensen–Dice over character trigrams. Good at partial word overlap.
    public static func trigramDice(_ a: String, _ b: String) -> Double {
        func grams(_ s: String) -> [String: Int] {
            let padded = Array("  " + s + " ")
            var out: [String: Int] = [:]
            guard padded.count >= 3 else { return out }
            for i in 0...(padded.count - 3) { out[String(padded[i..<i + 3]), default: 0] += 1 }
            return out
        }
        let ga = grams(a), gb = grams(b)
        let total = ga.values.reduce(0, +) + gb.values.reduce(0, +)
        guard total > 0 else { return 1 }
        var shared = 0
        for (g, n) in ga { shared += min(n, gb[g] ?? 0) }
        return 2 * Double(shared) / Double(total)
    }

    /// Text with every digit removed, so changing counters still match.
    static func withoutDigits(_ normalized: String) -> String {
        normalize(String(normalized.unicodeScalars.filter { !CharacterSet.decimalDigits.contains($0) }
            .map(Character.init)))
    }

    /// nil when either side has no text, so callers can tell "different" from "unknown".
    public static func similarity(_ a: String?, _ b: String?) -> Double? {
        guard let a, let b else { return nil }
        let na = normalize(a), nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return nil }
        // A symbol only label ("+", "…") only compares with another one; against
        // words it says nothing either way.
        let symbolsA = normalizeWords(a).isEmpty, symbolsB = normalizeWords(b).isEmpty
        if symbolsA != symbolsB { return nil }
        if symbolsA { return na == nb ? 1 : 0 }
        if na == nb { return 1 }

        let da = withoutDigits(na), db = withoutDigits(nb)
        if !da.isEmpty, da == db { return 0.93 }

        let ta = tokens(na), tb = tokens(nb)
        let shorter = ta.count <= tb.count ? ta : tb
        let longer = ta.count <= tb.count ? tb : ta
        var containment = 0.0
        if !shorter.isEmpty, shorter.joined().count >= 3,
           longer.joined(separator: " ").contains(shorter.joined(separator: " ")) {
            // "Export" inside "Export as PDF": strong, scaled by how much was added.
            containment = 0.72 + 0.2 * Double(shorter.count) / Double(longer.count)
        }

        let fuzzy = max(editRatio(na, nb), 0.5 * jaccard(ta, tb) + 0.5 * trigramDice(na, nb))
        return min(1, max(containment, fuzzy))
    }

    /// Best match between any pairing of the two label sets.
    public static func best(_ a: [String?], _ b: [String?]) -> Double? {
        var best: Double?
        for x in a {
            for y in b {
                if let s = similarity(x, y) { best = max(best ?? 0, s) }
            }
        }
        return best
    }

    /// Generated identifiers (`_NS:123`, UUIDs, long hex or number runs) change
    /// on every launch, so matching on them does more harm than good.
    /// Prefixes web frameworks put on ids they make up at load time.
    static let generatedPrefixes = ["mui-", "ember", "react-", "radix-", "headlessui-", "downshift-", "rc_", "rc-", ":r", "ng-", "yui_", "ext-", "gwt-uid"]

    public static func isStableIdentifier(_ id: String?) -> Bool {
        guard let id, !id.isEmpty else { return false }
        if id.hasPrefix("_NS:") { return false }
        let lower = id.lowercased()
        if lower.contains(":") || generatedPrefixes.contains(where: { lower.hasPrefix($0) }) { return false }
        // "field-12", "item_307": numbered at load time, different next time.
        if let sep = lower.lastIndex(where: { $0 == "-" || $0 == "_" }) {
            let tail = lower[lower.index(after: sep)...]
            if tail.count >= 2, tail.allSatisfy(\.isNumber) { return false }
        }
        var digitRun = 0, hexRun = 0, maxDigit = 0, maxHex = 0
        for ch in id {
            if ch.isNumber { digitRun += 1 } else { digitRun = 0 }
            if ch.isHexDigit { hexRun += 1 } else { hexRun = 0 }
            maxDigit = max(maxDigit, digitRun)
            maxHex = max(maxHex, hexRun)
        }
        if maxDigit >= 5 || maxHex >= 12 { return false }
        let dashed = id.split(separator: "-")
        if dashed.count == 5, dashed.allSatisfy({ $0.allSatisfy(\.isHexDigit) }) { return false }
        return true
    }
}
