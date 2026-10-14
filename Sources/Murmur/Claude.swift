import Foundation

enum ClaudeError: LocalizedError {
    case missingKey
    case refused
    case api(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Add an Anthropic API key in Settings → AI."
        case .refused: return "Claude declined this request."
        case .api(let status, let message): return "Claude API error \(status): \(message)"
        case .emptyResponse: return "Claude returned no text."
        }
    }
}

/// Minimal Messages API client over URLSession (Swift has no official SDK).
struct ClaudeClient {
    var apiKey: String
    var model: String
    /// "low" keeps dictation snappy; raise it for heavier rewrites.
    var effort: String

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// Models that accept server-side refusal fallbacks (`fallbacks: "default"`).
    private static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-fable-5-1"]

    func complete(system: String, user: String, timeout: TimeInterval = 45) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "output_config": ["effort": effort],
        ]
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if Self.fallbackModels.contains(model) {
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request, attemptsLeft: 2)
    }

    private func send(_ request: URLRequest, attemptsLeft: Int) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard (200..<300).contains(status) else {
            if [429, 500, 502, 503, 504, 529].contains(status), attemptsLeft > 1 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return try await send(request, attemptsLeft: attemptsLeft - 1)
            }
            let message = (json?["error"] as? [String: Any])?["message"] as? String ?? "no details"
            throw ClaudeError.api(status, message)
        }
        if json?["stop_reason"] as? String == "refusal" {
            throw ClaudeError.refused
        }
        let blocks = json?["content"] as? [[String: Any]] ?? []
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClaudeError.emptyResponse }
        return text
    }
}
