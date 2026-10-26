import Foundation

/// `{{name}}` placeholders in typed text, filled in each time a task runs.
public enum Variables {
    private static let pattern = try! NSRegularExpression(pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#)

    /// Placeholder names in the order they appear, without repeats.
    public static func names(in text: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        for m in pattern.matches(in: text, range: range) {
            guard let r = Range(m.range(at: 1), in: text) else { continue }
            let name = String(text[r])
            if seen.insert(key(name)).inserted { out.append(name) }
        }
        return out
    }

    /// Replaces every placeholder. Names match ignoring case and extra spaces,
    /// so a "First Name" column fills `{{first name}}`. Unknown names become empty.
    public static func fill(_ text: String, with values: [String: String]) -> String {
        guard text.contains("{{") else { return text }
        var lookup: [String: String] = [:]
        for (k, v) in values { lookup[key(k)] = v }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += lookup[key(ns.substring(with: m.range(at: 1)))] ?? ""
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// A variable name for a value read off the screen: from the label next to
    /// it ("Total:" gives "total"), else "value", made unique among `taken`.
    public static func suggestName(near label: String?, taken: [String]) -> String {
        var base = (label ?? "")
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(3).joined(separator: " ")
        if base.isEmpty || base.count > 30 || base.first?.isNumber == true { base = "value" }
        let used = Set(taken.map(key))
        guard used.contains(key(base)) else { return base }
        var n = 2
        while used.contains(key("\(base) \(n)")) { n += 1 }
        return "\(base) \(n)"
    }

    public static func key(_ name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Variables the task needs that the spreadsheet has no column for.
    public static func missing(_ names: [String], in headers: [String]) -> [String] {
        let have = Set(headers.map(key))
        return names.filter { !have.contains(key($0)) }
    }
}

extension Automation {
    /// Every `{{variable}}` the task needs given to it, in order. Names a read
    /// step fills earlier in the task come from the screen, so they aren't asked for.
    public var variableNames: [String] {
        var seen = Set<String>(), out: [String] = []
        for step in steps {
            if case .read(_, let name) = step.kind { seen.insert(Variables.key(name)); continue }
            guard case .type(let text, let ask, let secret, _) = step.kind, !ask, !secret else { continue }
            for name in Variables.names(in: text) where seen.insert(Variables.key(name)).inserted {
                out.append(name)
            }
        }
        return out
    }

    /// The names read steps fill, in order.
    public var readNames: [String] {
        steps.compactMap { if case .read(_, let n) = $0.kind { return n }; return nil }
    }
}

/// Reads CSV or tab separated text, as saved by Excel, Numbers or Google Sheets.
public enum CSV {
    /// Rows of cells. Handles quoted cells with commas, quotes ("") and line
    /// breaks inside them, Windows line endings and Excel's byte order mark.
    public static func parse(_ text: String) -> [[String]] {
        var input = text
        if input.hasPrefix("\u{FEFF}") { input.removeFirst() }
        let delimiter = detectDelimiter(input)

        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var inQuotes = false
        var chars = Array(input)
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { cell.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    cell.append(c)
                }
            } else if c == "\"" && cell.isEmpty {
                inQuotes = true
            } else if c == delimiter {
                row.append(cell); cell = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(cell); cell = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else {
                cell.append(c)
            }
            i += 1
        }
        return rows
    }

    /// First row as headers, the rest as one dictionary per row.
    public static func records(_ text: String) -> (headers: [String], rows: [[String: String]]) {
        let all = parse(text)
        guard let first = all.first else { return ([], []) }
        let headers = first.map { $0.trimmingCharacters(in: .whitespaces) }
        let rows = all.dropFirst().map { cells -> [String: String] in
            var r: [String: String] = [:]
            for (i, h) in headers.enumerated() where !h.isEmpty {
                r[h] = i < cells.count ? cells[i] : ""
            }
            return r
        }
        return (headers, rows)
    }

    /// Tab if the header line has tabs, semicolon if it only has semicolons, else comma.
    static func detectDelimiter(_ text: String) -> Character {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r\n" && $0 != "\r" }
        if firstLine.contains("\t") { return "\t" }
        if firstLine.contains(";") && !firstLine.contains(",") { return ";" }
        return ","
    }
}
