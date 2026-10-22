import Foundation

struct TranslationResult: Equatable {
    let originalText: String
    let translatedText: String
    let sourceLanguage: String
    let targetLanguage: String
    let timestamp: Date
    let providerName: String

    init(
        originalText: String,
        translatedText: String,
        sourceLanguage: String = "ja",
        targetLanguage: String = "zh-CN",
        timestamp: Date = Date(),
        providerName: String = "AI"
    ) {
        self.originalText = originalText
        self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.timestamp = timestamp
        self.providerName = providerName
    }
}
