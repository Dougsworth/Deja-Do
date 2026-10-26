import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One moment where finding a step again was not straightforward: a button
/// that had drifted and was healed, a pick the AI made, a spot found from the
/// screen alone, or a search that came up empty.
///
/// These are what let the matcher get better over time. Every automation
/// product that works well has a pile of these behind it; this is where Deja
/// Do's pile starts. Kept locally, exported only when the person asks. Never
/// holds typed text or field contents, only how the controls were described.
public struct RepairRecord: Codable, Equatable {
    public enum Kind: String, Codable, CaseIterable {
        /// A confident but imperfect match refreshed the step.
        case healed
        /// The refresh was refused because it looked like a different control.
        case healRefused
        /// The AI chose among candidates.
        case aiPicked
        /// Found by text and picture on the screen alone.
        case vision
        /// Clicked where it used to be, with nothing better to go on.
        case position
        /// Nothing was found with confidence.
        case notFound
    }

    /// How a control was described, stripped to what matching uses.
    public struct Identity: Codable, Equatable {
        public var role: String
        public var subrole: String?
        public var label: String?
        public var identifier: String?
        public var context: [String]
        public var pathLength: Int
        public var anchors: [String]
        public var frame: CGRect?
        public var windowSize: CGSize?

        public init(role: String, subrole: String? = nil, label: String? = nil, identifier: String? = nil,
                    context: [String] = [], pathLength: Int = 0, anchors: [String] = [], frame: CGRect? = nil,
                    windowSize: CGSize? = nil) {
            self.role = role; self.subrole = subrole
            self.label = label.map { String($0.prefix(60)) }
            self.identifier = identifier.map { String($0.prefix(60)) }
            self.context = context.map { String($0.prefix(40)) }
            self.pathLength = pathLength
            self.anchors = anchors.map { String($0.prefix(40)) }
            self.frame = frame; self.windowSize = windowSize
        }

        public init(_ l: ElementLocator) {
            self.init(role: l.role, subrole: l.subrole, label: l.label, identifier: l.identifier,
                      context: l.context ?? [], pathLength: l.path.count,
                      anchors: (l.anchors ?? []).map(\.label), frame: l.frameInWindow, windowSize: l.windowSize)
        }

        public init(_ s: ElementSnapshot) {
            self.init(role: s.role, subrole: s.subrole, label: s.label, identifier: s.identifier,
                      context: s.context, pathLength: s.path.count, frame: s.frame)
        }
    }

    public var date: Date
    public var app: String
    public var kind: Kind
    public var recorded: Identity
    public var found: Identity?
    /// The matcher's per signal scores for what was found, 0...1 each.
    public var signals: [String: Double]
    public var score: Double
    public var accepted: Bool
    public var risky: Bool
    public var note: String?

    public init(date: Date = Date(), app: String, kind: Kind, recorded: Identity, found: Identity? = nil,
                signals: [String: Double] = [:], score: Double = 0, accepted: Bool, risky: Bool = false,
                note: String? = nil) {
        self.date = date; self.app = app; self.kind = kind; self.recorded = recorded; self.found = found
        self.signals = signals; self.score = score; self.accepted = accepted; self.risky = risky
        self.note = note.map { String($0.prefix(200)) }
    }
}

/// Appends repair records to one file, one JSON object per line, and keeps
/// it from growing without end.
public final class RepairCorpus: @unchecked Sendable {
    public let url: URL
    public static let keep = 5000
    public let keep: Int
    private var sinceTrim = 0
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public init(base: URL? = nil, keep: Int = RepairCorpus.keep) {
        let root = base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = root.appendingPathComponent("Deja Do", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("repairs.jsonl")
        self.keep = keep
    }

    public func add(_ r: RepairRecord) {
        guard let line = try? encoder.encode(r) else { return }
        lock.lock(); defer { lock.unlock() }
        if let h = FileHandle(forWritingAtPath: url.path) {
            h.seekToEndOfFile()
            h.write(line + Data("\n".utf8))
            h.closeFile()
        } else {
            try? (line + Data("\n".utf8)).write(to: url, options: .atomic)
        }
        sinceTrim += 1
        if sinceTrim >= 50 { sinceTrim = 0; trimIfNeeded() }
    }

    public func load() -> [RepairRecord] {
        lock.lock(); defer { lock.unlock() }
        return readAll()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    /// A readable summary for the person: how often each kind happened, per app.
    public func summary() -> String {
        let all = load()
        guard !all.isEmpty else { return "No repairs recorded yet." }
        var byKind: [RepairRecord.Kind: Int] = [:]
        var apps = Set<String>()
        for r in all { byKind[r.kind, default: 0] += 1; apps.insert(r.app) }
        let parts = RepairRecord.Kind.allCases.compactMap { k -> String? in
            guard let n = byKind[k], n > 0 else { return nil }
            return "\(n) \(Self.name(k))"
        }
        return "\(all.count) records across \(apps.count) app\(apps.count == 1 ? "" : "s"): " + parts.joined(separator: ", ") + "."
    }

    public static func name(_ k: RepairRecord.Kind) -> String {
        switch k {
        case .healed: return "healed"
        case .healRefused: return "refused"
        case .aiPicked: return "AI picks"
        case .vision: return "found on screen"
        case .position: return "by position"
        case .notFound: return "not found"
        }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    private func readAll() -> [RepairRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(RepairRecord.self, from: $0) }
    }

    private func trimIfNeeded() {
        guard let data = try? Data(contentsOf: url) else { return }
        let lines = data.split(separator: 0x0A)
        guard lines.count > keep + keep / 10 else { return }
        let kept = lines.suffix(keep).map { Data($0) }.joined(separator: Data("\n".utf8)) + Data("\n".utf8)
        try? kept.write(to: url, options: .atomic)
    }
}

private extension Array where Element == Data {
    func joined(separator: Data) -> Data {
        var out = Data()
        for (i, d) in enumerated() {
            if i > 0 { out.append(separator) }
            out.append(d)
        }
        return out
    }
}
