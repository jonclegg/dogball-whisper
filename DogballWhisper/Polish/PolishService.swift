import Foundation

enum PolishError: LocalizedError, Equatable {
    case missingAPIKey
    case emptyResponse
    case http(Int, String)
    case requiresReasoning(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your OpenRouter API key in Settings."
        case .emptyResponse:
            return "The cleanup model returned nothing."
        case let .http(code, body):
            return "OpenRouter error \(code): \(body)"
        case let .requiresReasoning(model):
            return "\(model) always thinks before answering, which is too slow for dictation. Choose another model in Settings."
        }
    }
}

/// Strips disfluencies from a transcript via OpenRouter. The coordinator treats
/// every error here as "insert the raw transcript", so this type is free to
/// throw rather than paper over failures.
final class PolishService: TextCleaning {
    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        struct Reasoning: Encodable {
            let enabled: Bool
        }
        let model: String
        let messages: [Message]
        let temperature: Double
        /// Cleanup needs no thinking tokens; they only add latency. Every
        /// model this app offers accepts having it turned off — that is a
        /// selection criterion, checked by measurement, not an assumption.
        let reasoning: Reasoning
    }

    /// True for the 400 an endpoint returns when it mandates reasoning.
    /// Matching on the message is unpleasant but there is no distinct code:
    /// `google/gemini-3.5-flash` answers 400 with "Reasoning is mandatory for
    /// this endpoint and cannot be disabled."
    static func disablingReasoningRejected(status: Int, body: String) -> Bool {
        status == 400 && body.lowercased().contains("reasoning")
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let session: URLSession
    private let keyProvider: @Sendable () -> String?

    init(
        session: URLSession = .shared,
        keyProvider: @escaping @Sendable () -> String? = { KeychainStore.read() }
    ) {
        self.session = session
        self.keyProvider = keyProvider
    }

    func clean(_ text: String, prompt: String, model: String) async throws -> String {
        guard let key = keyProvider(), !key.isEmpty else {
            // Never log the key. Its presence and length are enough to tell a
            // missing key apart from a malformed one.
            Diagnostics.log("openrouter: no API key found in the keychain")
            throw PolishError.missingAPIKey
        }
        Diagnostics.log("openrouter: requesting \(model), key present (\(key.count) chars)")

        let messages: [ChatRequest.Message] = [
            .init(role: "system", content: prompt),
            .init(role: "user", content: text),
        ]

        do {
            return try await send(key: key, model: model, messages: messages)
        } catch let PolishError.http(status, body)
            where Self.disablingReasoningRejected(status: status, body: body)
        {
            // Deliberately not retried without the field. A model that
            // mandates reasoning is too slow for this call regardless —
            // measured at 3.0s against a 3.0s budget — so a retry would only
            // convert a clear failure into a silent timeout, and the user
            // would be left wondering why cleanup "sometimes" works. Say what
            // is wrong instead.
            Diagnostics.log("openrouter: \(model) mandates reasoning, which is too slow here")
            throw PolishError.requiresReasoning(model)
        }
    }

    private func send(
        key: String,
        model: String,
        messages: [ChatRequest.Message]
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                model: model,
                messages: messages,
                temperature: 0,
                reasoning: ChatRequest.Reasoning(enabled: false)
            )
        )

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PolishError.http(
                http.statusCode, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let content = Self.unwrap(decoded.choices.first?.message.content ?? "")
        guard !content.isEmpty else { throw PolishError.emptyResponse }
        return content
    }

    /// Models occasionally wrap their answer in quotes or a code fence even
    /// when told not to.
    static func unwrap(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()  // the opening fence, plus any language tag
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
