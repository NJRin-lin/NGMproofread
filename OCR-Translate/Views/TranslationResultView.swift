import SwiftUI

struct TranslationResultView: View {
    let result: TranslationResult
    let originalText: String
    var onLookup: ((String) -> Void)?

    private var cleanedOriginal: String {
        originalText
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("翻译结果")
                    .font(.headline)
                Text(result.providerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Text(langLabel(result.sourceLanguage))
                    Image(systemName: "arrow.right")
                        .font(.caption)
                    Text(langLabel(result.targetLanguage))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(.quaternary))
            }

            Divider()

            // 日文原文
            VStack(alignment: .leading, spacing: 4) {
                Text("原文")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(cleanedOriginal)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary)
                    )
            }

            // 中文翻译
            VStack(alignment: .leading, spacing: 4) {
                Text("中文")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(result.translatedText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func langLabel(_ code: String) -> String {
        switch code {
        case "ja": return "🇯🇵 日文"
        case "zh-CN": return "🇨🇳 中文"
        case "en": return "🇺🇸 英文"
        default: return code
        }
    }
}
