import Foundation
import Security

enum PocketError: LocalizedError {
    case message(String)
    case attachmentRejected(String)
    var errorDescription: String? { switch self { case let .message(text), let .attachmentRejected(text): return text } }
}
enum Keychain {
    static let service = Bundle.main.bundleIdentifier ?? "com.example.HarnessPocket"
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func set(_ account: String, _ value: String?) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        guard let value else { SecItemDelete(base as CFDictionary); return }
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw PocketError.message(L10n.format("認証情報を保存できませんでした（%lld）", Int64(update))) }
        var query = base
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw PocketError.message(L10n.format("認証情報を安全に保存できませんでした（%lld）", Int64(status))) }
    }
}
@MainActor final class API {
    var baseURL: URL
    var token: String?
    let session: URLSession
    init(url: URL, token: String? = nil) {
        self.baseURL = url; self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 300
        session = URLSession(configuration: config)
    }
    static func validate(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, (url.path.isEmpty || url.path == "/") else { throw PocketError.message(L10n.string("https:// から始まるアプリ用接続先を入力してください")) }
        if url.scheme == "https" { return url }
        #if DEBUG
        if url.scheme == "http", ["127.0.0.1", "localhost"].contains(host) { return url }
        #endif
        throw PocketError.message(L10n.string("暗号化されたHTTPS接続先が必要です"))
    }
    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, query: [URLQueryItem] = []) async throws -> [String: Any] {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        // The gateway's URLSearchParams treats a literal plus as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let url = components.url!
        var req = URLRequest(url: url); req.httpMethod = method
        if path.hasSuffix("/messages") { req.timeoutInterval = 180 }
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw PocketError.message(L10n.string("サーバーからの応答がありません")) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            if json["code"] as? String == "session/attachment-invalid" { throw PocketError.attachmentRejected(L10n.string(json["error"] as? String ?? "添付を受け付けられませんでした")) }
            let message = (json["error"] as? String).map { text in
                let prefix = "Apple通知エラー: "
                if text.hasPrefix(prefix) { return L10n.format("Apple通知エラー: %@", String(text.dropFirst(prefix.count))) }
                return L10n.string(text)
            }
            throw PocketError.message(message ?? L10n.format("接続エラー（%lld）", Int64(http.statusCode)))
        }
        return json
    }
    func socket() -> URLSessionWebSocketTask {
        var parts = URLComponents(url: baseURL.appendingPathComponent("v1/events"), resolvingAgainstBaseURL: false)!
        parts.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        var req = URLRequest(url: parts.url!)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return session.webSocketTask(with: req)
    }
}
