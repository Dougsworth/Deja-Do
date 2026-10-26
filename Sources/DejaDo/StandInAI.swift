import Foundation
import Network
@preconcurrency import DejaDoCore

/// An AI service for the self test, answering the way Ollama does. It reads
/// the real question Deja Do sends and picks the way a sensible model would
/// for the test page: a button whose label means the same as the recorded
/// one. So everything about AI repair runs for real (the question, the reply,
/// asking the person, learning from it) without a paid model or a network.
final class StandInAI: @unchecked Sendable {
    enum Mode { case sensible, refuses }

    /// Labels that mean the same, as a model would know.
    static let sameMeaning: [String: Set<String>] = [
        "submit": ["send", "mandar", "enviar", "submit request", "send request"]
    ]

    private let lock = NSLock()
    private var _calls = 0
    private var _prompts: [String] = []
    var mode: Mode = .sensible
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var lastPrompt: String? { lock.lock(); defer { lock.unlock() }; return _prompts.last }
    func reset() { lock.lock(); _calls = 0; _prompts = []; lock.unlock() }

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    var baseURL: String { "http://127.0.0.1:\(port)" }

    func start() -> Bool {
        guard let l = try? NWListener(using: { let p = NWParameters.tcp; p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any); return p }()) else { return false }
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { [weak self] s in
            if case .ready = s { self?.port = l.port?.rawValue ?? 0; ready.signal() }
            if case .failed = s { ready.signal() }
        }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.start(queue: DispatchQueue(label: "dejado.standin-ai"))
        listener = l
        _ = ready.wait(timeout: .now() + 3)
        return port != 0
    }

    func stop() { listener?.cancel(); listener = nil }

    private func serve(_ c: NWConnection) {
        c.start(queue: DispatchQueue(label: "dejado.standin-ai.conn"))
        var buffer = Data()
        func readMore() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
                guard let self else { c.cancel(); return }
                if let data { buffer.append(data) }
                if error != nil { c.cancel(); return }
                switch HTTPRequest.parse(buffer) {
                case .incomplete: if done { c.cancel() } else { readMore() }
                case .request(let r): self.send(self.answer(r), on: c)
                default: self.send(.error(400, "bad request"), on: c)
                }
            }
        }
        readMore()
    }

    private func send(_ r: HTTPResponse, on c: NWConnection) {
        c.send(content: r.serialized, completion: .contentProcessed { _ in c.cancel() })
    }

    private func answer(_ r: HTTPRequest) -> HTTPResponse {
        guard r.path == "/api/chat",
              let body = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any],
              let messages = body["messages"] as? [[String: Any]],
              let prompt = messages.last?["content"] as? String else { return .error(404, "not found") }
        lock.lock(); _calls += 1; _prompts.append(prompt); lock.unlock()
        let (index, reason) = mode == .refuses ? (-1, "nothing here does that") : Self.choose(prompt)
        let content = "{\"index\": \(index), \"reason\": \"\(reason)\"}"
        return .json(200, ["model": body["model"] ?? "stand-in", "message": ["role": "assistant", "content": content], "done": true])
    }

    /// Reads the recorded label and the numbered candidate lines out of the question.
    static func choose(_ prompt: String) -> (Int, String) {
        func label(in line: Substring) -> String? {
            guard let r = line.range(of: "label=\"") else { return nil }
            let rest = line[r.upperBound...]
            return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
        }
        let lines = prompt.split(separator: "\n")
        guard let recordedLine = lines.firstIndex(where: { $0.hasPrefix("Recorded element:") }).map({ lines[min($0 + 1, lines.count - 1)] }),
              let wanted = label(in: recordedLine)?.lowercased() else { return (-1, "no label to go on") }
        let meanings = (sameMeaning[wanted] ?? []).union([wanted])
        for line in lines {
            let parts = line.split(separator: "|", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, let i = Int(parts[0]), parts[1] == "Button",
                  let l = label(in: line)?.lowercased(), meanings.contains(l) else { continue }
            return (i, "“\(l)” does the same as “\(wanted)”")
        }
        return (-1, "nothing means “\(wanted)”")
    }
}
