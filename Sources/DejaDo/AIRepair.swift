import Foundation
import CoreGraphics
import DejaDoCore

/// When the engine isn't sure, ask Claude which element the user meant.
/// Only a text list of the window's elements is sent, never a screenshot
/// and never anything the user typed.
struct AIRepair {
    let apiKey: String
    let model: String

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

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 300,
            "system": "You help a Mac automation tool find UI elements. You answer with JSON only.",
            "messages": [["role": "user", "content": prompt]]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ReplayError("AI request failed (\(status)): \(text.prefix(200))")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            throw ReplayError("AI gave an answer Deja Do couldn't read.")
        }
        return try JSONDecoder().decode(Choice.self, from: Data(text[start...end].utf8))
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
