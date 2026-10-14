import Foundation
import Combine
import Security
import CryptoKit
import AuthenticationServices
import UIKit

private enum NativeKeychain {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.uichanlee.jaegun.native.auth", kSecAttrAccount as String: "session"]
    static func read() throws -> NativeTokens? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw NativeAPIError.security("기기의 안전한 로그인 저장소에 접근하지 못했습니다.") }
        return try JSONDecoder().decode(NativeTokens.self, from: data)
    }
    static func save(_ tokens: NativeTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let fields: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, fields as CFDictionary)
        if result == errSecItemNotFound {
            var item = query
            fields.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw NativeAPIError.security("로그인 정보를 안전하게 저장하지 못했습니다.") }
        } else if result != errSecSuccess { throw NativeAPIError.security("로그인 정보를 안전하게 저장하지 못했습니다.") }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NativeAPIError.security("기기 로그인 정보를 지우지 못했습니다. 잠금을 해제하고 다시 시도해 주세요.") }
    }
}

@MainActor final class NativeSession: NSObject, ObservableObject {
    @Published var signedIn = false
    @Published var loading = false
    @Published var error: String?
    @Published var consentRequired = true
    @Published var context: [String: Any] = [:]
    @Published var requiredDocuments: [[String: Any]] = []
    let api = NativeAPI()
    private var authSession: ASWebAuthenticationSession?
    private var authPresentationContext: NativeAuthPresentationContext?
    private var epoch = UUID()
    private var privacy: [String: Any] = [:]

    override init() {
        super.init()
        api.didRefresh = { try NativeKeychain.save($0) }
    }

    func restore() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            api.tokens = try NativeKeychain.read()
            if api.tokens != nil {
                try await api.refresh()
                try await api.verifyUser()
                signedIn = true
            }
            try await loadState()
        } catch {
            self.error = error.localizedDescription
            // A network failure is not logout. Never erase refresh credentials on timeout.
            context = [:]; consentRequired = true
        }
    }

    func signIn(email: String, password: String) async {
        guard !loading else { return }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), !password.isEmpty else { error = "이메일과 비밀번호를 입력해 주세요."; return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let tokens = try await api.authenticate(grant: "password", body: ["email": email, "password": password])
            try NativeKeychain.save(tokens)
            epoch = UUID(); context = [:]; privacy = [:]; consentRequired = true; api.tokens = tokens; signedIn = true
            try await loadState()
        } catch { self.error = error.localizedDescription }
    }

    func googleSignIn() async {
        guard !loading else { return }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive })
            .flatMap(\.windows).first(where: { $0.isKeyWindow && !$0.isHidden }) else {
            error = "로그인 창을 표시할 앱 화면을 찾지 못했습니다. 앱을 다시 열어 주세요. (AUTH-WINDOW)"
            return
        }
        loading = true; error = nil
        let presentation = NativeAuthPresentationContext(window: window)
        authPresentationContext = presentation
        defer { loading = false; authSession = nil; authPresentationContext = nil }
        do {
            let verifier = try randomString()
            let intent = UUID().uuidString.lowercased()
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
            let callbackHost = "jaegun-com.vercel.app"
            let callbackPath = "/auth/callback/social"
            var callback = URLComponents()
            callback.scheme = "https"; callback.host = callbackHost; callback.path = callbackPath
            callback.queryItems = [URLQueryItem(name: "social_intent", value: intent)]
            var authorize = URLComponents(url: NativeConfig.url.appendingPathComponent("auth/v1/authorize"), resolvingAgainstBaseURL: false)!
            authorize.queryItems = [
                URLQueryItem(name: "provider", value: "google"),
                URLQueryItem(name: "redirect_to", value: callback.url!.absoluteString),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "s256"),
                URLQueryItem(name: "scopes", value: "openid email profile"),
                URLQueryItem(name: "prompt", value: "select_account")
            ]
            let result: URL = try await withCheckedThrowingContinuation { continuation in
                var completed = false
                let complete: (Result<URL, Error>) -> Void = { result in
                    guard !completed else { return }
                    completed = true
                    continuation.resume(with: result)
                }
                let session = ASWebAuthenticationSession(url: authorize.url!, callback: .https(host: callbackHost, path: callbackPath)) { url, failure in
                    Task { @MainActor in
                        if let failure { complete(.failure(failure)) }
                        else if let url { complete(.success(url)) }
                        else { complete(.failure(NativeAPIError.invalidData)) }
                    }
                }
                session.presentationContextProvider = presentation
                self.authSession = session
                if !session.start() { complete(.failure(NativeAPIError.security("Google 인증 창을 시작하지 못했습니다. (AUTH-START)"))) }
            }
            let code = try NativeOAuthCallback.authorizationCode(result, expectedIntent: intent)
            let tokens = try await api.authenticate(grant: "pkce", body: ["auth_code": code, "code_verifier": verifier])
            try NativeKeychain.save(tokens)
            epoch = UUID(); context = [:]; privacy = [:]; consentRequired = true; api.tokens = tokens; signedIn = true
            try await loadState()
        } catch {
            let failure = error as NSError
            if failure.domain == ASWebAuthenticationSessionErrorDomain {
                self.error = failure.code == 1
                    ? "Google 로그인이 취소되었습니다. 선택한 동의는 유지됩니다."
                    : "iOS에서 Google 인증 창을 열지 못했습니다. (AUTH-\(failure.code))"
            } else { self.error = error.localizedDescription }
        }
    }

    func signOut() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        var serverFailed = false
        do { if api.tokens != nil { try await api.logout() } } catch { serverFailed = true }
        do {
            try NativeKeychain.delete()
            epoch = UUID(); api.tokens = nil; signedIn = false; context = [:]; privacy = [:]; consentRequired = true
            if serverFailed { error = "이 기기에서는 로그아웃했습니다. 네트워크 문제로 서버 세션 종료는 확인하지 못했습니다." }
        } catch { self.error = error.localizedDescription }
    }

    /// Called only after the native UI explicitly confirms all five documents and 14+ attestation.
    func acceptConsents() async {
        guard signedIn, !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let previous = requiredDocuments
            let current = try await validatedDocuments()
            guard fingerprint(previous) == fingerprint(current) else {
                requiredDocuments = current
                throw NativeAPIError.security("동의 문서가 변경되었습니다. 다시 읽고 확인해 주세요.")
            }
            var versions: [String: String] = [:]
            current.forEach { versions[$0["document_key"] as! String] = $0["version"] as? String }
            let visibility = privacy["directory_visibility"] as? [String: Any] ?? [:]
            _ = try await api.rpc("save_my_privacy_preferences_v2", body: [
                "p_required_consents": versions,
                "p_avatar_visible": visibility["avatar"] as? Bool ?? false,
                "p_church_title_visible": visibility["church_title"] as? Bool ?? false,
                "p_email_visible": visibility["email"] as? Bool ?? false,
                "p_bio_visible": visibility["bio"] as? Bool ?? false
            ])
            try await loadState()
        } catch { self.error = error.localizedDescription }
    }

    private func loadState() async throws {
        let generation = epoch
        let documents = try await validatedDocuments()
        guard generation == epoch else { return }
        requiredDocuments = documents
        guard signedIn else { return }
        let state = try await api.rpc("get_my_safety_privacy_state")
        guard generation == epoch, let state = state as? [String: Any] else { throw NativeAPIError.invalidData }
        privacy = state
        consentRequired = state["consent_gate_open"] as? Bool != true
        guard !consentRequired else { context = [:]; return }
        let value = try await api.rpc("get_my_context")
        guard generation == epoch else { return }
        if let row = value as? [String: Any] { context = row }
        else if let rows = value as? [[String: Any]], let row = rows.first { context = row }
        else { throw NativeAPIError.invalidData }
    }

    private func validatedDocuments() async throws -> [[String: Any]] {
        let remote = try await api.rows("consent_documents", query: "select=document_key,version,locale,title,document_url,content_sha256,required,effective_at,retired_at&locale=eq.ko-KR&required=eq.true&retired_at=is.null&order=document_key")
        guard let source = Bundle.main.url(forResource: "LegalDocuments", withExtension: "json"),
              let local = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [[String: Any]] else { throw NativeAPIError.security("필수 동의 문서 구성을 확인하지 못했습니다.") }
        return try NativeConsentContract.validate(remote: remote, bundled: local)
    }

    private func fingerprint(_ documents: [[String: Any]]) -> [String] {
        documents.map { "\($0["document_key"] ?? "")@\($0["version"] ?? ""):\($0["content_sha256"] ?? "")" }.sorted()
    }
    private func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw NativeAPIError.security("안전한 로그인 요청을 생성하지 못했습니다.") }
        return Data(bytes).base64URLEncoded()
    }
}

@MainActor private final class NativeAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: UIWindow
    init(window: UIWindow) { self.window = window }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
}

enum NativeConsentContract {
    static func validate(remote: [[String: Any]], bundled local: [[String: Any]], now: Date = Date()) throws -> [[String: Any]] {
        guard local.count == 5, remote.count == 5 else { throw NativeAPIError.security("필수 동의 문서 구성을 확인하지 못했습니다.") }
        let expectedKeys: Set<String> = ["privacy_policy", "sensitive_information", "overseas_transfer", "terms_of_service", "community_guidelines"]
        guard Set(remote.compactMap { $0["document_key"] as? String }) == expectedKeys,
              Set(local.compactMap { $0["key"] as? String }) == expectedKeys else { throw NativeAPIError.security("필수 동의 문서 구성이 변경되었습니다.") }
        let routes = ["privacy_policy": "privacy", "sensitive_information": "sensitive", "overseas_transfer": "overseas", "terms_of_service": "terms", "community_guidelines": "community"]
        for row in remote {
            guard let key = row["document_key"] as? String,
                  let own = local.first(where: { $0["key"] as? String == key }),
                  let version = own["version"] as? String,
                  row["version"] as? String == version,
                  row["title"] as? String == own["title"] as? String,
                  row["content_sha256"] as? String == own["sha256"] as? String,
                  let hash = row["content_sha256"] as? String,
                  hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  row["document_url"] as? String == "/legal/\(routes[key]!)/\(version)",
                  let required = row["required"] as? NSNumber,
                  CFGetTypeID(required) == CFBooleanGetTypeID(), required.boolValue,
                  row["locale"] as? String == "ko-KR",
                  let effective = row["effective_at"] as? String,
                  Self.parseDate(effective).map({ $0 <= now }) == true,
                  row["retired_at"] == nil || row["retired_at"] is NSNull else {
                throw NativeAPIError.security("동의 문서의 버전 또는 무결성을 확인하지 못했습니다. 앱 업데이트를 확인해 주세요.")
            }
        }
        return remote
    }

    private static func parseDate(_ value: String) -> Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

enum NativeOAuthCallback {
    static func authorizationCode(_ result: URL, expectedIntent: String) throws -> String {
        guard !expectedIntent.isEmpty, let returned = URLComponents(url: result, resolvingAgainstBaseURL: false),
              returned.scheme == "https", returned.host == "jaegun-com.vercel.app", returned.port == nil,
              returned.user == nil, returned.password == nil, returned.fragment == nil,
              returned.path == "/auth/callback/social",
              returned.queryItems?.contains(where: { $0.name == "error" || $0.name == "error_description" }) != true,
              returned.queryItems?.filter({ $0.name == "social_intent" }).count == 1,
              returned.queryItems?.first(where: { $0.name == "social_intent" })?.value == expectedIntent,
              returned.queryItems?.filter({ $0.name == "code" }).count == 1,
              let code = returned.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw NativeAPIError.security("Google 로그인 반환 정보를 확인하지 못했습니다. 다시 시작해 주세요.")
        }
        return code
    }
}

private extension Data {
    func base64URLEncoded() -> String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
