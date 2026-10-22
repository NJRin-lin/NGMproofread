import Foundation

struct VocabEntry: Equatable, Codable {
    let word: String
    let reading: String
    let meaning: String
    let partOfSpeech: String?
    let jlptLevel: String?
    let examples: [String]
    let notes: String?
}

enum VocabError: LocalizedError {
    case emptyWord
    case apiError(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .emptyWord: "请输入要查询的单词"
        case .apiError(let msg): "查询出错: \(msg)"
        case .parseError(let msg): "解析出错: \(msg)"
        }
    }
}

final class VocabularyService {
    private let deepSeek = DeepSeekService()
    private let systemPrompt = """
    你是一位专业的日语词典助手。用户会输入一个日语单词或短语，请返回 JSON：

    {
      "word": "原词",
      "reading": "读音（平假名）",
      "meaning": "中文释义",
      "partOfSpeech": "词性",
      "jlptLevel": "JLPT级别",
      "examples": ["例句1（日文）", "例句2（日文）"],
      "notes": "用法说明或常见搭配"
    }

    要求：
    - reading 必须使用平假名
    - meaning 使用简洁中文
    - examples 提供 1-3 个实际例句（日文即可）
    - 如果查询的是短语，说明其构成和用法
    - 只输出 JSON
    """

    private var cache: [String: VocabEntry] = [:]

    func lookup(_ word: String) async throws -> VocabEntry {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VocabError.emptyWord }

        let provider = deepSeek.activeProvider
        let connection: String
        if provider == .chatgpt {
            connection = await ChatGPTClient.shared.cacheIdentity
        } else {
            connection = provider.rawValue
        }
        let key = connection + ":" + trimmed.lowercased()
        if let cached = cache[key] { return cached }

        let raw: String
        do {
            raw = try await deepSeek.chat(
                systemPrompt: systemPrompt,
                userMessage: trimmed,
                temperature: 0.1,
                maxTokens: 1024
            )
        } catch {
            throw VocabError.apiError(error.localizedDescription)
        }

        let entry = try parse(raw, word: trimmed)
        cache[key] = entry
        return entry
    }

    func clearCache() { cache.removeAll() }

    private func parse(_ jsonString: String, word: String) throws -> VocabEntry {
        let cleaned = jsonString
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            throw VocabError.parseError("编码失败")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VocabError.parseError("JSON 解析失败")
        }

        return VocabEntry(
            word: json["word"] as? String ?? word,
            reading: json["reading"] as? String ?? "",
            meaning: json["meaning"] as? String ?? "",
            partOfSpeech: json["partOfSpeech"] as? String,
            jlptLevel: json["jlptLevel"] as? String,
            examples: json["examples"] as? [String] ?? [],
            notes: json["notes"] as? String
        )
    }
}
