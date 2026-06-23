import SwiftUI

enum InputMode: String, CaseIterable {
    case image = "图片识别"
    case text = "文字输入"
}

struct ContentView: View {
    @State private var selectedImage: NSImage?
    @State private var ocrResult: OCRResult?
    @State private var analysisMode: AnalysisMode = .proofread
    @State private var isProcessingOCR = false
    @State private var isProcessingAI = false
    @State private var errorMessage: String?
    @State private var showingSettings = false
    @State private var pendingImage: NSImage?
    @State private var lookupWord: String = ""
    @State private var inputMode: InputMode = .image
    @State private var manualText: String = ""
    @State private var proofreadText: String = ""
    @State private var referenceImage: NSImage?

    // Per-mode translation/analysis state
    @State private var imageTranslation: TranslationResult?
    @State private var imageAnalysis: AnalysisResult?
    @State private var imageCache: [AnalysisMode: AnalysisResult] = [:]
    @State private var textTranslation: TranslationResult?
    @State private var textAnalysis: AnalysisResult?
    @State private var textCache: [AnalysisMode: AnalysisResult] = [:]

    private var currentTranslation: TranslationResult? {
        inputMode == .image ? imageTranslation : textTranslation
    }
    private var currentAnalysis: AnalysisResult? {
        inputMode == .image ? imageAnalysis : textAnalysis
    }
    private var currentCache: [AnalysisMode: AnalysisResult] {
        get { inputMode == .image ? imageCache : textCache }
        nonmutating set {
            if inputMode == .image { imageCache = newValue } else { textCache = newValue }
        }
    }

    private let ocrService = OCRService()
    private let translationService = TranslationService()
    private let analysisService = AnalysisService()
    private let screenshotManager = ScreenshotManager()
    private let imageLoader = ImageLoader()
    private let apiKeyStore = APIKeyStore()
    @StateObject private var glossary = GlossaryStore()

    private var hasAPIKey: Bool { apiKeyStore.hasActiveKey() }

    private var currentText: String {
        let text = inputMode == .text ? manualText : (ocrResult?.fullText ?? "")
        return text
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationSplitView {
            sidebarView
        } content: {
            ocrContentView
        } detail: {
            translationDetailView
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                analysisModePicker
                Button(action: takeScreenshot) {
                    Label("截图", systemImage: "camera.viewfinder")
                }
                .help("截图识别 (⌘⇧S)")

                Button(action: uploadImage) {
                    Label("上传图片", systemImage: "photo.badge.plus")
                }
                .help("上传图片文件")

                Button(action: { showingSettings = true }) {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(analysisMode: $analysisMode)
        }
        .onChange(of: analysisMode) { _, _ in
            guard !currentText.isEmpty else { return }
            if let cached = currentCache[analysisMode] {
                applyAnalysis(cached)
                return
            }
            Task {
                isProcessingAI = true
                if currentTranslation == nil {
                    if inputMode == .text {
                        await performTextTranslation()
                    } else {
                        await performTranslationAndAnalysis()
                    }
                } else if let result = try? await analysisService.analyze(text: currentText, mode: analysisMode) {
                    applyAnalysis(result)
                }
                isProcessingAI = false
            }
        }
    }

    // MARK: - Sidebar (Image)

    private var sidebarView: some View {
        VStack(spacing: 0) {
            Picker("", selection: $inputMode) {
                ForEach(InputMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if inputMode == .text {
                manualTextInputView
            } else if let image = selectedImage {
                CroppableImageView(image: image, onConfirm: { cropped in
                    pendingImage = cropped
                    Task { await performOCR() }
                }, onRequestNewImage: {
                    uploadImage()
                })
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "doc.text.image")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("点击截图按钮或上传图片开始")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    VStack(spacing: 12) {
                        Button(action: uploadImage) {
                            Label("上传图片", systemImage: "photo.badge.plus")
                                .frame(width: 160)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button(action: takeScreenshot) {
                            Label("截图识别", systemImage: "camera.viewfinder")
                                .frame(width: 160)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 350, max: 500)
    }

    // MARK: - Manual text input

    private var manualTextInputView: some View {
        VStack(spacing: 0) {
            // 翻译栏
            VStack(alignment: .leading, spacing: 4) {
                Text("翻译栏")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                TextEditor(text: $manualText)
                    .font(.body)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.quaternary, lineWidth: 0.5)
                    )
                    .padding(.horizontal, 12)
            }
            .padding(.top, 8)

            Divider().padding(.vertical, 8)

            // 校对栏
            VStack(alignment: .leading, spacing: 4) {
                Text("校对栏")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                TextEditor(text: $proofreadText)
                    .font(.body)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.quaternary, lineWidth: 0.5)
                    )
                    .padding(.horizontal, 12)
            }

            // Bottom buttons
            HStack {
                Button(action: {
                    manualText = ""
                    proofreadText = ""
                    resetResults()
                }) {
                    Label("清空", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(manualText.isEmpty && proofreadText.isEmpty)

                Spacer()

                Button(action: {
                    Task {
                        resetResults()
                        await performTextTranslation()
                    }
                }) {
                    Label("开始翻译分析", systemImage: "sparkles")
                        .frame(width: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessingAI)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Content (OCR Result)

    private var ocrContentView: some View {
        Group {
            if inputMode == .text {
                // Text mode content
                VStack {
                    if let ref = referenceImage {
                        ZoomableImageView(image: ref, onUploadNew: uploadReferenceImage)
                    } else {
                        VStack(spacing: 20) {
                            Image(systemName: "doc.text.image")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text("上传对照图片")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            Button(action: uploadReferenceImage) {
                                Label("选择图片", systemImage: "photo.badge.plus")
                                    .frame(width: 140)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else if isProcessingOCR {
                ProgressView("正在识别文字...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(error)
                        .foregroundStyle(.secondary)
                    Button("重试") {
                        errorMessage = nil
                        Task { await performOCR() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let ocr = ocrResult {
                OCRResultView(result: ocr)
            } else {
                Text("等待图片...")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewColumnWidth(min: 250, ideal: 350, max: 500)
    }

    // MARK: - Detail (Translation + Analysis)

    private var translationDetailView: some View {
        Group {
            if let translation = currentTranslation {
                VStack(spacing: 0) {
                    VocabularyLookupView(externalQuery: $lookupWord)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            TranslationResultView(result: translation, originalText: currentText)

                            if currentAnalysis != nil {
                                Divider()
                            }

                            AnalysisView(result: currentAnalysis)
                        }
                        .padding()
                    }
                }
            } else if let ocr = ocrResult {
                VStack(spacing: 20) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)

                    if isProcessingAI {
                        ProgressView("正在翻译和分析...")
                    } else if hasAPIKey {
                        Text("OCR 识别完成")
                            .font(.headline)
                        Text("共识别 \(ocr.blocks.count) 段文字，平均置信度 \(Int(ocr.averageConfidence * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button(action: { Task { await performTranslationAndAnalysis() } }) {
                            Label("开始翻译分析", systemImage: "sparkles")
                                .frame(width: 180)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else {
                        Text("OCR 识别完成")
                            .font(.headline)
                        Text("共识别 \(ocr.blocks.count) 段文字，平均置信度 \(Int(ocr.averageConfidence * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("配置 DeepSeek API Key 后可翻译分析")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Button(action: { showingSettings = true }) {
                            Label("配置 API Key", systemImage: "key")
                                .frame(width: 180)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if inputMode == .text, !manualText.isEmpty, !isProcessingAI {
                VStack(spacing: 20) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("文字已输入，点击侧栏按钮开始翻译")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isProcessingOCR {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("等待识别完成...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 12) {
                    Text("处理出错")
                        .font(.headline)
                    Text(error)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("翻译结果将显示在这里")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewColumnWidth(min: 350, ideal: 450)
    }

    // MARK: - Analysis Mode Picker

    private var analysisModePicker: some View {
        HStack(spacing: 8) {
            if isProcessingAI {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                    .help("正在分析...")
            }
            Picker("分析模式", selection: $analysisMode) {
                ForEach(AnalysisMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .contextMenu { EmptyView() }
        }
    }

    // MARK: - Actions

    private func takeScreenshot() {
        Task {
            do {
                let image = try await screenshotManager.capture()
                selectedImage = image
                resetResults()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func uploadImage() {
        Task {
            if inputMode == .text {
                if let img = await imageLoader.loadFromFile() { referenceImage = img }
            } else {
                if let image = await imageLoader.loadFromFile() { selectedImage = image; resetResults() }
            }
        }
    }

    private func resetResults() {
        ocrResult = nil
        imageTranslation = nil; imageAnalysis = nil; imageCache = [:]
        textTranslation = nil; textAnalysis = nil; textCache = [:]
        errorMessage = nil
        pendingImage = nil
    }

    // MARK: - Helpers

    private func applyAnalysis(_ result: AnalysisResult) {
        if inputMode == .image { imageAnalysis = result; imageCache[analysisMode] = result }
        else { textAnalysis = result; textCache[analysisMode] = result }
    }

    // MARK: - OCR (local, no API needed)

    private func performOCR() async {
        guard let image = pendingImage else { return }

        isProcessingOCR = true
        errorMessage = nil
        imageTranslation = nil; imageAnalysis = nil; imageCache = [:]

        do {
            let ocr = try await ocrService.recognize(image)
            ocrResult = ocr

            if ocr.fullText.isEmpty {
                errorMessage = "未识别到文字内容"
                isProcessingOCR = false
                return
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isProcessingOCR = false
    }

    private func uploadReferenceImage() {
        Task {
            if let img = await imageLoader.loadFromFile() {
                referenceImage = img
            }
        }
    }

    // MARK: - Manual text translation (skips OCR)

    private func performTextTranslation() async {
        let text = manualText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isProcessingAI = true

        do {
            async let translation = translationService.translate(text: text, glossary: glossary.buildPromptSnippet())
            async let analysis = analysisService.analyze(text: currentText, mode: analysisMode)

            let (trans, anal) = try await (translation, analysis)
            textTranslation = trans
            textAnalysis = anal
            textCache[analysisMode] = anal
        } catch {
            errorMessage = error.localizedDescription
        }

        isProcessingAI = false
    }

    // MARK: - Translation + Analysis (needs API key)

    private func performTranslationAndAnalysis() async {
        guard let ocr = ocrResult, !ocr.fullText.isEmpty else { return }

        isProcessingAI = true

        do {
            async let translation = translationService.translate(text: ocr.fullText, glossary: glossary.buildPromptSnippet())
            async let analysis = analysisService.analyze(text: currentText, mode: analysisMode)

            let (trans, anal) = try await (translation, analysis)
            imageTranslation = trans
            imageAnalysis = anal
            imageCache[analysisMode] = anal
        } catch {
            errorMessage = error.localizedDescription
        }

        isProcessingAI = false
    }
}
