import XCTest
@testable import JaegunNative

final class NativeSecurityTests: XCTestCase {
    func testSensitiveProofUsesServerTimeAndFailsClosed() {
        XCTAssertTrue(NativeSensitiveAuthStatus.isVerified(["verified": true, "expires_at": "2026-10-14T10:05:00Z", "server_now": "2026-10-14T10:00:00Z"]))
        XCTAssertFalse(NativeSensitiveAuthStatus.isVerified(["verified": true, "expires_at": "2026-10-14T10:00:00Z", "server_now": "2026-10-14T10:00:00Z"]))
        XCTAssertFalse(NativeSensitiveAuthStatus.isVerified(["verified": false, "expires_at": "2026-10-14T10:05:00Z", "server_now": "2026-10-14T10:00:00Z"]))
        XCTAssertFalse(NativeSensitiveAuthStatus.isVerified(["verified": 1, "expires_at": "2026-10-14T10:05:00Z", "server_now": "2026-10-14T10:00:00Z"]))
        XCTAssertFalse(NativeSensitiveAuthStatus.isVerified(["verified": true, "server_now": "invalid"]))
    }
    func testPhoneApprovalPolicyDoesNotExpandScopeOrAllowSelfReview() {
        let context: [String: Any] = ["profile": ["id": "actor"], "membership": ["status": "active", "role": "minister", "organization_id": "church-a"]]
        let valid: [String: Any] = ["status": "pending", "user_id": "applicant", "organization_id": "church-a", "requested_role": "member"]
        XCTAssertTrue(NativeApprovalPolicy.reviewable(valid, context: context))
        var other = valid; other["organization_id"] = "church-b"; XCTAssertFalse(NativeApprovalPolicy.reviewable(other, context: context))
        other = valid; other["requested_role"] = "executive"; XCTAssertFalse(NativeApprovalPolicy.reviewable(other, context: context))
        other = valid; other["user_id"] = "actor"; XCTAssertFalse(NativeApprovalPolicy.reviewable(other, context: context))
        XCTAssertFalse(NativeApprovalPolicy.validReason("  ", rejecting: true))
    }
    func testEventDraftRequiresHostAndPreservesOperationIdentifier() {
        var draft = NativeEventDraft(scopeId: UUID().uuidString)
        let id = draft.id
        draft.title = "청년부 모임"
        XCTAssertNotNil(draft.validation)
        draft.host = "청년부"
        XCTAssertNil(draft.validation)
        XCTAssertEqual(draft.body["p_id"] as? String, id.uuidString)
        draft.endsAt = draft.startsAt
        XCTAssertNotNil(draft.validation)
        draft.endsAt = draft.startsAt.addingTimeInterval(3600)
        draft.frequency = "weekly"; draft.recurrenceCount = 12
        XCTAssertNotNil(draft.validation)
        draft.weekdays = [1]
        XCTAssertNil(draft.validation)
        draft.capacity = "0"
        XCTAssertNotNil(draft.validation)
    }
    func testCommunityNavigationMatchesWebDestinations() {
        XCTAssertEqual(NativeCommunityNavigation.items.map { $0.1 }, ["홈", "게시판", "채팅", "교회", "AI", "내 정보"])
        XCTAssertEqual(Set(NativeCommunityNavigation.items.map { $0.0 }).count, 6)
    }
    func testConsentDisplayOrderMatchesWeb() {
        let keys = ["community_guidelines", "terms_of_service", "sensitive_information", "privacy_policy", "overseas_transfer"]
        let documents = keys.compactMap { NativeLegalDocument(["key": $0, "version": "2026-10-14"]) }.sorted { $0.displayOrder < $1.displayOrder }
        XCTAssertEqual(documents.map { $0.type }, ["privacy_policy", "sensitive_information", "overseas_transfer", "terms_of_service", "community_guidelines"])
    }
    func testLoginRouteSurvivesGoogleBusyState() {
        for busy in [false, true, false] {
            XCTAssertEqual(NativeRootRoute.resolve(loading: busy, signedIn: false, consentRequired: true, administrator: false, activeMember: false), .login)
        }
    }
    func testConsentRouteSurvivesFailedSaveBusyState() {
        for busy in [false, true, false] {
            XCTAssertEqual(NativeRootRoute.resolve(loading: busy, signedIn: true, consentRequired: true, administrator: true, activeMember: true), .consent)
        }
    }
    func testAdministratorCannotSkipRequiredConsent() {
        XCTAssertEqual(NativeRootRoute.resolve(loading: false, signedIn: true, consentRequired: true, administrator: true, activeMember: false), .consent)
        XCTAssertEqual(NativeRootRoute.resolve(loading: false, signedIn: true, consentRequired: false, administrator: true, activeMember: false), .community)
    }
    func testVerifiedExistingAccountSkipsSignupConsent() {
        XCTAssertEqual(NativeRootRoute.resolve(loading: false, signedIn: true, consentRequired: false, administrator: false, activeMember: true), .community)
        XCTAssertEqual(NativeRootRoute.resolve(loading: false, signedIn: true, consentRequired: true, administrator: false, activeMember: false), .consent)
        XCTAssertEqual(NativeRootRoute.resolve(loading: false, signedIn: true, consentRequired: false, administrator: false, activeMember: false), .onboarding)
    }
    func testConsentConfirmationBindsExactVersionsAndAge() {
        let ids = Set(remote.compactMap(NativeLegalDocument.init).map(\.id))
        XCTAssertTrue(NativeConsentContract.confirmationMatches(documents: remote, acceptedIDs: ids, ageConfirmed: true))
        XCTAssertFalse(NativeConsentContract.confirmationMatches(documents: remote, acceptedIDs: ids, ageConfirmed: false))
        XCTAssertFalse(NativeConsentContract.confirmationMatches(documents: remote, acceptedIDs: Set(ids.dropFirst()), ageConfirmed: true))
        let outdated = Set(ids.map { $0.replacingOccurrences(of: "2026-10-14", with: "2026-08-27") })
        XCTAssertFalse(NativeConsentContract.confirmationMatches(documents: remote, acceptedIDs: outdated, ageConfirmed: true))
    }
    func testDuplicateOrUnknownConsentDoesNotBecomeSignupAcceptance() {
        let ids = Set(remote.compactMap(NativeLegalDocument.init).map(\.id))
        var duplicate = remote; duplicate[0] = duplicate[1]
        XCTAssertFalse(NativeConsentContract.confirmationMatches(documents: duplicate, acceptedIDs: ids, ageConfirmed: true))
        var unknown = remote; unknown[0]["document_key"] = "unapproved-document"
        XCTAssertFalse(NativeConsentContract.confirmationMatches(documents: unknown, acceptedIDs: ids, ageConfirmed: true))
    }
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
    func testOAuthEmptyFragmentPasses() throws {
        let callback = URL(string: "https://jaegun-com.vercel.app/auth/callback/social?code=one-use-code&social_intent=known#")!
        XCTAssertEqual(try NativeOAuthCallback.authorizationCode(callback, expectedIntent: "known"), "one-use-code")
    }
    func testOAuthNonEmptyFragmentFailsWithSafeDiagnostic() {
        for fragment in ["access_token=secret-token", "error=denied", "%20", "code=secret-code"] {
            let callback = URL(string: "https://jaegun-com.vercel.app/auth/callback/social?code=secret-code&social_intent=known#\(fragment)")!
            XCTAssertThrowsError(try NativeOAuthCallback.authorizationCode(callback, expectedIntent: "known")) { error in
                XCTAssertTrue(error.localizedDescription.contains("CALLBACK-FRAGMENT"))
                XCTAssertFalse(error.localizedDescription.contains("secret-code"))
                XCTAssertFalse(error.localizedDescription.contains("secret-token"))
                XCTAssertFalse(error.localizedDescription.contains("https://"))
            }
        }
    }
    func testOAuthEmptyFragmentDoesNotBypassIntentOrCode() {
        rejectCallback("https://jaegun-com.vercel.app/auth/callback/social?code=a&social_intent=other#")
        rejectCallback("https://jaegun-com.vercel.app/auth/callback/social?code=a&code=b&social_intent=known#")
        rejectCallback("https://attacker.invalid/auth/callback/social?code=a&social_intent=known#")
    }
    func testOAuthProviderErrorCodeFails() { rejectCallback("https://jaegun-com.vercel.app/auth/callback/social?code=a&social_intent=known&error_code=denied") }
    private func rejectCallback(_ value: String) { XCTAssertThrowsError(try NativeOAuthCallback.authorizationCode(URL(string: value)!, expectedIntent: "known")) }
}
