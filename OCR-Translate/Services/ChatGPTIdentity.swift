import Foundation
import Security

struct ChatGPTDiscovery: Decodable {
    let issuer: String
    let jwksURI: URL
    let revocationEndpoint: URL
    enum CodingKeys: String, CodingKey {
        case issuer, jwksURI = "jwks_uri", revocationEndpoint = "revocation_endpoint"
    }

    static func load(session: URLSession) async throws -> Self {
        let (data, response) = try await session.data(from: URL(string: ChatGPTProtocol.issuer + "/.well-known/openid-configuration")!)
        try ChatGPTProtocol.checkHTTP(response)
        let discovery = try JSONDecoder().decode(Self.self, from: data)
        func trusted(_ url: URL) -> Bool {
            url.scheme == "https" && url.host == "auth.openai.com" && url.user == nil && url.password == nil
        }
        guard discovery.issuer == ChatGPTProtocol.issuer,
              trusted(discovery.jwksURI), trusted(discovery.revocationEndpoint) else {
            throw ChatGPTError.message("ChatGPT 登录服务配置无效")
        }
        return discovery
    }
}

enum ChatGPTIdentity {
    struct Claims: Decodable {
        let iss: String
        let sub: String
        let aud: Audience
        let exp: Double
        let nonce: String
        let email: String?
        let azp: String?
    }

    enum Audience: Decodable {
        case one(String), many([String])
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) { self = .one(value) }
            else { self = .many(try container.decode([String].self)) }
        }
        var values: [String] {
            switch self { case .one(let value): [value]; case .many(let values): values }
        }
    }

    struct Header: Decodable { let alg: String; let kid: String }
    struct JWK: Decodable { let kty: String; let kid: String; let n: String?; let e: String?; let alg: String?; let use: String? }
    struct JWKS: Decodable { let keys: [JWK] }

    static func validate(_ token: String, clientID: String, nonce: String,
                         keys: JWKS, now: Date = Date()) throws -> Claims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let headerData = ChatGPTProtocol.decodeBase64URL(parts[0]),
              let claimsData = ChatGPTProtocol.decodeBase64URL(parts[1]),
              let signature = ChatGPTProtocol.decodeBase64URL(parts[2]) else {
            throw ChatGPTError.message("ChatGPT 身份凭据无效")
        }
        let header = try JSONDecoder().decode(Header.self, from: headerData)
        guard header.alg == "RS256",
              let jwk = keys.keys.first(where: { $0.kid == header.kid && $0.kty == "RSA" }),
              jwk.alg == nil || jwk.alg == "RS256", jwk.use == nil || jwk.use == "sig",
              let n = jwk.n.flatMap(ChatGPTProtocol.decodeBase64URL),
              let e = jwk.e.flatMap(ChatGPTProtocol.decodeBase64URL) else {
            throw ChatGPTError.message("无法验证 ChatGPT 身份签名")
        }
        let encoded = der(0x30, integer(n) + integer(e))
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(encoded as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic
        ] as CFDictionary, &error),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data((parts[0] + "." + parts[1]).utf8) as CFData,
                                    signature as CFData, &error) else {
            throw ChatGPTError.message("ChatGPT 身份签名验证失败")
        }
        let claims = try JSONDecoder().decode(Claims.self, from: claimsData)
        guard claims.iss == ChatGPTProtocol.issuer, claims.aud.values.contains(clientID),
              claims.aud.values.count == 1 || claims.azp == clientID,
              claims.exp > now.timeIntervalSince1970, claims.nonce == nonce, !claims.sub.isEmpty else {
            throw ChatGPTError.message("ChatGPT 身份验证不匹配或已过期，请重新登录")
        }
        return claims
    }

    private static func integer(_ data: Data) -> Data {
        var bytes = Data(data.drop(while: { $0 == 0 }))
        if bytes.first.map({ $0 & 0x80 != 0 }) == true { bytes.insert(0, at: 0) }
        return der(0x02, bytes)
    }

    private static func der(_ tag: UInt8, _ data: Data) -> Data {
        var result = Data([tag])
        if data.count < 128 { result.append(UInt8(data.count)) }
        else {
            var length = data.count
            var bytes: [UInt8] = []
            while length > 0 { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 }
            result.append(0x80 | UInt8(bytes.count)); result.append(contentsOf: bytes)
        }
        result.append(data)
        return result
    }
}

// Subscription credentials are separate from the legacy API-key preferences.
enum ChatGPTCredentialStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.ngmproofread.chatgpt",
        kSecAttrAccount as String: "accounts"
    ]

    static func read() throws -> [ChatGPTAccount] {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ChatGPTError.message("无法读取钥匙串中的 ChatGPT 登录信息")
        }
        return try JSONDecoder().decode([ChatGPTAccount].self, from: data)
    }

    static func save(_ accounts: [ChatGPTAccount]) throws {
        let data = try JSONEncoder().encode(accounts)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else {
                throw ChatGPTError.message("无法将 ChatGPT 登录信息保存到钥匙串")
            }
        } else if status != errSecSuccess {
            throw ChatGPTError.message("无法更新钥匙串中的 ChatGPT 登录信息")
        }
    }
}
