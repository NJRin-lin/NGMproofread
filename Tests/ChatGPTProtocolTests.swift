// Offline contract/security tests. No account, network, or user credentials required.
import Foundation
import Security

@main
enum ChatGPTProtocolTests {
    static var passed = 0

    static func check(_ description: String, _ body: () throws -> Void) rethrows {
        try body(); passed += 1
        print("PASS \(description)")
    }

    static func require(_ value: Bool) {
        precondition(value, "Expectation failed")
    }

    static func rejects(_ body: () throws -> Void) {
        do { try body() } catch { return }
        preconditionFailure("Expected rejection")
    }

    static func account() -> ChatGPTAccount {
        ChatGPTAccount(clientID: "oaiapp_test", subject: "subject", email: "fixture@example.invalid",
                       accessToken: "fixture-token", refreshToken: nil, idToken: "fixture-id-token",
                       expiresAt: .distantFuture, scopes: ["chatgpt.tokens.use.direct"], selectedModel: "account-model")
    }

    static func main() throws {
        try check("PKCE random values and URL encoding") {
            let first = try ChatGPTProtocol.random()
            let second = try ChatGPTProtocol.random()
            require(first != second && first.count == 43)
            let url = ChatGPTProtocol.authorizeURL(hostID: "urn:uuid:fixture", redirect: "http://127.0.0.1:12345/auth/callback",
                state: first, nonce: second, verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", account: nil)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
            require(fields["client_id"] == "dynamic_agent_client")
            require(fields["agent_name_hint"] == "NGM proofread")
            require(fields["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
            require(fields["resource"] == "https://api.openai.com/v1")
            require(fields["scope"]!.contains("chatgpt.tokens.use.direct"))
        }
        check("Returning login uses issued registration and matching identity hint") {
            let url = ChatGPTProtocol.authorizeURL(hostID: "host", redirect: "redirect", state: "state",
                nonce: "nonce", verifier: "verifier", account: account())
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            require(items.first(where: { $0.name == "client_id" })?.value == "oaiapp_test")
            require(!items.contains(where: { $0.name == "agent_name_hint" }))
            require(items.first(where: { $0.name == "id_token_hint" })?.value == "fixture-id-token")
        }
        try check("Valid first registration callback") {
            let result = try ChatGPTProtocol.callback(URL(string: "http://127.0.0.1/auth/callback?code=code&state=state&client_id=oaiapp_new")!, state: "state", account: nil)
            require(result.clientID == "oaiapp_new" && result.code == "code")
        }
        check("Reject callback state, duplicate parameters, denied consent and missing registration") {
            for query in ["code=x&state=wrong&client_id=oaiapp_new", "code=x&state=state&state=state&client_id=oaiapp_new",
                          "error=access_denied&state=state", "code=x&state=state", "code=x&state=state&client_id=dynamic_agent_client"] {
                rejects { _ = try ChatGPTProtocol.callback(URL(string: "http://127.0.0.1/auth/callback?" + query)!, state: "state", account: nil) }
            }
        }
        try check("Reauthorization keeps client ID and rejects a different registration") {
            let result = try ChatGPTProtocol.callback(URL(string: "http://127.0.0.1/auth/callback?code=x&state=state")!, state: "state", account: account())
            require(result.clientID == account().clientID)
            rejects { _ = try ChatGPTProtocol.callback(URL(string: "http://127.0.0.1/auth/callback?code=x&state=state&client_id=other")!, state: "state", account: account()) }
        }
        check("Identity-only account cannot use plan") {
            var identity = account(); identity.scopes = ["openid", "profile", "email"]
            require(!identity.canUsePlan)
            let url = ChatGPTProtocol.authorizeURL(hostID: "host", redirect: "redirect", state: "state",
                nonce: "nonce", verifier: "verifier", account: identity)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            require(items.first(where: { $0.name == "prompt" })?.value == "consent")
        }
        try check("Subscription request uses Responses and supported fields only") {
            let request = try ChatGPTProtocol.responseRequest(token: "fixture-token", model: "account-model", instructions: "日文翻译", text: "こんにちは")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            require(request.url?.absoluteString == "https://api.openai.com/v1/responses")
            require(body["store"] as? Bool == false && body["stream"] as? Bool == true)
            require(Set(body.keys) == Set(["model", "instructions", "input", "store", "stream"]))
            require(body["model"] as? String == "account-model")
        }
        check("Form fields encode +, &, = and non-ASCII without injection") {
            let data = ChatGPTProtocol.form(["code": "a+b&c=あ"])
            require(String(data: data, encoding: .utf8) == "code=a%2Bb%26c%3D%E3%81%82")
        }
        try check("Completed SSE stream joins translated text") {
            var stream = ChatGPTStream()
            for line in [": comment", "event: response.output_text.delta", "data: {\"type\":\"response.output_text.delta\",\"delta\":\"你好\"}", "",
                         "data: {\"type\":\"response.output_text.delta\",\"delta\":\"。\"}", "",
                         "data: {\"type\":\"response.completed\"}", "", "data: [DONE]", ""] { try stream.line(line) }
            require(try stream.finish() == "你好。")
        }
        check("Partial output and DONE alone are not success") {
            rejects {
                var stream = ChatGPTStream()
                try stream.line("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}")
                try stream.line(""); try stream.line("data: [DONE]"); _ = try stream.finish()
            }
        }
        check("Failure after output, incomplete and malformed events are rejected") {
            for event in ["{\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}",
                          "{\"type\":\"response.incomplete\"}", "invalid json"] {
                rejects { var stream = ChatGPTStream(); try stream.line("data: " + event); try stream.line("") }
            }
        }
        try testIdentity()
        print("\(passed) ChatGPT contract/security checks passed")
    }

    static func testIdentity() throws {
        var keyError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                                      kSecAttrKeySizeInBits: 2048,
                                                      kSecAttrIsPermanent: false] as CFDictionary, &keyError) else {
            throw ChatGPTError.message("测试用临时 RSA 密钥生成失败：\(keyError?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        let publicKey = SecKeyCopyPublicKey(privateKey)!
        let der = SecKeyCopyExternalRepresentation(publicKey, nil)! as Data
        var offset = 0
        func element() -> Data {
            offset += 1
            var length = Int(der[offset]); offset += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f; length = 0
                for _ in 0..<count { length = (length << 8) | Int(der[offset]); offset += 1 }
            }
            let value = der.subdata(in: offset..<(offset + length)); offset += length
            return value
        }
        // Skip the sequence header, then read the modulus and exponent.
        offset = 1
        let length = Int(der[offset]); offset += 1
        if length & 0x80 != 0 { offset += length & 0x7f }
        let n = element(), e = element()
        let keysData = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "RSA", "kid": "fixture", "alg": "RS256", "use": "sig",
                                "n": ChatGPTProtocol.base64URL(n), "e": ChatGPTProtocol.base64URL(e)]]])
        let keys = try JSONDecoder().decode(ChatGPTIdentity.JWKS.self, from: keysData)
        let header = ChatGPTProtocol.base64URL(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "fixture"]))
        func token(_ values: [String: Any]) throws -> String {
            let payload = ChatGPTProtocol.base64URL(try JSONSerialization.data(withJSONObject: values))
            let input = header + "." + payload
            let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)! as Data
            return input + "." + ChatGPTProtocol.base64URL(signature)
        }
        let claims: [String: Any] = ["iss": ChatGPTProtocol.issuer, "sub": "fixture-subject", "aud": "oaiapp_test",
                                     "nonce": "fixture-nonce", "exp": Date().addingTimeInterval(3600).timeIntervalSince1970]
        let valid = try token(claims)
        try check("JWT signature and identity claims validated") {
            let result = try ChatGPTIdentity.validate(valid, clientID: "oaiapp_test", nonce: "fixture-nonce", keys: keys)
            require(result.sub == "fixture-subject")
        }
        try check("JWT wrong issuer/audience/nonce and expired identity rejected") {
            for (field, value) in [("iss", "https://untrusted.invalid" as Any), ("aud", "other" as Any),
                                    ("nonce", "wrong" as Any), ("exp", 1 as Any)] {
                var altered = claims; altered[field] = value
                let signed = try token(altered)
                rejects { _ = try ChatGPTIdentity.validate(signed, clientID: "oaiapp_test", nonce: "fixture-nonce", keys: keys) }
            }
        }
        check("JWT tampered signature rejected") {
            let parts = valid.split(separator: ".")
            let bad = parts[0] + "." + parts[1] + "." + ChatGPTProtocol.base64URL(Data(repeating: 0, count: 256))
            rejects { _ = try ChatGPTIdentity.validate(String(bad), clientID: "oaiapp_test", nonce: "fixture-nonce", keys: keys) }
        }
    }
}
