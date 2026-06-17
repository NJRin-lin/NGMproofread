import SwiftUI

struct SettingsView: View {
    @Binding var analysisMode: AnalysisMode
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProvider: AIProvider = .deepseek
    @State private var apiKey: String = ""
    @State private var showKey: Bool = false
    @State private var saveStatus: String?

    @State private var newWord: String = ""
    @State private var newTranslation: String = ""

    private let store = APIKeyStore()
    @StateObject private var glossary = GlossaryStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("设置")
                    .font(.title2)
                    .bold()
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    providerSection
                    Divider()
                    apiKeySection
                    Divider()
                    analysisModeSection
                    Divider()
                    glossarySection
                    Divider()
                    aboutSection
                }
                .padding()
            }
        }
        .frame(width: 520, height: 600)
        .onAppear {
            selectedProvider = store.activeProvider
            loadKey()
        }
        .onChange(of: selectedProvider) { _, _ in
            store.activeProvider = selectedProvider
            loadKey()
            saveStatus = nil
        }
    }

    // MARK: - Provider Picker

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "cpu.fill")
                    .foregroundStyle(.blue)
                Text("AI 模型")
                    .font(.headline)
            }

            Picker("", selection: $selectedProvider) {
                ForEach(AIProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.radioGroup)
        }
    }

    // MARK: - API Key Section

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "key.fill")
                    .foregroundStyle(.blue)
                Text("\(selectedProvider.shortName) API Key")
                    .font(.headline)
            }

            Text("API Key 仅存储在本机")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if showKey {
                    TextField("\(selectedProvider.keyPrefix)...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                } else {
                    SecureField("\(selectedProvider.keyPrefix)...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }

                Button(action: { showKey.toggle() }) {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(showKey ? "隐藏" : "显示")
            }

            HStack {
                Button("保存") {
                    let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    store.save(trimmed, for: selectedProvider)
                    saveStatus = "\(selectedProvider.shortName) 已保存"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveStatus = nil }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("删除") {
                    store.delete(for: selectedProvider)
                    apiKey = ""
                    saveStatus = "已删除"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveStatus = nil }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)

                if let status = saveStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Text("获取 Key: \(selectedProvider.getKeyURL)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Analysis Mode

    private var analysisModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "text.magnifyingglass")
                    .foregroundStyle(.purple)
                Text("默认分析深度")
                    .font(.headline)
            }

            Picker("", selection: $analysisMode) {
                Text("学习模式 — 句子拆解 + 语法 + 词汇注解").tag(AnalysisMode.study)
                Text("校对模式 — 精准句子成分拆解").tag(AnalysisMode.proofread)
            }
            .pickerStyle(.radioGroup)
        }
    }

    // MARK: - Glossary

    private var glossarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "character.book.closed.fill")
                    .foregroundStyle(.orange)
                Text("翻译术语表")
                    .font(.headline)
            }

            Text("AI 翻译时将严格按照下列映射翻译指定词汇。建议单次使用的术语控制在 50 条以内")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Add new entry
            HStack(spacing: 6) {
                TextField("日语词汇", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 120)
                TextField("中文翻译", text: $newTranslation)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 120)
                Button("添加") {
                    glossary.add(word: newWord, translation: newTranslation)
                    newWord = ""
                    newTranslation = ""
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty
                       || newTranslation.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // Entry list
            if glossary.entries.isEmpty {
                Text("暂无术语，添加后翻译将自动应用")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(glossary.entries) { entry in
                            HStack(spacing: 6) {
                                Text("「\(entry.word)」→「\(entry.translation)」")
                                    .font(.caption)
                                Spacer()
                                Button(action: { glossary.remove(entry) }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 2)
                            .padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.3)))
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.gray)
                Text("关于")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("NGM proofread")
                    .font(.body)
                Text("版本 1.0.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("开发者：NJRin")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("技术支持：虹之咲学园 Vibe Coding 同好会")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func loadKey() {
        apiKey = store.read(for: selectedProvider) ?? ""
    }
}
