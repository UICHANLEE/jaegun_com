import XCTest
@testable import JaegunNative

final class NativeSecurityTests: XCTestCase {
    private let routes = ["privacy_policy": "privacy", "sensitive_information": "sensitive", "overseas_transfer": "overseas", "terms_of_service": "terms", "community_guidelines": "community"]
    private var local: [[String: Any]] {
        routes.keys.sorted().map { ["key": $0, "version": "2026-10-14", "title": $0, "sha256": String(repeating: "a", count: 64)] }
    }
    private var remote: [[String: Any]] {
        local.map { item in
            let key = item["key"] as! String
            return ["document_key": key, "version": item["version"]!, "title": item["title"]!, "content_sha256": item["sha256"]!, "document_url": "/legal/\(routes[key]!)/2026-10-14", "required": true, "locale": "ko-KR", "effective_at": "2026-10-13T00:00:00Z", "retired_at": NSNull()]
        }
    }
    private let now = ISO8601DateFormatter().date(from: "2026-10-14T00:00:00Z")!
    func testExactContractPasses() throws { XCTAssertEqual(try NativeConsentContract.validate(remote: remote, bundled: local, now: now).count, 5) }
    func testOrderDoesNotChangeContract() throws { XCTAssertEqual(try NativeConsentContract.validate(remote: remote.reversed(), bundled: local, now: now).count, 5) }
    func testMissingDocumentFails() { XCTAssertThrowsError(try NativeConsentContract.validate(remote: Array(remote.dropLast()), bundled: local, now: now)) }
    func testDuplicateDocumentFails() { var rows = remote; rows[1] = rows[0]; XCTAssertThrowsError(try NativeConsentContract.validate(remote: rows, bundled: local, now: now)) }
    func testUnknownDocumentFails() { reject(field: "document_key", value: "unknown") }
    func testWrongVersionFails() { reject(field: "version", value: "2026-08-30") }
    func testWrongHashFails() { reject(field: "content_sha256", value: String(repeating: "b", count: 64)) }
    func testWrongURLFails() { reject(field: "document_url", value: "https://attacker.invalid/legal") }
    func testWrongTitleFails() { reject(field: "title", value: "changed") }
    func testWrongLocaleFails() { reject(field: "locale", value: "en-US") }
    func testNotRequiredFails() { reject(field: "required", value: false) }
    func testNumericRequiredFails() { reject(field: "required", value: NSNumber(value: 1)) }
    func testFutureEffectiveDateFails() { reject(field: "effective_at", value: "2027-01-01T00:00:00Z") }
    func testMalformedEffectiveDateFails() { reject(field: "effective_at", value: "not-a-date") }
    func testRetiredDocumentFails() { reject(field: "retired_at", value: "2026-10-13T12:00:00Z") }
    func testBundledDuplicatesFail() { var docs = local; docs[1] = docs[0]; XCTAssertThrowsError(try NativeConsentContract.validate(remote: remote, bundled: docs, now: now)) }
    private func reject(field: String, value: Any) { var rows = remote; rows[0][field] = value; XCTAssertThrowsError(try NativeConsentContract.validate(remote: rows, bundled: local, now: now)) }

    func testOAuthExactCallbackPasses() throws {
        let url = URL(string: "https://jaegun-com.vercel.app/auth/callback/social?code=one-use-code&social_intent=known")!
        XCTAssertEqual(try NativeOAuthCallback.authorizationCode(url, expectedIntent: "known"), "one-use-code")
    }
    func testOAuthAttackerHostFails() { rejectCallback("https://attacker.invalid/auth/callback/social?code=code&social_intent=known") }
    func testOAuthWrongIntentFails() { rejectCallback("https://jaegun-com.vercel.app/auth/callback/social?code=code&social_intent=other") }
    func testOAuthDuplicateCodeFails() { rejectCallback("https://jaegun-com.vercel.app/auth/callback/social?code=a&code=b&social_intent=known") }
    func testOAuthDuplicateIntentFails() { rejectCallback("https://jaegun-com.vercel.app/auth/callback/social?code=a&social_intent=known&social_intent=known") }
    func testOAuthImplicitFragmentFails() { rejectCallback("https://jaegun-com.vercel.app/auth/callback/social?code=a&social_intent=known#access_token=untrusted") }
    func testOAuthWrongPathFails() { rejectCallback("https://jaegun-com.vercel.app/auth/callback/other?code=a&social_intent=known") }
    func testOAuthHTTPFails() { rejectCallback("http://jaegun-com.vercel.app/auth/callback/social?code=a&social_intent=known") }
    func testOAuthErrorFails() { rejectCallback("https://jaegun-com.vercel.app/auth/callback/social?code=a&social_intent=known&error=denied") }
    func testOAuthCredentialsFails() { rejectCallback("https://user@jaegun-com.vercel.app/auth/callback/social?code=a&social_intent=known") }
    func testOAuthEmptyCodeFails() { rejectCallback("https://jaegun-com.vercel.app/auth/callback/social?code=&social_intent=known") }
    private func rejectCallback(_ value: String) { XCTAssertThrowsError(try NativeOAuthCallback.authorizationCode(URL(string: value)!, expectedIntent: "known")) }
}
