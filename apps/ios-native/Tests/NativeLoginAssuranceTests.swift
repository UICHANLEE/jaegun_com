import XCTest
@testable import JaegunNative

final class NativeLoginAssuranceTests: XCTestCase {
    func testVerifiedLoginWaitsForDestinationWithoutShowingTransientConsentOrOnboarding() {
        XCTAssertEqual(NativeRootRoute.resolve(loading: true, signedIn: true, consentRequired: true, administrator: false, activeMember: false, resolvingEntry: true), .entry)
        XCTAssertEqual(NativeRootRoute.resolve(loading: true, signedIn: true, consentRequired: false, administrator: true, activeMember: false, resolvingEntry: true), .entry)
        XCTAssertEqual(NativeRootRoute.resolve(loading: true, signedIn: false, consentRequired: true, administrator: false, activeMember: false, resolvingEntry: true), .login)
    }
    func testEntryCompletionStillEnforcesMFAConsentAndMembership() {
        XCTAssertEqual(NativeRootRoute.resolve(loading: false, signedIn: true, consentRequired: true, administrator: true, activeMember: true, mfaRequired: true, resolvingEntry: false), .mfa)
        XCTAssertEqual(NativeRootRoute.resolve(loading: false, signedIn: true, consentRequired: true, administrator: true, activeMember: true, resolvingEntry: false), .consent)
        XCTAssertEqual(NativeRootRoute.resolve(loading: false, signedIn: true, consentRequired: false, administrator: false, activeMember: false, resolvingEntry: false), .onboarding)
    }
    func testEnrolledChallengePrecedesCommunityAndConsentWithoutRequiringNewEnrollment() {
        XCTAssertEqual(NativeRootRoute.resolve(loading: false, signedIn: true, consentRequired: false, administrator: true, activeMember: true, mfaRequired: true), .mfa)
        XCTAssertEqual(NativeRootRoute.resolve(loading: false, signedIn: true, consentRequired: true, administrator: false, activeMember: true, mfaRequired: true), .mfa)
        XCTAssertEqual(NativeRootRoute.resolve(loading: false, signedIn: true, consentRequired: false, administrator: false, activeMember: true, mfaRequired: false), .community)
        XCTAssertEqual(NativeRootRoute.resolve(loading: false, signedIn: false, consentRequired: true, administrator: true, activeMember: true, mfaRequired: true), .login)
    }
    func testOnlyVerifiedServerFactorsRequireAChallenge() {
        let id = UUID().uuidString
        XCTAssertTrue(NativeLoginAssurance.verifiedFactors([:]).isEmpty)
        XCTAssertTrue(NativeLoginAssurance.verifiedFactors(["factors": [["id": id, "status": "unverified", "factor_type": "totp"]]]).isEmpty)
        XCTAssertEqual(NativeLoginAssurance.verifiedFactors(["factors": [["id": id, "status": "verified", "factor_type": "totp"]]]).first?["id"] as? String, id)
        XCTAssertFalse(NativeLoginAssurance.hasAAL2("invalid"))
        XCTAssertTrue(NativeLoginAssurance.validCode("012345"))
        XCTAssertFalse(NativeLoginAssurance.validCode("１２３４５６"))
        XCTAssertFalse(NativeLoginAssurance.validCode("12345\n"))
    }
    func testPasswordRecoveryUsesSharedTwelveTo128CharacterPolicyAndAsciiOtp() {
        XCTAssertTrue(NativeRecoveryPolicy.valid(email: "member@example.invalid", code: "012345", password: "a-safe-new-password"))
        XCTAssertFalse(NativeRecoveryPolicy.valid(email: "member@example.invalid", code: "123456", password: "short"))
        XCTAssertFalse(NativeRecoveryPolicy.valid(email: "member@example.invalid", code: "123456", password: String(repeating: "a", count: 129)))
        XCTAssertFalse(NativeRecoveryPolicy.valid(email: "member@example.invalid", code: "123456", password: "a-safe-new\npassword"))
        XCTAssertFalse(NativeRecoveryPolicy.valid(email: "member@example.invalid", code: "１２３４５６", password: "a-safe-new-password"))
    }
}
