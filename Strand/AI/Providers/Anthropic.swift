import Foundation
import StrandAnalytics

struct AnthropicClient: AIProviderClient {

    func send(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) async throws -> String {
        var wire: [[String: Any]] = []
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

        // Anthropic: system prompt is a top-level field, not a message role.
        var body: [String: Any] = [
            "model": model,
            // #1074: 900 truncated detailed coaching replies mid-sentence; 4096 lets a full multi-section
            // reply complete (a cap, not a target — the system prompt keeps it short). Matches the others.
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": wire
        ]
        Self.applyModelSettings(&body, model: model)

        var req = URLRequest(url: AIProvider.anthropic.endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await performRequest(req, session: session)
        // sfz: newer Claude models can start with a `thinking` block, so join every `text` block
        // instead of reading the first one.
        let joined = (json["content"] as? [[String: Any]] ?? [])
            .filter { ($0["type"] as? String ?? "text") == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        let text = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw emptyReplyError(json)   // #1074: surface the provider's real error if the 200 body has one
        }
        return text
    }

    /// K1: Stream via `stream: true`. Anthropic SSE uses typed events; we extract `content_block_delta`
    /// with `text_delta` via `SseDeltas.anthropicDelta`. Byte-parity pin in
    /// `SseDeltasTests.anthropicReassembleMatchesFullReply`.
    func stream(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession,
        onDelta: (String) -> Void
    ) async throws {
        var wire: [[String: Any]] = []
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": wire,
            "stream": true
        ]
        Self.applyModelSettings(&body, model: model)

        var req = URLRequest(url: AIProvider.anthropic.endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        // sfz: an `error` event mid-stream (e.g. overloaded) used to end silently as "(no reply)".
        var streamError: String?
        var gotText = false
        var stopReason: String?
        try await performStreamingRequest(req, session: session) { payload in
            if let delta = SseDeltas.anthropicDelta(payload) {
                gotText = true
                onDelta(delta)
            } else if let data = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if obj["type"] as? String == "error" {
                    let err = obj["error"] as? [String: Any]
                    streamError = (err?["message"] as? String) ?? "The provider ended the reply with an error."
                } else if obj["type"] as? String == "message_delta",
                          let d = obj["delta"] as? [String: Any], let r = d["stop_reason"] as? String {
                    stopReason = r
                }
            }
        }
        if let streamError, !gotText { throw AICoachError.server(500, streamError) }
        if !gotText, stopReason == "refusal" {
            throw AICoachError.server(400, "Claude declined to answer that one. Try asking it another way.")
        }
        if !gotText, stopReason == "max_tokens" {
            throw AICoachError.server(400, "The model ran out of room before answering. Try a shorter question or another model.")
        }
    }

    /// sfz: Claude 5-generation models think by default at high effort, and that thinking counts
    /// against `max_tokens`, so a 4096 cap could be spent before any answer text. Keep thinking
    /// short and leave room for the reply. Older models are sent exactly as before.
    static func isFiveGeneration(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.hasPrefix("claude-fable") || m.hasPrefix("claude-mythos")
            || m.range(of: #"^claude-(opus|sonnet|haiku)-5"#, options: .regularExpression) != nil
    }

    static func applyModelSettings(_ body: inout [String: Any], model: String) {
        guard isFiveGeneration(model) else { return }
        body["max_tokens"] = 16000
        body["thinking"] = ["type": "adaptive"]
        body["output_config"] = ["effort": "low"]
    }

    func fetchModels(key: String, session: URLSession) async throws -> [String] {
        // sfz: ask for the whole catalogue; the default page is only 20 models.
        var comps = URLComponents(url: AIProvider.anthropic.modelsEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "limit", value: "1000")]
        var req = URLRequest(url: comps.url ?? AIProvider.anthropic.modelsEndpoint)
        req.httpMethod = "GET"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        return parseModels(try await performRequest(req, session: session))
    }

    /// Pure: unwrap the `/models` body into ids (Anthropic keeps all non-empty). No network — unit-tested.
    func parseModels(_ json: [String: Any]) -> [String] {
        guard let list = json["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return id
        }
    }
}
