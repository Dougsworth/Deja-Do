import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Suggested variables

public struct VariableSuggestion: Equatable, Identifiable {
    public var id: UUID { stepID }
    public let stepID: UUID
    public let name: String
    public let text: String
}

/// Offers to turn typed values into {{variables}}, named after the field they
/// were typed into ("Invoice No." becomes {{invoice no}}), or by what the value
/// looks like (an email, a date, an amount). Always a suggestion the person
/// confirms, never automatic. Idea from OpenAdapt's field label annotator and
/// open-record-replay's parameter rules.
public enum VariableSuggester {
    public static func suggestions(for a: Automation) -> [VariableSuggestion] {
        var used = Set(a.variableNames.map(Variables.key))
        var out: [VariableSuggestion] = []
        for step in a.steps where step.isEnabled {
            guard case .type(let text, let ask, let secret, _) = step.kind, !ask, !secret,
                  !text.contains("{{"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let base = name(label: step.fieldLabel, value: text) else { continue }
            var name = base, n = 2
            while used.contains(Variables.key(name)) { name = "\(base) \(n)"; n += 1 }
            used.insert(Variables.key(name))
            out.append(VariableSuggestion(stepID: step.id, name: name, text: text))
        }
        return out
    }

    /// Replaces the step's typed text with the variable. The typed value becomes the variable's last value.
    public static func apply(_ s: VariableSuggestion, to a: inout Automation) {
        guard let i = a.steps.firstIndex(where: { $0.id == s.stepID }),
              case .type(_, let ask, let secret, let prompt) = a.steps[i].kind else { return }
        a.steps[i].kind = .type(text: "{{\(s.name)}}", askEachRun: ask, secret: secret, prompt: prompt)
    }

    static let emailRE = try! NSRegularExpression(pattern: #"^[^\s@]+@[^\s@]+\.[a-z]{2,}$"#, options: [.caseInsensitive])
    static let amountRE = try! NSRegularExpression(pattern: #"^[$£€¥]?\s?-?\d{1,3}(?:[,\s]?\d{3})*(?:\.\d{1,2})?$"#)
    static let phoneRE = try! NSRegularExpression(pattern: #"^\+?[\d\s().-]{7,}$"#)

    static func name(label: String?, value: String) -> String? {
        if let label {
            let words = TextSimilarity.tokens(TextSimilarity.normalize(label))
                .filter { !["enter", "type", "your", "the", "a", "here", "please"].contains($0) }
            if !words.isEmpty, words.joined().count >= 2 {
                return words.prefix(3).joined(separator: " ")
            }
        }
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(v.startIndex..., in: v)
        if emailRE.firstMatch(in: v, range: range) != nil { return "email" }
        if Volatility.datesNear(v, reference: nil) != nil { return "date" }
        if amountRE.firstMatch(in: v, range: range) != nil && v.contains(where: { $0.isNumber }) { return "amount" }
        if phoneRE.firstMatch(in: v, range: range) != nil && v.filter(\.isNumber).count >= 7 { return "phone" }
        if v.hasPrefix("/") || v.hasPrefix("~/") { return "file" }
        return nil
    }
}

// MARK: - Suggested removals

public struct RemovalSuggestion: Equatable {
    public let stepID: UUID
    public let reason: String
}

/// Points out steps that probably did nothing, so a recording can be tidied.
/// Only ever suggested, never removed automatically. Rules adapted from
/// OpenAdapt's distiller (compiler/distill.py, MIT).
public enum StepTrim {
    public static func suggestions(for a: Automation) -> [RemovalSuggestion] {
        var out: [RemovalSuggestion] = []
        let steps = a.steps
        for (i, step) in steps.enumerated() where step.isEnabled {
            let next = steps[(i + 1)...].first { $0.isEnabled }
            switch step.kind {
            case .click(let t, _, _, _):
                guard step.noEffect == true, a.risk(at: i).risk == .normal else { continue }
                // A click that only focused a field the next step types into is needed.
                if let next, case .type = next.kind { continue }
                if let next, case .key = next.kind { continue }
                if ["AXTextField", "AXTextArea", "AXComboBox"].contains(t.role) { continue }
                out.append(RemovalSuggestion(stepID: step.id, reason: "Nothing changed on screen after this click"))
            case .activate:
                if next == nil { out.append(RemovalSuggestion(stepID: step.id, reason: "Switches app at the very end")) }
            case .key(let code, let mods, _):
                // ⌘Tab or ⌘Space at the end is usually reaching for Deja Do to stop recording.
                let command = mods & RiskGuesser.commandFlag != 0
                if next == nil && command && (code == 48 || code == 49) {
                    out.append(RemovalSuggestion(stepID: step.id, reason: "Pressed while stopping the recording"))
                }
            default:
                continue
            }
        }
        return out
    }
}

// MARK: - Popups

/// A dialog that sometimes gets in the way ("What's New", "Rate this app"),
/// how to recognise it and how to close it. Checked before every step.
/// Idea from OpenAdapt's interstitials (ir.Interstitial, MIT).
public struct PopupRule: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    /// Only checked while this app is in front. nil means any app.
    public var bundleID: String?
    /// Text that must all be on screen for it to count as this popup.
    public var detect: [String]
    public var dismiss: PopupDismiss
    public var created = Date()

    public init(id: UUID = UUID(), name: String, bundleID: String?, detect: [String], dismiss: PopupDismiss,
                created: Date = Date()) {
        self.id = id; self.name = name; self.bundleID = bundleID; self.detect = detect
        self.dismiss = dismiss; self.created = created
    }

    public func matches(_ screen: ScreenState) -> Bool {
        guard !detect.isEmpty else { return false }
        if let bundleID, let front = screen.bundleID, front != bundleID { return false }
        let all = screen.texts.map(\.text) + [screen.windowTitle].compactMap { $0 }
        return detect.allSatisfy { want in
            let key = TextSimilarity.normalize(want)
            return all.contains { StepVerifier.sameText(key, TextSimilarity.normalize($0)) }
        }
    }

    /// Picks up to three texts that identify a popup: ones on screen now that
    /// weren't there when things were normal, stable, and not too long.
    public static func signature(now: ScreenState, normal: ScreenState?) -> [String] {
        let usual = Set((normal?.texts.map(\.text) ?? []).map(TextSimilarity.normalize))
        var picks: [String] = []
        var seen = Set<String>()
        let candidates = [now.windowTitle].compactMap { $0 }.filter { _ in normal?.windowTitle != now.windowTitle }
            + now.texts.map(\.text)
        for t in candidates {
            let key = TextSimilarity.normalize(t)
            guard (3...60).contains(t.count), !usual.contains(key), !seen.contains(key),
                  !Volatility.isVolatile(t) else { continue }
            seen.insert(key)
            picks.append(t)
            if picks.count == 3 { break }
        }
        return picks
    }
}

public enum PopupDismiss: Codable, Equatable {
    case key(code: UInt16, modifiers: UInt64, label: String)
    case click(target: ElementLocator)

    public var summary: String {
        switch self {
        case .key(_, _, let label): return "press \(label)"
        case .click(let t): return "click “\(t.label ?? t.title ?? t.desc ?? "the button")”"
        }
    }
}

// MARK: - Run history

/// What one run did, kept so a run can be looked back on. Holds step
/// summaries and notes only: never typed text or variable values.
/// Shape from MacTape's run records (MIT).
public struct RunRecord: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var started: Date
    public var duration: Double
    public var outcome: String
    public var succeeded: Bool
    public var row: Int?
    public var rows: Int?
    public var steps: [StepRun]

    public struct StepRun: Codable, Equatable {
        public var index: Int
        public var summary: String
        public var note: String?
        public var ran: Bool

        public init(index: Int, summary: String, note: String?, ran: Bool) {
            self.index = index
            self.summary = summary
            self.note = note
            self.ran = ran
        }
    }

    public init(started: Date, duration: Double, outcome: String, succeeded: Bool, row: Int? = nil, rows: Int? = nil,
                steps: [StepRun]) {
        self.started = started; self.duration = duration; self.outcome = outcome; self.succeeded = succeeded
        self.row = row; self.rows = rows; self.steps = steps
    }
}

/// Keeps the last runs of each task in Application Support.
public struct RunHistory {
    public let dir: URL
    public static let keep = 30

    public init(base: URL? = nil) {
        let root = base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = root.appendingPathComponent("Deja Do/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func url(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }

    public func load(_ id: UUID) -> [RunRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(id)) else { return [] }
        return (try? decoder.decode([RunRecord].self, from: data)) ?? []
    }

    public func add(_ r: RunRecord, to id: UUID) {
        var all = load(id)
        all.insert(r, at: 0)
        if all.count > Self.keep { all.removeLast(all.count - Self.keep) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(all) { try? data.write(to: url(id), options: .atomic) }
    }

    public func delete(_ id: UUID) { try? FileManager.default.removeItem(at: url(id)) }
}

extension Step {
    /// A summary safe to keep in logs: typing steps say what field, not what was typed.
    public var safeSummary: String {
        if case .type(let text, let ask, let secret, let prompt) = kind {
            if secret { return prompt.isEmpty ? "Type a password" : prompt }
            if ask { return "Type text asked each run" }
            let vars = Variables.names(in: text)
            if !vars.isEmpty { return "Type " + vars.map { "{{\($0)}}" }.joined(separator: " ") }
            if let field = fieldLabel { return "Type into “\(field)”" }
            return "Type text"
        }
        return summary
    }
}

// MARK: - Goal and finish line

extension Automation {
    /// What the screen should show once the task is done, from the recording:
    /// the last step that changed something checkable.
    public var doneWhen: [String] {
        guard let e = steps.last(where: { $0.isEnabled && ($0.expect?.hasChecks ?? false) })?.expect else { return [] }
        var out: [String] = []
        if let t = e.windowTitle { out.append("the window is titled “\(t)”") }
        for a in e.appeared.prefix(3) where a.typed != true { out.append("“\(a.text)” is on screen") }
        for v in e.vanished.prefix(2) { out.append("“\(v)” is gone") }
        return out
    }
}

// MARK: - Export as an agent skill

/// Writes a task as a SKILL.md that Claude Code, Codex and other agents can
/// follow: run it through Deja Do when it's installed, or do the steps by
/// hand. Never includes typed secrets, positions or pictures.
/// Format idea from open-record-replay.
public enum SkillExport {
    public static func slug(_ name: String) -> String {
        let s = TextSimilarity.tokens(TextSimilarity.normalize(name)).joined(separator: "-")
        return s.isEmpty ? "dejado-task" : String(s.prefix(60))
    }

    public static func markdown(_ a: Automation) -> String {
        let vars = a.variableNames
        let goal = (a.goal?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let description = goal ?? "Repeats the recorded task “\(a.name)”."
        var md = """
        ---
        name: \(slug(a.name))
        description: \(description.replacingOccurrences(of: "\n", with: " "))
        ---

        # \(a.name)

        \(description)

        ## Run it with Deja Do

        If Deja Do is installed on this Mac, run the recorded task instead of doing the steps yourself. It replays exactly, checks each step, and stops safely if something is off:

        ```
        open "dejado://run?task=\(a.id.uuidString)\(vars.map { "&\(urlKey($0))=VALUE" }.joined())"
        ```

        Deja Do asks the person to confirm before running a task requested by another app.

        """
        if !vars.isEmpty {
            md += "\n## Inputs\n\n" + vars.map { "- `\($0)`" }.joined(separator: "\n") + "\n"
        }
        md += "\n## Steps, if you do it by hand\n\n"
        var n = 0
        for (i, step) in a.steps.enumerated() where step.isEnabled {
            n += 1
            var line = "\(n). \(step.safeSummary)"
            if case .click(let t, _, _, _) = step.kind {
                if let w = t.windowTitle, !w.isEmpty, w != t.appName { line += " in \(t.appName), “\(w)”" }
                else { line += " in \(t.appName)" }
                if (t.label ?? "").isEmpty, let near = t.anchors?.first { line += ", near “\(near.label)”" }
            }
            if case .type(let text, _, _, _) = step.kind, !Variables.names(in: text).isEmpty {
                line = "\(n). Type " + text
            }
            if let s = step.expect?.summary { line += ". \(s.replacingOccurrences(of: "Then expects", with: "Afterwards you should see"))" }
            if a.risk(at: i).risk == .risky { line += " **This sends, saves or deletes: do it once only.**" }
            md += line + "\n"
        }
        let done = a.doneWhen
        if !done.isEmpty {
            md += "\n## Done when\n\n" + done.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        md += """

        ## Rules

        - Never repeat a step marked do it once only unless you can see it didn't happen.
        - If the screen doesn't look like the step expects, stop and tell the person instead of guessing.
        - Ask the person for any password; none are stored here.

        """
        return md
    }

    static func urlKey(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
    }
}
