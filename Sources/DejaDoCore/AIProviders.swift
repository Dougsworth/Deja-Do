import Foundation

/// Where an AI request goes.
public enum AIProvider: String, Codable, CaseIterable {
    /// Your own Deja Do server, which holds the real keys. Testers only need an access code.
    case dejaDo
    case anthropic
    case openai
    case gemini
    /// Models running on this Mac through Ollama. Free and nothing leaves the Mac.
    case ollama

    public var name: String {
        switch self {
        case .dejaDo: return "Deja Do"
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .ollama: return "Ollama (on this Mac)"
        }
    }

    /// Keychain account for this provider's key or access code.
    public var keychainAccount: String? {
        switch self {
        case .dejaDo: return "dejado-access"
        case .anthropic: return "anthropic"
        case .openai: return "openai"
        case .gemini: return "gemini"
        case .ollama: return nil
        }
    }

    public var keyLabel: String {
        switch self {
        case .dejaDo: return "Access code"
        case .anthropic, .openai, .gemini: return "\(name) API key"
        case .ollama: return ""
        }
    }

    public var keyPlaceholder: String {
        switch self {
        case .dejaDo: return "Code from whoever invited you"
        case .anthropic: return "sk-ant-…"
        case .openai: return "sk-…"
        case .gemini: return "AIza…"
        case .ollama: return ""
        }
    }

    public var needsKey: Bool { self != .ollama }
}

public struct AIModel: Equatable, Hashable {
    public let id: String
    public let name: String
    public let note: String

    public init(_ id: String, _ name: String, _ note: String) {
        self.id = id
        self.name = name
        self.note = note
    }
}

public enum AICatalog {
    /// Models offered for each provider, quickest first. Ollama's come from the Mac itself.
    public static func models(for provider: AIProvider) -> [AIModel] {
        switch provider {
        case .anthropic, .dejaDo:
            return [
                AIModel("claude-haiku-5-5", "Claude Haiku 5.5", "Fastest and cheapest. Fine for most fixes."),
                AIModel("claude-sonnet-5-5", "Claude Sonnet 5.5", "A good balance of speed and judgement."),
                AIModel("claude-opus-5-5", "Claude Opus 5.5", "Most careful, slowest and most expensive.")
            ] + (provider == .dejaDo ? models(for: .openai) + models(for: .gemini) : [])
        case .openai:
            return [
                AIModel("gpt-6-luna", "GPT-6 Luna", "OpenAI's small, quick model."),
                AIModel("gpt-6.1-sol", "GPT-6.1 Sol", "OpenAI's main model.")
            ]
        case .gemini:
            return [
                AIModel("gemini-3.5-flash-lite", "Gemini 3.5 Flash Lite", "Google's quickest and cheapest."),
                AIModel("gemini-3.8-flash", "Gemini 3.8 Flash", "Quick, with better judgement."),
                AIModel("gemini-4-argon", "Gemini 4 Argon", "Google's most capable.")
            ]
        case .ollama:
            return []
        }
    }

    public static func defaultModel(for provider: AIProvider) -> String {
        switch provider {
        case .anthropic, .dejaDo: return "claude-sonnet-5-5"
        case .openai: return "gpt-6-luna"
        case .gemini: return "gemini-3.8-flash"
        case .ollama: return ""
        }
    }

    /// Which company actually runs a model, so the Deja Do server knows where to send it.
    public static func vendor(ofModel id: String) -> AIProvider {
        if id.hasPrefix("gpt") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") { return .openai }
        if id.hasPrefix("gemini") { return .gemini }
        return .anthropic
    }
}

/// Everything needed to send one request.
public struct AIConfig: Equatable {
    public var provider: AIProvider
    public var model: String
    /// API key, or the access code for the Deja Do server.
    public var key: String
    /// Deja Do server address, or Ollama's when it isn't the usual one.
    public var baseURL: String?

    public init(provider: AIProvider, model: String, key: String = "", baseURL: String? = nil) {
        self.provider = provider
        self.model = model
        self.key = key
        self.baseURL = baseURL
    }

    /// Why this setup can't send anything yet, or nil when it's ready.
    public var problem: String? {
        if model.trimmingCharacters(in: .whitespaces).isEmpty {
            return provider == .ollama ? "Pick an Ollama model in Settings." : "Pick a model in Settings."
        }
        if provider.needsKey && key.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Add your \(provider.keyLabel.lowercased()) in Settings to let AI look for it."
        }
        if provider == .dejaDo && (baseURL ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return "Add the Deja Do server address in Settings."
        }
        return nil
    }
}

/// A provider neutral HTTP request, so it can be built and tested without URLSession.
public struct HTTPCall: Equatable {
    public var url: URL
    public var headers: [String: String]
    public var body: Data
}

public enum AIRequestError: LocalizedError, Equatable {
    case badAddress(String)
    case failed(status: Int, message: String)
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .badAddress(let a): return "“\(a)” isn't a valid address."
        case .failed(let status, let message):
            switch status {
            case 401, 403: return "AI request was refused (\(status)). Check the key or access code in Settings. \(message)"
            case 429: return "AI request limit reached (429). \(message)"
            default: return "AI request failed (\(status)): \(message)"
            }
        case .unreadable: return "AI gave an answer Deja Do couldn't read."
        }
    }
}

/// Builds requests for each provider and reads their replies.
public enum AIRequest {
    public static let ollamaDefault = "http://localhost:11434"

    public static func build(_ c: AIConfig, system: String, prompt: String, maxTokens: Int = 1500) throws -> HTTPCall {
        func json(_ o: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) }
        func url(_ s: String) throws -> URL {
            guard let u = URL(string: s), let scheme = u.scheme, ["http", "https"].contains(scheme), u.host != nil else {
                throw AIRequestError.badAddress(s)
            }
            return u
        }
        let jsonHeader = ["content-type": "application/json"]

        switch c.provider {
        case .anthropic:
            return HTTPCall(
                url: try url("https://api.anthropic.com/v1/messages"),
                headers: jsonHeader.merging(["x-api-key": c.key, "anthropic-version": "2023-06-01"]) { $1 },
                body: try json(["model": c.model, "max_tokens": maxTokens, "system": system,
                                "messages": [["role": "user", "content": prompt]]]))
        case .openai:
            return HTTPCall(
                url: try url("https://api.openai.com/v1/chat/completions"),
                headers: jsonHeader.merging(["authorization": "Bearer \(c.key)"]) { $1 },
                body: try json(["model": c.model, "max_completion_tokens": maxTokens,
                                "response_format": ["type": "json_object"],
                                "messages": [["role": "system", "content": system],
                                             ["role": "user", "content": prompt]]]))
        case .gemini:
            let model = c.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? c.model
            return HTTPCall(
                url: try url("https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"),
                headers: jsonHeader.merging(["x-goog-api-key": c.key]) { $1 },
                body: try json(["systemInstruction": ["parts": [["text": system]]],
                                "contents": [["role": "user", "parts": [["text": prompt]]]],
                                "generationConfig": ["responseMimeType": "application/json",
                                                     "maxOutputTokens": maxTokens]]))
        case .ollama:
            let base = trimmedBase(c.baseURL) ?? ollamaDefault
            return HTTPCall(
                url: try url(base + "/api/chat"),
                headers: jsonHeader,
                body: try json(["model": c.model, "stream": false, "format": "json",
                                "messages": [["role": "system", "content": system],
                                             ["role": "user", "content": prompt]]]))
        case .dejaDo:
            guard let base = trimmedBase(c.baseURL) else { throw AIRequestError.badAddress(c.baseURL ?? "") }
            return HTTPCall(
                url: try url(base + "/v1/choose"),
                headers: jsonHeader.merging(["authorization": "Bearer \(c.key)"]) { $1 },
                body: try json(["model": c.model, "system": system, "prompt": prompt, "maxTokens": maxTokens]))
        }
    }

    /// The model's text from a reply, or a clear error for a failed one.
    public static func text(from data: Data, status: Int, provider: AIProvider) throws -> String {
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status) else {
            throw AIRequestError.failed(status: status, message: errorMessage(obj, data))
        }
        guard let obj else { throw AIRequestError.unreadable }
        let text: String?
        switch provider {
        case .anthropic:
            text = (obj["content"] as? [[String: Any]])?
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined()
        case .openai:
            text = ((obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        case .gemini:
            text = (((obj["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]])?
                .compactMap { $0["thought"] as? Bool == true ? nil : $0["text"] as? String }
                .joined()
        case .ollama:
            text = (obj["message"] as? [String: Any])?["content"] as? String
        case .dejaDo:
            text = obj["text"] as? String
        }
        guard let text, !text.isEmpty else { throw AIRequestError.unreadable }
        return text
    }

    /// The first JSON object in a reply, ignoring any words or code fences around it.
    public static func jsonObject<T: Decodable>(_ type: T.Type, in text: String) throws -> T {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw AIRequestError.unreadable
        }
        do { return try JSONDecoder().decode(T.self, from: Data(text[start...end].utf8)) }
        catch { throw AIRequestError.unreadable }
    }

    static func errorMessage(_ obj: [String: Any]?, _ data: Data) -> String {
        if let e = obj?["error"] as? [String: Any], let m = e["message"] as? String { return String(m.prefix(200)) }
        if let m = obj?["error"] as? String { return String(m.prefix(200)) }
        return String((String(data: data, encoding: .utf8) ?? "").prefix(200))
    }

    static func trimmedBase(_ s: String?) -> String? {
        guard var b = s?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty else { return nil }
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }

    /// Model names from Ollama's /api/tags reply.
    public static func ollamaModels(from data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["models"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["name"] as? String }.sorted()
    }
}
