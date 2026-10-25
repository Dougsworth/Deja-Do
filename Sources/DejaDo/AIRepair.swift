import Foundation
import CoreGraphics
@preconcurrency import DejaDoCore

/// When the engine isn't sure, ask an AI model which element the user meant.
/// Only a text list of the window's elements is sent, never a screenshot
/// and never anything the user typed.
struct AIRepair {
    let config: AIConfig

    struct Choice: Decodable {
        let index: Int
        let reason: String?
    }

    /// - Parameter shortlist: candidates with the engine's score, best first.
    func choose(target l: ElementLocator, shortlist: [(snapshot: ElementSnapshot, score: Double)]) async throws -> Choice {
        var lines: [String] = []
        for (i, item) in shortlist.enumerated() {
            let n = item.snapshot
            var parts = ["\(i)", n.role.replacingOccurrences(of: "AX", with: "")]
            if let x = n.label { parts.append("label=\"\(x.prefix(70))\"") }
            if let x = n.title, x != n.label { parts.append("title=\"\(x.prefix(50))\"") }
            if let x = n.desc, x != n.label { parts.append("desc=\"\(x.prefix(50))\"") }
            if let x = n.identifier { parts.append("id=\(x.prefix(40))") }
            if let f = n.frame { parts.append("at=\(Int(f.midX)),\(Int(f.midY))") }
            if let c = n.context.first { parts.append("in=\"\(c.prefix(30))\"") }
            parts.append("similarity=\(String(format: "%.2f", item.score))")
            lines.append(parts.joined(separator: " | "))
        }

        var wanted: [String] = ["role=\(l.role.replacingOccurrences(of: "AX", with: ""))"]
        if let x = l.label { wanted.append("label=\"\(x)\"") }
        if let x = l.title { wanted.append("title=\"\(x)\"") }
        if let x = l.desc { wanted.append("desc=\"\(x)\"") }
        if let x = l.identifier { wanted.append("id=\(x)") }
        if let x = l.help { wanted.append("help=\"\(x)\"") }
        if let f = l.frameInWindow { wanted.append("was at=\(Int(f.midX)),\(Int(f.midY))") }
        if let w = l.windowTitle { wanted.append("window=\"\(w)\"") }
        if let c = l.context, !c.isEmpty { wanted.append("in=\"\(c.joined(separator: " › "))\"") }
        for a in l.anchors ?? [] {
            wanted.append("near \"\(a.label.prefix(40))\" (\(Self.direction(a.offset)))")
        }

        let prompt = """
        A user recorded clicking an element in the Mac app \(l.appName). The app's layout has since \
        changed, so the recorded element can't be found with confidence. Pick the element in the current \
        window that does the same job.

        Recorded element:
        \(wanted.joined(separator: " | "))

        Current elements (index | role | attributes | position relative to the window | how similar \
        a matching algorithm thinks it is, 0 to 1):
        \(lines.joined(separator: "\n"))

        Reply with only JSON: {"index": <number>, "reason": "<short reason>"}.
        Use {"index": -1, "reason": "..."} if nothing listed is a reasonable match. \
        Prefer a matching meaning over a matching position. The similarity score is a hint, not the answer.
        """

        let system = "You help a Mac automation tool find UI elements. You answer with JSON only."
        let call = try AIRequest.build(config, system: system, prompt: prompt)
        var request = URLRequest(url: call.url)
        request.httpMethod = "POST"
        // Models on the Mac can take a while to load the first time.
        request.timeoutInterval = config.provider == .ollama ? 120 : 45
        for (k, v) in call.headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = call.body

        let reply: (Data, URLResponse)
        do {
            reply = try await URLSession.shared.data(for: request)
        } catch {
            if config.provider == .ollama {
                throw ReplayError("Couldn't reach Ollama. Is it running? (\(error.localizedDescription))")
            }
            throw ReplayError("Couldn't reach \(config.provider.name): \(error.localizedDescription)")
        }
        let status = (reply.1 as? HTTPURLResponse)?.statusCode ?? 0
        do {
            let text = try AIRequest.text(from: reply.0, status: status, provider: config.provider)
            return try AIRequest.jsonObject(Choice.self, in: text)
        } catch let e as AIRequestError {
            throw ReplayError(e.localizedDescription)
        }
    }

    static func direction(_ offset: CGPoint) -> String {
        if abs(offset.x) >= abs(offset.y) { return offset.x > 0 ? "to its right" : "to its left" }
        return offset.y > 0 ? "below it" : "above it"
    }
}

struct ReplayError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
