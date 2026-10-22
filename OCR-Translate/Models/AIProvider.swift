import Foundation

enum AIProvider: String, CaseIterable, Equatable {
    case deepseek
    case openai
    case gemini
    case chatgpt

    var displayName: String {
        switch self {
        case .deepseek: "DeepSeek"
        case .openai:   "OpenAI API（独立计费）"
        case .gemini:   "Gemini (Google)"
        case .chatgpt:  "ChatGPT 账号（使用计划额度）"
        }
    }

    var shortName: String {
        switch self {
        case .deepseek: "DeepSeek"
        case .openai:   "OpenAI"
        case .gemini:   "Gemini"
        case .chatgpt:  "ChatGPT"
        }
    }

    var endpoint: String {
        switch self {
        case .deepseek: "https://api.deepseek.com/v1/chat/completions"
        case .openai:   "https://api.openai.com/v1/chat/completions"
        case .gemini:   "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
        case .chatgpt:  "https://api.openai.com/v1/responses"
        }
    }

    var model: String {
        switch self {
        case .deepseek: "deepseek-chat"
        case .openai:   "gpt-4o"
        case .gemini:   "gemini-2.0-flash"
        case .chatgpt:  "" // The account-specific catalog supplies the model.
        }
    }

    /// How the API key is sent
    var authHeader: (String, String)? {
        switch self {
        case .deepseek, .openai:
            return ("Authorization", "Bearer <key>")
        case .gemini:
            return nil // key goes in URL query param
        case .chatgpt:
            return nil // OAuth authorization is handled by ChatGPTClient.
        }
    }

    var getKeyURL: String {
        switch self {
        case .deepseek: "platform.deepseek.com → API Keys"
        case .openai:   "platform.openai.com → API Keys"
        case .gemini:   "aistudio.google.com → Get API Key"
        case .chatgpt:  "在浏览器中登录 ChatGPT"
        }
    }

    /// Key prefix hint for placeholder
    var keyPrefix: String {
        switch self {
        case .deepseek: "sk-"
        case .openai:   "sk-"
        case .gemini:   "AIza"
        case .chatgpt:  ""
        }
    }
}
