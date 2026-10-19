import XCTest
@testable import JaegunNative

final class NativeChatTests: XCTestCase {
    private let organization = "10100000-0000-4000-8000-000000000001"
    private let otherOrganization = "10100000-0000-4000-8000-000000000002"
    private let ownID = "10200000-0000-4000-8000-000000000001"
    private let firstID = "10200000-0000-4000-8000-00000000000a"
    private let secondID = "10200000-0000-4000-8000-00000000000b"

    private func membership(_ id: String, organization: String? = nil, status: String = "active") -> [String: Any] {
        ["user_id": id, "organization_id": organization ?? self.organization, "status": status]
    }

    func testReadGateCoalescesAndRejectsStaleSessionAndRequest() throws {
        var gate = NativeChatReadGate()
        XCTAssertNil(gate.begin(identity: ""))
        let first = try XCTUnwrap(gate.begin(identity: "session-a:actor:church"))
        XCTAssertNil(gate.begin(identity: "session-a:actor:church"))
        XCTAssertTrue(gate.accepts(first, identity: "session-a:actor:church"))
        XCTAssertFalse(gate.accepts(first, identity: "session-b:actor:church"))
        let replacement = try XCTUnwrap(gate.begin(identity: "session-b:actor:church"))
        gate.finish(first)
        XCTAssertTrue(gate.accepts(replacement, identity: "session-b:actor:church"))
        gate.invalidate()
        XCTAssertFalse(gate.accepts(replacement, identity: "session-b:actor:church"))
        let next = try XCTUnwrap(gate.begin(identity: "session-b:actor:church"))
        gate.finish(next)
        XCTAssertNotNil(gate.begin(identity: "session-b:actor:church"))
    }

    func testAuthorizationFailuresClearButTransientNetworkFailuresCanKeepSameSessionRows() {
        XCTAssertTrue(NativeChatFailurePolicy.requiresClearingProtectedContent(NativeAPIError.response(401)))
        XCTAssertTrue(NativeChatFailurePolicy.requiresClearingProtectedContent(NativeAPIError.response(403)))
        XCTAssertTrue(NativeChatFailurePolicy.requiresClearingProtectedContent(NativeAPIError.sessionExpired))
        XCTAssertTrue(NativeChatFailurePolicy.requiresClearingProtectedContent(NativeAPIError.security("denied")))
        XCTAssertFalse(NativeChatFailurePolicy.requiresClearingProtectedContent(NativeAPIError.response(503)))
        XCTAssertFalse(NativeChatFailurePolicy.requiresClearingProtectedContent(URLError(.timedOut)))
    }

    func testMembershipProjectionUsesExactChurchActiveMembersAndExcludesSelf() {
        let rows = [membership(ownID), membership(firstID), membership(firstID.uppercased()),
                    membership(secondID, organization: otherOrganization), membership(secondID, status: "pending"), membership("invalid")]
        XCTAssertEqual(NativeChatMemberDirectory.profileIDs(in: rows, organization: organization.uppercased(), ownID: ownID.uppercased()), [firstID])
    }

    func testIncrementalPagesPreserveVisibleResultsAndUseMembershipOffsets() {
        var directory = NativeChatMemberDirectory()
        let page = Array(repeating: membership(firstID), count: NativeChatMemberDirectory.pageSize)
        directory.append(memberships: page,
                         profiles: [["id": firstID, "display_name": "첫 회원"], ["id": secondID, "display_name": "범위 밖 회원"]],
                         organization: organization, ownID: ownID)
        XCTAssertEqual(directory.offset, 50)
        XCTAssertTrue(directory.hasMore)
        XCTAssertEqual(directory.members.count, 1)
        XCTAssertTrue(directory.matching("아직 안 불러온 이름").isEmpty)
        XCTAssertEqual(directory.matching("  첫  ").count, 1)
        // Blocked/hidden profiles may be absent. They still advance the membership
        // offset and must not erase an already visible page.
        directory.append(memberships: [membership(secondID)], profiles: [], organization: organization, ownID: ownID)
        XCTAssertEqual(directory.offset, 51)
        XCTAssertEqual(directory.members.count, 1)
        XCTAssertFalse(directory.hasMore)
        XCTAssertFalse(directory.reachedLimit)
    }

    func testProfileResultsAreDeduplicatedAcrossPages() {
        var directory = NativeChatMemberDirectory()
        let profile: [String: Any] = ["id": firstID.uppercased(), "display_name": "Member"]
        directory.append(memberships: [membership(firstID)], profiles: [profile, profile], organization: organization, ownID: ownID)
        directory.append(memberships: [membership(firstID)], profiles: [profile], organization: organization, ownID: ownID)
        XCTAssertEqual(directory.members.count, 1)
        XCTAssertEqual(directory.matching("member").count, 1)
    }

    func testFullPageAtServerOffsetLimitStopsWithoutClaimingExhaustiveSearch() {
        var directory = NativeChatMemberDirectory()
        let page = Array(repeating: membership(firstID), count: NativeChatMemberDirectory.pageSize)
        for _ in stride(from: 0, through: NativeChatMemberDirectory.maximumOffset, by: NativeChatMemberDirectory.pageSize) {
            directory.append(memberships: page, profiles: [], organization: organization, ownID: ownID)
        }
        XCTAssertFalse(directory.hasMore)
        XCTAssertTrue(directory.reachedLimit)
        XCTAssertEqual(directory.offset, 10_050)
    }

    @MainActor func testUncertainChannelDraftKeepsOperationUntilExplicitReset() {
        let draft = NativeChatChannelDraft()
        draft.name = "소모임"
        draft.visibility = "private"
        let operation = draft.channelID
        draft.frozenPayload = ["name": "소모임", "visibility": "private", "expectedActorId": ownID, "organizationId": organization]
        // Cancelling the sheet does not reset this hub-owned object.
        let reopened = draft
        XCTAssertEqual(reopened.channelID, operation)
        XCTAssertEqual(reopened.frozenPayload?["visibility"] as? String, "private")
        reopened.reset()
        XCTAssertNotEqual(draft.channelID, operation)
        XCTAssertNil(draft.frozenPayload)
        XCTAssertTrue(draft.name.isEmpty)
    }
}
