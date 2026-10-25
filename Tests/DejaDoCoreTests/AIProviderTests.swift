import XCTest
@testable import DejaDoCore

final class AIProviderTests: XCTestCase {
    private func body(_ call: HTTPCall) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: call.body) as? [String: Any]) ?? [:]
    }

    func testAnthropicRequest() throws {
        let call = try AIRequest.build(AIConfig(provider: .anthropic, model: "claude-haiku-5-5", key: "k"),
                                       system: "sys", prompt: "hi", maxTokens: 300)
        XCTAssertEqual(call.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(call.headers["x-api-key"], "k")
        XCTAssertEqual(call.headers["anthropic-version"], "2023-06-01")
        let b = body(call)
        XCTAssertEqual(b["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(b["system"] as? String, "sys")
        XCTAssertEqual(b["max_tokens"] as? Int, 300)
    }

    func testOpenAIRequest() throws {
        let call = try AIRequest.build(AIConfig(provider: .openai, model: "gpt-6-luna", key: "k"), system: "sys", prompt: "hi")
        XCTAssertEqual(call.url.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(call.headers["authorization"], "Bearer k")
        let b = body(call)
        XCTAssertEqual((b["messages"] as? [[String: Any]])?.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual((b["response_format"] as? [String: Any])?["type"] as? String, "json_object")
        XCTAssertNotNil(b["max_completion_tokens"])
    }

    func testGeminiRequest() throws {
        let call = try AIRequest.build(AIConfig(provider: .gemini, model: "gemini-3.8-flash", key: "k"), system: "sys", prompt: "hi")
        XCTAssertEqual(call.url.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent")
        XCTAssertEqual(call.headers["x-goog-api-key"], "k")
        XCTAssertFalse(call.url.absoluteString.contains("key="), "the key goes in a header, never the URL")
        let config = body(call)["generationConfig"] as? [String: Any]
        XCTAssertEqual(config?["responseMimeType"] as? String, "application/json")
    }

    func testOllamaUsesTheMacByDefault() throws {
        let call = try AIRequest.build(AIConfig(provider: .ollama, model: "llama4:8b"), system: "s", prompt: "p")
        XCTAssertEqual(call.url.absoluteString, "http://localhost:11434/api/chat")
        XCTAssertNil(call.headers["authorization"])
        XCTAssertEqual(body(call)["stream"] as? Bool, false)
        let other = try AIRequest.build(AIConfig(provider: .ollama, model: "m", baseURL: "http://studio.local:11434/"),
                                        system: "s", prompt: "p")
        XCTAssertEqual(other.url.absoluteString, "http://studio.local:11434/api/chat")
    }

    func testDejaDoServerRequest() throws {
        let c = AIConfig(provider: .dejaDo, model: "gpt-6-luna", key: "code", baseURL: "https://ai.example.com//")
        let call = try AIRequest.build(c, system: "s", prompt: "p")
        XCTAssertEqual(call.url.absoluteString, "https://ai.example.com/v1/choose")
        XCTAssertEqual(call.headers["authorization"], "Bearer code")
        XCTAssertEqual(body(call)["model"] as? String, "gpt-6-luna")
        XCTAssertThrowsError(try AIRequest.build(AIConfig(provider: .dejaDo, model: "m", key: "c", baseURL: "not a url"),
                                                 system: "s", prompt: "p"))
    }

    func testReadsEachProvidersReply() throws {
        let replies: [(AIProvider, String)] = [
            (.anthropic, #"{"content":[{"type":"text","text":"{\"index\":2}"}]}"#),
            (.openai, #"{"choices":[{"message":{"role":"assistant","content":"{\"index\":2}"}}]}"#),
            (.gemini, #"{"candidates":[{"content":{"parts":[{"text":"thinking","thought":true},{"text":"{\"index\":2}"}]}}]}"#),
            (.ollama, #"{"message":{"role":"assistant","content":"{\"index\":2}"},"done":true}"#),
            (.dejaDo, #"{"text":"{\"index\":2}"}"#)
        ]
        struct Pick: Decodable { let index: Int }
        for (provider, json) in replies {
            let text = try AIRequest.text(from: Data(json.utf8), status: 200, provider: provider)
            XCTAssertEqual(try AIRequest.jsonObject(Pick.self, in: text).index, 2, provider.rawValue)
        }
    }

    func testErrorsSayWhatWentWrong() {
        let data = Data(#"{"error":{"message":"invalid x-api-key"}}"#.utf8)
        XCTAssertThrowsError(try AIRequest.text(from: data, status: 401, provider: .anthropic)) { e in
            XCTAssertEqual(e as? AIRequestError, .failed(status: 401, message: "invalid x-api-key"))
            XCTAssertTrue(e.localizedDescription.contains("Check the key"))
        }
        let server = Data(#"{"error":"Daily limit reached"}"#.utf8)
        XCTAssertThrowsError(try AIRequest.text(from: server, status: 429, provider: .dejaDo)) { e in
            XCTAssertEqual(e as? AIRequestError, .failed(status: 429, message: "Daily limit reached"))
        }
    }

    func testJSONIsFoundInsideChatter() throws {
        struct Pick: Decodable { let index: Int; let reason: String? }
        let p = try AIRequest.jsonObject(Pick.self, in: "Sure! ```json\n{\"index\": 4, \"reason\": \"Send\"}\n```")
        XCTAssertEqual(p.index, 4)
        XCTAssertThrowsError(try AIRequest.jsonObject(Pick.self, in: "no idea"))
    }

    func testConfigProblems() {
        XCTAssertNil(AIConfig(provider: .anthropic, model: "claude-sonnet-5-5", key: "k").problem)
        XCTAssertNotNil(AIConfig(provider: .openai, model: "gpt-6-luna", key: " ").problem)
        XCTAssertNil(AIConfig(provider: .ollama, model: "llama4").problem, "Ollama needs no key")
        XCTAssertEqual(AIConfig(provider: .ollama, model: "").problem, "Pick an Ollama model in Settings.")
        XCTAssertNotNil(AIConfig(provider: .dejaDo, model: "m", key: "c").problem, "needs the server address")
    }

    func testServerRoutesModelsToTheRightCompany() {
        XCTAssertEqual(AICatalog.vendor(ofModel: "gpt-6.1-sol"), .openai)
        XCTAssertEqual(AICatalog.vendor(ofModel: "gemini-4-argon"), .gemini)
        XCTAssertEqual(AICatalog.vendor(ofModel: "claude-opus-5-5"), .anthropic)
        let viaServer = AICatalog.models(for: .dejaDo).map(\.id)
        XCTAssertTrue(viaServer.contains("gpt-6-luna") && viaServer.contains("gemini-3.8-flash"))
        for p in AIProvider.allCases where p != .ollama {
            XCTAssertTrue(AICatalog.models(for: p).map(\.id).contains(AICatalog.defaultModel(for: p)), p.rawValue)
        }
    }

    func testOllamaModelList() {
        let data = Data(#"{"models":[{"name":"qwen3:8b"},{"name":"llama4:8b"}]}"#.utf8)
        XCTAssertEqual(AIRequest.ollamaModels(from: data), ["llama4:8b", "qwen3:8b"])
        XCTAssertEqual(AIRequest.ollamaModels(from: Data("nope".utf8)), [])
    }
}
