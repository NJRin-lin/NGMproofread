import Foundation
import CryptoKit
import Security

enum ChatGPTError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

struct ChatGPTAccount: Codable, Identifiable {
    var id: String { clientID }
    let clientID: String
    let subject: String
    let email: String
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expiresAt: Date
    var scopes: [String]
    var selectedModel: String?
    var canUsePlan: Bool { scopes.contains("chatgpt.tokens.use.direct") && !accessToken.isEmpty }
    var label: String { "\(email.isEmpty ? "ChatGPT 账号" : email) · \(clientID.suffix(6))" }
}

struct ChatGPTModel: Decodable, Identifiable {
    let slug: String
    let displayName: String
    let visibility: String
    var id: String { slug }
    enum CodingKeys: String, CodingKey {
        case slug, visibility
        case displayName = "display_name"
    }
}

struct ChatGPTTokens: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Double
    let scope: String?
    let tokenType: String
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", idToken = "id_token"
        case expiresIn = "expires_in", tokenType = "token_type", scope
    }
}

enum ChatGPTProtocol {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ value: String) -> Data? {
        let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }

    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ChatGPTError.message("无法生成登录验证信息，请重试")
        }
        return base64URL(Data(bytes))
    }

    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }

    static func authorizeURL(hostID: String, redirect: String, state: String, nonce: String,
                             verifier: String, account: ChatGPTAccount?) -> URL {
        var fields = ["client_id": account?.clientID ?? "dynamic_agent_client",
                      "ext_agent_host_id": hostID, "redirect_uri": redirect,
                      "response_type": "code", "scope": scopes, "resource": resource,
                      "state": state, "nonce": nonce, "code_challenge_method": "S256",
                      "code_challenge": base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))]
        if let account {
            if let hint = account.idToken { fields["id_token_hint"] = hint }
            if !account.email.isEmpty { fields["login_hint"] = account.email }
            if !account.canUsePlan { fields["prompt"] = "consent" }
        } else {
            fields["agent_name_hint"] = "NGM proofread"
        }
        var parts = URLComponents(string: issuer + "/api/accounts/authorize")!
        parts.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url!
    }

    static func callback(_ url: URL, state: String, account: ChatGPTAccount?) throws -> (code: String, clientID: String) {
        guard url.host == "127.0.0.1", url.path == "/auth/callback",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw ChatGPTError.message("登录回调地址无效")
        }
        // Reject duplicates rather than accepting an ambiguous state or client ID.
        var values: [String: String] = [:]
        for item in items {
            guard values[item.name] == nil else { throw ChatGPTError.message("登录回调包含重复参数") }
            values[item.name] = item.value ?? ""
        }
        guard values["state"] == state else { throw ChatGPTError.message("登录验证不匹配，请重新连接") }
        if values["error"] != nil { throw ChatGPTError.message("登录或授权未完成，请重新连接 ChatGPT") }
        let clientID = values["client_id"] ?? account?.clientID ?? ""
        guard !clientID.isEmpty, clientID != "dynamic_agent_client",
              account == nil || account?.clientID == clientID,
              let code = values["code"], !code.isEmpty else {
            throw ChatGPTError.message("ChatGPT 注册未完成或账号不匹配，请重新登录")
        }
        return (code, clientID)
    }

    static func checkHTTP(_ response: URLResponse, data: Data = Data()) throws {
        guard let http = response as? HTTPURLResponse else { throw ChatGPTError.message("ChatGPT 响应无效") }
        guard (200..<300).contains(http.statusCode) else {
            // Never display raw auth responses, which can contain credentials.
            switch http.statusCode {
            case 401: throw ChatGPTError.message("ChatGPT 登录已失效，请在设置中重新连接")
            case 403: throw ChatGPTError.message("此账号尚未获准使用 ChatGPT 计划，请检查授权和账号资格")
            case 429: throw ChatGPTError.message("ChatGPT 使用额度已达上限或请求过于频繁，请稍后重试")
            default: throw ChatGPTError.message("ChatGPT 请求失败（HTTP \(http.statusCode)），请稍后重试")
            }
        }
    }

    static func responseRequest(token: String, model: String, instructions: String, text: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: resource + "/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120
        // Subscription inference does not accept temperature or max_output_tokens.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "instructions": instructions,
            "input": [["role": "user", "content": text]], "store": false, "stream": true
        ])
        return request
    }
}

// Collect only a completed Responses stream. Partial output must never be cached as success.
struct ChatGPTStream {
    private(set) var output = ""
    private(set) var completed = false
    private var eventData: [String] = []

    mutating func line(_ line: String) throws {
        if line.isEmpty {
            guard !eventData.isEmpty else { return }
            let data = eventData.joined(separator: "\n")
            eventData = []
            guard data != "[DONE]", let bytes = data.data(using: .utf8) else { return }
            guard let event = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let type = event["type"] as? String else { throw ChatGPTError.message("ChatGPT 响应格式无效") }
            switch type {
            case "response.output_text.delta": output += event["delta"] as? String ?? ""
            case "response.completed": completed = true
            case "response.failed", "response.incomplete", "error":
                let response = event["response"] as? [String: Any]
                let error = (response?["error"] as? [String: Any]) ?? (event["error"] as? [String: Any])
                let code = error?["code"] as? String ?? event["code"] as? String ?? ""
                if code.contains("usage_limit") || code.contains("sharing_unavailable") {
                    throw ChatGPTError.message("ChatGPT 计划额度已用完或暂不可用，请查看 ChatGPT 的使用情况设置")
                }
                throw ChatGPTError.message("ChatGPT 未完成此次回复，请重试；此前的部分内容不会作为结果保存")
            default: break
            }
        } else if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.first == " " { value.removeFirst() }
            eventData.append(value)
        }
    }

    mutating func finish() throws -> String {
        try line("")
        guard completed, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatGPTError.message("ChatGPT 回复中断或为空，请重试")
        }
        return output
    }
}
