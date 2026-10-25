import Foundation

/// A task saved to a `.dejado` file so it can move to another Mac or person.
///
/// Exported files carry the steps only: run counts, timings and anything
/// typed into a step marked "ask each run" or "password" are left out.
/// Imported tasks get fresh IDs so the same file can be imported twice.
public struct TaskFile: Codable {
    public static let formatName = "dejado-task"
    public static let currentVersion = 1
    public static let fileExtension = "dejado"

    public var format: String
    public var version: Int
    public var exported: Date
    public var automation: Automation

    public enum Failure: LocalizedError, Equatable {
        case notATask
        case newerVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .notATask: return "That file isn't a Deja Do task."
            case .newerVersion(let v): return "That task was saved by a newer Deja Do (format \(v)). Update the app to open it."
            }
        }
    }

    public static func encode(_ a: Automation, at date: Date = Date()) throws -> Data {
        var clean = a
        clean.runs = 0
        clean.repairs = 0
        clean.lastRun = nil
        clean.lastSucceeded = nil
        clean.lastDuration = nil
        for i in clean.steps.indices {
            if case .type(_, let ask, let secret, let prompt) = clean.steps[i].kind, ask || secret {
                clean.steps[i].kind = .type(text: "", askEachRun: ask, secret: secret, prompt: prompt)
            }
        }
        let file = TaskFile(format: formatName, version: currentVersion, exported: date, automation: clean)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(file)
    }

    public static func decode(_ data: Data, now: Date = Date()) throws -> Automation {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(TaskFile.self, from: data), file.format == formatName else {
            throw Failure.notATask
        }
        guard file.version <= currentVersion else { throw Failure.newerVersion(file.version) }
        var a = file.automation
        a.id = UUID()
        a.created = now
        a.steps = a.steps.map { Step(id: UUID(), kind: $0.kind) }
        return a
    }
}
