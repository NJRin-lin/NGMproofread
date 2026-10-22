import Foundation

enum TranslationError: LocalizedError {
    case emptyText
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .emptyText: "没有可翻译的文本"
        case .apiError(let msg): "翻译出错: \(msg)"
        }
    }
}

final class TranslationService {
    private let deepSeek = DeepSeekService()

    private let systemPrompt = """
    你是一位专业的日文翻译专家。你的任务是将日文文本翻译成流畅自然的中文。

    翻译要求：
    1. 保持原文的段落结构和换行格式
    2. 准确传达原文含义，避免漏译或过度意译
    3. 遇到专业术语时保持准确，必要时在括号内加注说明
    4. 日文特有的敬语表达在中文中找到最贴切的对应
    5. 如果原文包含多种语言（如日文中夹杂英文），保留英文不翻译

    请直接输出翻译结果，不要添加任何解释或说明。
    """

    func translate(text: String, glossary: String = "") async throws -> TranslationResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranslationError.emptyText
        }

        let prompt = systemPrompt + glossary
        let providerName = deepSeek.activeProvider.shortName

        do {
            let translated = try await deepSeek.chat(
                systemPrompt: prompt,
                userMessage: trimmed
            )
            return TranslationResult(
                originalText: trimmed,
                translatedText: translated.trimmingCharacters(in: .whitespacesAndNewlines),
                providerName: providerName
            )
        } catch {
            throw TranslationError.apiError(error.localizedDescription)
        }
    }
}
