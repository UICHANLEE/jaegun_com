import XCTest
@testable import JaegunNative

final class NativeBoardTests: XCTestCase {
    private let actor = "00000000-0000-0000-0000-000000000001"
    private let church = "00000000-0000-0000-0000-000000000002"
    private let boardID = "00000000-0000-0000-0000-000000000003"
    private let postID = "00000000-0000-0000-0000-000000000004"

    private func identity(role: String = "member", admin: Bool = false) -> NativeBoardIdentity {
        NativeBoardIdentity(generation: UUID(), actorID: actor, organizationID: church, role: role, platformAdmin: admin)
    }
    private func board() -> [String: Any] {
        ["id": boardID, "organization_id": church, "is_global": false, "is_read_only": false, "staff_only_posting": false]
    }

    func testWritingRequiresExactChurchAndExplicitBoardFlags() {
        var row = board()
        XCTAssertTrue(NativeBoardPolicy.canWrite(row, identity: identity()))
        row["organization_id"] = actor
        XCTAssertFalse(NativeBoardPolicy.canWrite(row, identity: identity(admin: true)))
        row = board(); row["is_read_only"] = true
        XCTAssertFalse(NativeBoardPolicy.canWrite(row, identity: identity(admin: true)))
        row = board(); row["is_global"] = true
        XCTAssertFalse(NativeBoardPolicy.canWrite(row, identity: identity(admin: true)))
        row = board(); row.removeValue(forKey: "staff_only_posting")
        XCTAssertFalse(NativeBoardPolicy.canWrite(row, identity: identity()))
    }

    func testStaffBoardRoleDiscoveryDoesNotGrantOrdinaryMemberWrite() {
        var row = board(); row["staff_only_posting"] = true
        XCTAssertFalse(NativeBoardPolicy.canWrite(row, identity: identity()))
        XCTAssertTrue(NativeBoardPolicy.canWrite(row, identity: identity(role: "minister")))
        XCTAssertTrue(NativeBoardPolicy.canWrite(row, identity: identity(role: "executive")))
        XCTAssertTrue(NativeBoardPolicy.canWrite(row, identity: identity(admin: true)))
        XCTAssertFalse(NativeBoardPolicy.canWrite(row, identity: identity(role: "department_head")))
    }

    func testValidationUsesPostgresScalarLengthsNotGraphemeCounts() {
        XCTAssertFalse(NativeBoardPolicy.postInput(title: " \n", body: "내용"))
        XCTAssertFalse(NativeBoardPolicy.postInput(title: "제목", body: "\n "))
        XCTAssertTrue(NativeBoardPolicy.postInput(title: String(repeating: "가", count: 200), body: String(repeating: "가", count: 50000)))
        XCTAssertFalse(NativeBoardPolicy.postInput(title: String(repeating: "가", count: 201), body: "내용"))
        XCTAssertFalse(NativeBoardPolicy.postInput(title: "제목", body: String(repeating: "가", count: 50001)))
        // Each visually single flag contains two PostgreSQL characters.
        XCTAssertTrue(NativeBoardPolicy.postInput(title: String(repeating: "🇰🇷", count: 100), body: "내용"))
        XCTAssertFalse(NativeBoardPolicy.postInput(title: String(repeating: "🇰🇷", count: 101), body: "내용"))
        XCTAssertTrue(NativeBoardPolicy.commentInput(String(repeating: "가", count: 5000)))
        XCTAssertFalse(NativeBoardPolicy.commentInput(String(repeating: "가", count: 5001)))
        XCTAssertFalse(NativeBoardPolicy.commentInput(" \n "))
    }

    func testCommentsRequirePublishedAllowedExactChurchPost() {
        var row: [String: Any] = ["id": postID, "organization_id": church, "status": "published", "allow_comments": true]
        XCTAssertTrue(NativeBoardPolicy.canComment(row, identity: identity()))
        row["status"] = "draft"
        XCTAssertFalse(NativeBoardPolicy.canComment(row, identity: identity(admin: true)))
        row["status"] = "published"; row["allow_comments"] = false
        XCTAssertFalse(NativeBoardPolicy.canComment(row, identity: identity()))
        row["allow_comments"] = true; row["organization_id"] = NSNull()
        XCTAssertFalse(NativeBoardPolicy.canComment(row, identity: identity(admin: true)))
    }

    func testAnonymousProjectionDoesNotRequireAnAuthorIdentifier() {
        let row: [String: Any] = [
            "id": postID, "organization_id": church, "status": "published", "allow_comments": true,
            "author_id": NSNull(), "author_label": "익명", "is_anonymous": true, "is_owner": true
        ]
        XCTAssertTrue(NativeBoardPolicy.canComment(row, identity: identity()))
        XCTAssertTrue(row["is_owner"] as? Bool == true)
        XCTAssertTrue(row["author_id"] is NSNull)
    }

    func testReconciliationDistinguishesAbsentTerminalAndInvalidResults() throws {
        XCTAssertNil(try NativeBoardPolicy.status(NSNull()))
        for status in ["draft", "published", "hidden", "deleted"] {
            XCTAssertEqual(try NativeBoardPolicy.status(["status": status]), status)
        }
        XCTAssertThrowsError(try NativeBoardPolicy.status(["status": "archived"]))
        XCTAssertThrowsError(try NativeBoardPolicy.status([String: Any]()))
        XCTAssertThrowsError(try NativeBoardPolicy.status([["status": "published"]]))
    }

    func testOwnedDraftRejectsUnexpectedScopeAndIdentifiers() throws {
        var row: [String: Any] = ["id": postID, "organization_id": church, "board_id": boardID, "status": "draft"]
        let actor = identity()
        XCTAssertEqual(try NativeBoardPolicy.ownedDraft(row, id: postID, boardID: boardID, identity: actor), "draft")
        row["organization_id"] = self.actor
        XCTAssertThrowsError(try NativeBoardPolicy.ownedDraft(row, id: postID, boardID: boardID, identity: actor))
        row["organization_id"] = church; row["board_id"] = self.actor
        XCTAssertThrowsError(try NativeBoardPolicy.ownedDraft(row, id: postID, boardID: boardID, identity: actor))
        row["board_id"] = boardID; row["id"] = self.actor
        XCTAssertThrowsError(try NativeBoardPolicy.ownedDraft(row, id: postID, boardID: boardID, identity: actor))
    }

    func testUncertainCommentFailuresKeepTheSameOperation() {
        XCTAssertTrue(NativeBoardPolicy.definitiveCommentRejection(NativeAPIError.response(400)))
        XCTAssertTrue(NativeBoardPolicy.definitiveCommentRejection(NativeAPIError.response(403)))
        XCTAssertFalse(NativeBoardPolicy.definitiveCommentRejection(NativeAPIError.response(409)))
        XCTAssertFalse(NativeBoardPolicy.definitiveCommentRejection(NativeAPIError.response(408)))
        XCTAssertFalse(NativeBoardPolicy.definitiveCommentRejection(NativeAPIError.response(503)))
        XCTAssertFalse(NativeBoardPolicy.definitiveCommentRejection(URLError(.timedOut)))
        XCTAssertFalse(NativeBoardPolicy.definitiveCommentRejection(NativeAPIError.invalidData))
    }

    func testOnlyNetworkFailuresMayRetainProtectedRows() {
        XCTAssertTrue(NativeBoardPolicy.mayRetainProtectedRows(after: URLError(.timedOut)))
        XCTAssertTrue(NativeBoardPolicy.mayRetainProtectedRows(after: URLError(.notConnectedToInternet)))
        XCTAssertFalse(NativeBoardPolicy.mayRetainProtectedRows(after: NativeAPIError.response(401)))
        XCTAssertFalse(NativeBoardPolicy.mayRetainProtectedRows(after: NativeAPIError.response(403)))
        XCTAssertFalse(NativeBoardPolicy.mayRetainProtectedRows(after: NativeAPIError.response(500)))
        XCTAssertFalse(NativeBoardPolicy.mayRetainProtectedRows(after: NativeAPIError.sessionExpired))
        XCTAssertFalse(NativeBoardPolicy.mayRetainProtectedRows(after: NativeAPIError.security("권한 없음")))
        XCTAssertFalse(NativeBoardPolicy.mayRetainProtectedRows(after: NativeAPIError.invalidData))
        XCTAssertFalse(NativeBoardPolicy.mayRetainProtectedRows(after: URLError(.userAuthenticationRequired)))
    }

    @MainActor func testIdentityInvalidatesForConsentActorScopeAndRoleChanges() {
        let session = NativeSession()
        session.signedIn = true; session.consentRequired = false
        session.context = ["profile": ["id": actor], "membership": ["organization_id": church, "status": "active", "role": "member"]]
        let initial = NativeBoardIdentity.capture(session)
        XCTAssertNotNil(initial)
        session.consentRequired = true
        XCTAssertNil(NativeBoardIdentity.capture(session))
        session.consentRequired = false
        session.context["profile"] = ["id": boardID]
        XCTAssertNotEqual(NativeBoardIdentity.capture(session), initial)
        session.context["profile"] = ["id": actor]
        session.context["membership"] = ["organization_id": boardID, "status": "active", "role": "member"]
        XCTAssertNotEqual(NativeBoardIdentity.capture(session), initial)
        session.context["membership"] = ["organization_id": church, "status": "active", "role": "executive"]
        XCTAssertNotEqual(NativeBoardIdentity.capture(session), initial)
        session.context["membership"] = ["organization_id": church, "status": "suspended", "role": "member"]
        XCTAssertNil(NativeBoardIdentity.capture(session))
    }
}
