import SwiftUI

struct ChatGPTSettingsView: View {
    @ObservedObject private var client = ChatGPTClient.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("ChatGPT 账号", systemImage: "person.crop.circle")
                .font(.headline)
            Text("使用 ChatGPT 账号登录并授权 NGM proofread 使用计划额度，无需填写 API Key。能否使用取决于账号计划、授权和剩余额度。")
                .font(.caption).foregroundStyle(.secondary)

            if !client.accounts.isEmpty {
                Picker("账号", selection: Binding(get: { client.activeID }, set: { id in
                    client.selectAccount(id)
                    Task { await client.loadModels() }
                })) {
                    ForEach(client.accounts) { account in
                        Text(account.label).tag(account.id)
                    }
                }
                .disabled(client.isConnecting || client.isSigningOut || client.isLoadingModels)
            }

            HStack {
                Button("Continue with ChatGPT") { client.connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(client.isConnecting || client.isSigningOut || client.isLoadingModels)
                if client.isConnecting {
                    ProgressView().controlSize(.small)
                    Button("取消") { client.cancelLogin() }
                } else if client.activeAccount != nil {
                    Button("添加其他账号") { client.connect(newAccount: true) }
                        .disabled(client.isSigningOut || client.isLoadingModels)
                    Button("退出") { Task { await client.signOut() } }
                        .disabled(client.isSigningOut)
                }
            }

            if let account = client.activeAccount, account.canUsePlan {
                if !client.models.isEmpty {
                    Picker("模型", selection: Binding(get: { client.activeAccount?.selectedModel ?? "" },
                                                     set: { client.selectModel($0) })) {
                        Text("请选择模型").tag("")
                        ForEach(client.models) { model in Text(model.displayName).tag(model.slug) }
                    }
                    .disabled(client.isConnecting || client.isSigningOut || client.isLoadingModels)
                } else if let model = account.selectedModel {
                    Text("上次选择：\(model)").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("刷新可用模型") { Task { await client.loadModels() } }
                        .disabled(client.isLoadingModels || client.isConnecting || client.isSigningOut)
                    if client.isLoadingModels || client.isSigningOut { ProgressView().controlSize(.small) }
                    Link("查看使用额度", destination: URL(string: "https://chatgpt.com/#settings")!)
                }
            }

            if let status = client.status {
                Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }

            Divider()
            Text("免费网页版")
                .font(.subheadline).bold()
            Text("如果账号不支持计划接入，可以在 ChatGPT 网页中使用免费功能。此入口只打开网页，需手动提交文字和查看回复，不会自动填入 NGM 的翻译结果。")
                .font(.caption).foregroundStyle(.secondary)
            Link("打开 ChatGPT 网页", destination: URL(string: "https://chatgpt.com/")!)
            Link("了解 ChatGPT 账号接入", destination: URL(string: "https://developers.openai.com/siwc/quickstart")!)
                .font(.caption)
        }
        .task { await client.loadModels() }
    }
}
