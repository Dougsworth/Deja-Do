import Foundation

/// Keeps the learned match weights for each app on disk.
public struct WeightStore {
    public let url: URL

    /// - Parameter base: override for tests. Defaults to Application Support.
    public init(base: URL? = nil) {
        let root = base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = root.appendingPathComponent("Deja Do", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("match-weights.json")
    }

    public func load() -> [String: MatchWeights] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: MatchWeights].self, from: data) else { return [:] }
        return decoded
    }

    public func save(_ weights: [String: MatchWeights]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(weights) { try? data.write(to: url, options: .atomic) }
    }
}
