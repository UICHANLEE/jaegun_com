import Foundation

enum NativeAPIError: LocalizedError {
    case response(Int), invalidData, sessionExpired, security(String)
    var errorDescription: String? {
        switch self {
        case .response(let code):
            if code == 401 { return "로그인이 만료되었습니다. 다시 로그인해 주세요." }
            if code == 403 { return "동의 또는 접근 권한을 확인해 주세요." }
            if code == 429 { return "요청이 많습니다. 잠시 후 다시 시도해 주세요." }
            return "서버 요청이 실패했습니다 (\(code)). 다시 시도해 주세요."
        case .invalidData: return "서버 응답을 확인하지 못했습니다."
        case .sessionExpired: return "로그인이 만료되었습니다. 다시 로그인해 주세요."
        case .security(let message): return message
        }
    }
}

struct NativeTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

/// All authority is enforced by Supabase RLS and actor-bound RPCs, not decoded claims.
@MainActor final class NativeAPI {
    var tokens: NativeTokens?
    var didRefresh: ((NativeTokens) throws -> Void)?
    private var refreshing: Task<NativeTokens, Error>?
    private let transport: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 45
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    func rows(_ table: String, query: String = "") async throws -> [[String: Any]] {
        try validateIdentifier(table)
        guard let rows = try await request(path: "/rest/v1/\(table)", query: query) as? [[String: Any]] else {
            throw NativeAPIError.invalidData
        }
        return rows
    }

    func rpc(_ name: String, body: [String: Any] = [:]) async throws -> Any {
        try validateIdentifier(name)
        // Mutations are never replayed after authentication failure. UI must reconcile
        // uncertain results before an explicit retry; table reads remain retryable.
        return try await request(path: "/rest/v1/rpc/\(name)", method: "POST", body: body, retry: false)
    }

    func authenticate(grant: String, body: [String: Any]) async throws -> NativeTokens {
        let response = try await request(path: "/auth/v1/token", query: "grant_type=\(grant)", method: "POST", body: body, authenticated: false)
        return try decodeTokens(response)
    }

    func refresh() async throws {
        if let refreshing { tokens = try await refreshing.value; return }
        guard let previous = tokens else { throw NativeAPIError.sessionExpired }
        let task = Task { try await self.authenticate(grant: "refresh_token", body: ["refresh_token": previous.refreshToken]) }
        refreshing = task
        defer { refreshing = nil }
        let updated = try await task.value
        guard tokens?.refreshToken == previous.refreshToken else { throw NativeAPIError.sessionExpired }
        try didRefresh?(updated)
        tokens = updated
    }

    func logout() async throws {
        _ = try await request(path: "/auth/v1/logout", query: "scope=local", method: "POST")
    }

    func verifyUser() async throws {
        _ = try await authenticatedIdentity()
    }

    func authenticatedIdentity() async throws -> (id: String, google: Bool) {
        let value = try await request(path: "/auth/v1/user")
        guard let user = value as? [String: Any], let id = user["id"] as? String, UUID(uuidString: id) != nil,
              user["is_anonymous"] as? Bool != true else { throw NativeAPIError.sessionExpired }
        let identities = user["identities"] as? [[String: Any]] ?? []
        return (id, identities.contains { $0["provider"] as? String == "google" })
    }

    func request(path: String, query: String = "", method: String = "GET", body: [String: Any]? = nil, authenticated: Bool = true, retry: Bool = true) async throws -> Any {
        let authPath = path.hasPrefix("/auth/v1/")
        if authenticated, let token = tokens, token.expiresAt.timeIntervalSinceNow < 60, !authPath { try await refresh() }
        guard var components = URLComponents(url: NativeConfig.url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "opwzujhfsxqaivtbjewg.supabase.co" else {
            throw NativeAPIError.security("서버 설정이 올바르지 않습니다.")
        }
        guard path.hasPrefix("/rest/v1/") || path.hasPrefix("/auth/v1/") else { throw NativeAPIError.invalidData }
        components.path = path
        components.percentEncodedQuery = query.isEmpty ? nil : query
        guard let url = components.url else { throw NativeAPIError.invalidData }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(NativeConfig.key, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if authenticated, let tokens { request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, raw) = try await transport.data(for: request)
        guard let response = raw as? HTTPURLResponse else { throw NativeAPIError.invalidData }
        if response.statusCode == 401, authenticated, retry, tokens != nil, !authPath {
            try await refresh()
            return try await self.request(path: path, query: query, method: method, body: body, authenticated: true, retry: false)
        }
        guard (200..<300).contains(response.statusCode) else { throw NativeAPIError.response(response.statusCode) }
        if data.isEmpty { return NSNull() }
        return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    private func validateIdentifier(_ value: String) throws {
        guard !value.isEmpty, value.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil else { throw NativeAPIError.invalidData }
    }

    private func decodeTokens(_ value: Any) throws -> NativeTokens {
        guard let row = value as? [String: Any], let access = row["access_token"] as? String,
              let refresh = row["refresh_token"] as? String, !access.isEmpty, !refresh.isEmpty,
              let expires = row["expires_in"] as? Double, expires > 0,
              let user = row["user"] as? [String: Any], user["is_anonymous"] as? Bool != true else {
            throw NativeAPIError.invalidData
        }
        return NativeTokens(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(expires))
    }
}
