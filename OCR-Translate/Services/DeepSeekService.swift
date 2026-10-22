import Foundation

enum AIServiceError: LocalizedError {
    case invalidURL
    case noAPIKey
    case requestFailed(Int)
    case decodingFailed
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: "API 地址无效"
        case .noAPIKey: "请先在设置中配置 API Key"
        case .requestFailed(let code): "API 请求失败 (HTTP \(code))"
        case .decodingFailed: "API 响应解析失败"
        case .emptyResponse: "API 返回内容为空"
        }
    }
}

// MARK: - OpenAI-compatible chat models

struct ChatMessage: Codable {
    let role: String
    let content: String
}

struct ChatRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
    }
}

struct ChatChoice: Codable {
    let message: ChatMessage
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
    }
}

struct ChatResponse: Codable {
    let choices: [ChatChoice]
}

// MARK: - Gemini models

private struct GeminiPart: Codable {
    let text: String
}

private struct GeminiContent: Codable {
    let role: String?
    let parts: [GeminiPart]
}

private struct GeminiRequest: Codable {
    let systemInstruction: GeminiContent?
    let contents: [GeminiContent]

    enum CodingKeys: String, CodingKey {
        case systemInstruction = "system_instruction"
        case contents
    }
}

private struct GeminiCandidate: Codable {
    let content: GeminiContent
}

private struct GeminiResponse: Codable {
    let candidates: [GeminiCandidate]
}

// MARK: - Service

final class AIService {
    private let store = APIKeyStore()

    var activeProvider: AIProvider { store.activeProvider }

    func chat(
        systemPrompt: String,
        userMessage: String,
        temperature: Double = 0.3,
        maxTokens: Int = 4096
    ) async throws -> String {
        let provider = store.activeProvider

        if provider == .chatgpt {
            return try await ChatGPTClient.shared.chat(instructions: systemPrompt, text: userMessage)
        }

        guard let apiKey = store.read(for: provider), !apiKey.isEmpty else {
            throw AIServiceError.noAPIKey
        }

        switch provider {
        case .deepseek, .openai:
            return try await openAICompatibleChat(
                provider: provider,
                apiKey: apiKey,
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                temperature: temperature,
                maxTokens: maxTokens
            )
        case .gemini:
            return try await geminiChat(
                apiKey: apiKey,
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                temperature: temperature,
                maxTokens: maxTokens
            )
        case .chatgpt:
            throw AIServiceError.noAPIKey // Handled above; never send a plan token to Chat Completions.
        }
    }

    // MARK: - OpenAI-compatible (DeepSeek / OpenAI)

    private func openAICompatibleChat(
        provider: AIProvider,
        apiKey: String,
        systemPrompt: String,
        userMessage: String,
        temperature: Double,
        maxTokens: Int
    ) async throws -> String {
        guard let url = URL(string: provider.endpoint) else {
            throw AIServiceError.invalidURL
        }

        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userMessage)
        ]

        let requestBody = ChatRequest(
            model: provider.model,
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(requestBody)
        urlRequest.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.requestFailed(0)
        }
        guard httpResponse.statusCode == 200 else {
            throw AIServiceError.requestFailed(httpResponse.statusCode)
        }
        guard let chatResponse = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = chatResponse.choices.first?.message.content,
              !content.isEmpty else {
            throw AIServiceError.emptyResponse
        }

        return content
    }

    // MARK: - Gemini

    private func geminiChat(
        apiKey: String,
        systemPrompt: String,
        userMessage: String,
        temperature _: Double,
        maxTokens: Int
    ) async throws -> String {
        let provider = AIProvider.gemini
        var components = URLComponents(string: provider.endpoint)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        guard let url = components.url else {
            throw AIServiceError.invalidURL
        }

        var systemInstr: GeminiContent? = nil
        if !systemPrompt.isEmpty {
            systemInstr = GeminiContent(role: nil, parts: [GeminiPart(text: systemPrompt)])
        }

        let request = GeminiRequest(
            systemInstruction: systemInstr,
            contents: [GeminiContent(role: "user", parts: [GeminiPart(text: userMessage)])]
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        urlRequest.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.requestFailed(0)
        }
        guard httpResponse.statusCode == 200 else {
            throw AIServiceError.requestFailed(httpResponse.statusCode)
        }
        guard let geminiResponse = try? JSONDecoder().decode(GeminiResponse.self, from: data),
              let content = geminiResponse.candidates.first?.content.parts.first?.text,
              !content.isEmpty else {
            throw AIServiceError.emptyResponse
        }

        return content
    }
}

/// Backward compatibility alias
typealias DeepSeekService = AIService
