import Foundation
import Combine

@MainActor
final class ChatGPTClient: ObservableObject {
    static let shared = ChatGPTClient()
    @Published private(set) var accounts: [ChatGPTAccount] = []
    @Published private(set) var activeID: String
    @Published private(set) var models: [ChatGPTModel] = []
    @Published private(set) var isConnecting = false
    @Published private(set) var isLoadingModels = false
    @Published private(set) var isSigningOut = false
    @Published var status: String?

    private let defaults: UserDefaults
    private let session: URLSession
    private var loginTask: Task<Void, Never>?
    private var refreshTasks: [String: Task<ChatGPTAccount, Error>] = [:]
    private var generations: [String: UUID] = [:]

    var activeAccount: ChatGPTAccount? { accounts.first { $0.id == activeID } }
    var isReady: Bool { activeAccount?.canUsePlan == true && activeAccount?.selectedModel != nil }
    var cacheIdentity: String {
        ["chatgpt", activeID, activeAccount?.selectedModel ?? "", generations[activeID]?.uuidString ?? ""].joined(separator: ":")
    }

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        activeID = defaults.string(forKey: "chatgpt_active_account") ?? ""
        do { accounts = try ChatGPTCredentialStore.read() }
        catch { status = error.localizedDescription }
        if !accounts.contains(where: { $0.id == activeID }) { activeID = accounts.first?.id ?? "" }
    }

    func selectAccount(_ id: String) {
        guard accounts.contains(where: { $0.id == id }), !isConnecting, !isSigningOut else { return }
        activeID = id
        defaults.set(id, forKey: "chatgpt_active_account")
        models = []
        status = nil
    }

    func selectModel(_ slug: String) {
        guard models.contains(where: { $0.slug == slug }),
              var account = activeAccount else { return }
        account.selectedModel = slug
        do { try save(account) } catch { status = error.localizedDescription }
    }

    func connect(newAccount: Bool = false) {
        guard !isConnecting, !isSigningOut else { return }
        isConnecting = true
        status = "请在浏览器中完成 ChatGPT 登录和授权"
        let previous = newAccount ? nil : activeAccount
        loginTask = Task {
            let login = ChatGPTLogin()
            defer { isConnecting = false; loginTask = nil }
            do {
                let redirect = try await login.start()
                let state = try ChatGPTProtocol.random()
                let nonce = try ChatGPTProtocol.random()
                let verifier = try ChatGPTProtocol.random()
                let url = ChatGPTProtocol.authorizeURL(hostID: hostID, redirect: redirect, state: state,
                                                       nonce: nonce, verifier: verifier, account: previous)
                let callback = try await login.authorize(at: url, state: state)
                let authorization = try ChatGPTProtocol.callback(callback, state: state, account: previous)
                let tokens = try await exchange([
                    "grant_type": "authorization_code", "client_id": authorization.clientID,
                    "code": authorization.code, "code_verifier": verifier,
                    "redirect_uri": redirect, "resource": ChatGPTProtocol.resource
                ])
                guard let idToken = tokens.idToken else { throw ChatGPTError.message("ChatGPT 未返回身份凭据，请重新登录") }
                let discovery = try await ChatGPTDiscovery.load(session: session)
                let (keyData, keyResponse) = try await session.data(from: discovery.jwksURI)
                try ChatGPTProtocol.checkHTTP(keyResponse)
                let claims = try ChatGPTIdentity.validate(idToken, clientID: authorization.clientID, nonce: nonce,
                                                          keys: JSONDecoder().decode(ChatGPTIdentity.JWKS.self, from: keyData))
                guard previous == nil || previous?.subject == claims.sub else {
                    throw ChatGPTError.message("登录账号与所选账号不一致，请使用“添加其他账号”")
                }
                if let saved = accounts.first(where: { $0.id == authorization.clientID }), saved.subject != claims.sub {
                    throw ChatGPTError.message("ChatGPT 账号身份不匹配")
                }
                try Task.checkCancellation()
                let account = ChatGPTAccount(clientID: authorization.clientID, subject: claims.sub,
                    email: claims.email ?? "", accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
                    idToken: idToken, expiresAt: Date().addingTimeInterval(tokens.expiresIn),
                    scopes: (tokens.scope ?? "").split(separator: " ").map(String.init), selectedModel: previous?.selectedModel)
                try save(account)
                generations[account.id] = UUID()
                activeID = account.id
                defaults.set(activeID, forKey: "chatgpt_active_account")
                models = []
                status = account.canUsePlan ? "ChatGPT 已连接" : "已登录，但未获得计划使用权限。请检查账号资格或重新授权；也可以使用网页版。"
                if account.canUsePlan { await loadModels() }
            } catch is CancellationError { status = "已取消登录" }
            catch { status = error.localizedDescription }
            login.cancel()
        }
    }

    func cancelLogin() { loginTask?.cancel() }

    func loadModels() async {
        guard let account = activeAccount, account.canUsePlan, !isLoadingModels, !isSigningOut else { return }
        let id = account.id
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let refreshed = try await authorizedAccount(id)
            var request = URLRequest(url: URL(string: ChatGPTProtocol.resource + "/models")!)
            request.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            try ChatGPTProtocol.checkHTTP(response)
            struct Catalog: Decodable { let models: [ChatGPTModel] }
            let available = try JSONDecoder().decode(Catalog.self, from: data).models.filter { $0.visibility == "list" }
            guard activeID == id, activeAccount?.canUsePlan == true, !isSigningOut else { return }
            models = available
            if let current = activeAccount?.selectedModel, !available.contains(where: { $0.slug == current }),
               var currentAccount = activeAccount {
                currentAccount.selectedModel = nil
                try save(currentAccount)
            }
            if activeAccount?.selectedModel == nil, let first = available.first { selectModel(first.slug) }
            status = available.isEmpty ? "此账号暂时没有可用模型，请检查授权和 ChatGPT 计划资格" : "ChatGPT 已连接，模型列表已更新"
        } catch {
            if activeID == id { status = error.localizedDescription }
        }
    }

    func signOut() async {
        guard var account = activeAccount, !isConnecting, !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        let id = account.id
        generations[id] = UUID()
        refreshTasks[id]?.cancel(); refreshTasks[id] = nil
        var remoteRevoked = account.refreshToken == nil
        if let refresh = account.refreshToken {
            do {
                let discovery = try await ChatGPTDiscovery.load(session: session)
                var request = URLRequest(url: discovery.revocationEndpoint)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = ChatGPTProtocol.form(["token": refresh, "token_type_hint": "refresh_token", "client_id": id])
                request.timeoutInterval = 15
                let (_, response) = try await session.data(for: request)
                try ChatGPTProtocol.checkHTTP(response)
                remoteRevoked = true
            } catch { remoteRevoked = false }
        }
        account.accessToken = ""; account.refreshToken = nil; account.idToken = nil
        account.scopes = []; account.selectedModel = nil; account.expiresAt = .distantPast
        do {
            try save(account)
            models = []
            status = remoteRevoked ? "已退出 ChatGPT" : "已清除本机登录信息，远程退出未确认。请在 ChatGPT 设置中断开 NGM proofread。"
        } catch { status = "本机登录信息清除失败，请重试退出：\(error.localizedDescription)" }
    }

    func chat(instructions: String, text: String) async throws -> String {
        guard let account = activeAccount, !isSigningOut else { throw ChatGPTError.message("请先在设置中连接 ChatGPT") }
        let id = account.id
        let generation = generations[id]
        let authorized = try await authorizedAccount(id)
        guard let model = authorized.selectedModel else { throw ChatGPTError.message("请在设置中刷新并选择 ChatGPT 模型") }
        let request = try ChatGPTProtocol.responseRequest(token: authorized.accessToken, model: model,
                                                          instructions: instructions, text: text)
        let (bytes, response) = try await session.bytes(for: request)
        try ChatGPTProtocol.checkHTTP(response)
        var stream = ChatGPTStream()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard activeID == id, generations[id] == generation, accounts.first(where: { $0.id == id })?.canUsePlan == true else {
                throw ChatGPTError.message("ChatGPT 连接已变更，此次请求已停止")
            }
            try stream.line(line)
        }
        return try stream.finish()
    }

    private var hostID: String {
        if let value = defaults.string(forKey: "chatgpt_host_id") { return value }
        let value = "urn:uuid:" + UUID().uuidString.lowercased()
        defaults.set(value, forKey: "chatgpt_host_id")
        return value
    }

    private func save(_ account: ChatGPTAccount) throws {
        var updated = accounts.filter { $0.id != account.id }
        updated.append(account)
        try ChatGPTCredentialStore.save(updated)
        accounts = updated
    }

    private func authorizedAccount(_ id: String) async throws -> ChatGPTAccount {
        guard let account = accounts.first(where: { $0.id == id }), account.canUsePlan, !isSigningOut else {
            throw ChatGPTError.message("请在设置中连接 ChatGPT 并授权使用计划额度")
        }
        if account.expiresAt.timeIntervalSinceNow > 90 { return account }
        if let pending = refreshTasks[id] { return try await pending.value }
        guard let refresh = account.refreshToken else { throw ChatGPTError.message("ChatGPT 登录已过期，请重新连接") }
        let generation = generations[id]
        let pending = Task { () throws -> ChatGPTAccount in
            let tokens = try await exchange(["grant_type": "refresh_token", "client_id": id,
                                            "refresh_token": refresh, "resource": ChatGPTProtocol.resource])
            try Task.checkCancellation()
            guard generations[id] == generation else { throw CancellationError() }
            var updated = account
            // A model may have been selected while renewal was in flight.
            updated.selectedModel = accounts.first(where: { $0.id == id })?.selectedModel
            updated.accessToken = tokens.accessToken
            updated.refreshToken = tokens.refreshToken ?? account.refreshToken
            updated.idToken = tokens.idToken ?? account.idToken
            updated.expiresAt = Date().addingTimeInterval(tokens.expiresIn)
            if let scope = tokens.scope { updated.scopes = scope.split(separator: " ").map(String.init) }
            try save(updated)
            guard updated.canUsePlan else { throw ChatGPTError.message("ChatGPT 计划使用授权已失效，请重新连接") }
            return updated
        }
        refreshTasks[id] = pending
        defer { refreshTasks[id] = nil }
        return try await pending.value
    }

    private func exchange(_ fields: [String: String]) async throws -> ChatGPTTokens {
        var request = URLRequest(url: URL(string: ChatGPTProtocol.issuer + "/api/accounts/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = ChatGPTProtocol.form(fields)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        try ChatGPTProtocol.checkHTTP(response)
        let tokens = try JSONDecoder().decode(ChatGPTTokens.self, from: data)
        guard tokens.tokenType.lowercased() == "bearer", !tokens.accessToken.isEmpty, tokens.expiresIn > 0 else {
            throw ChatGPTError.message("ChatGPT 登录信息无效，请重新连接")
        }
        return tokens
    }
}
