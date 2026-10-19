import XCTest
@testable import JaegunNative

final class NativeGovernanceTests: XCTestCase {
    private func entry(_ id: String, type: String = "church", source: String = "office", offices: [String] = ["pastor"], manage: Bool = true, delegate: Bool = true) -> [String: Any] {
        ["scope_id": id, "scope_type": type, "authority_source": source, "office_codes": offices,
         "can_manage_officers": manage, "can_manage_delegations": delegate, "can_view_roster": true]
    }
    func testParentAndSiblingAuthorityNeverMergeIntoChurchScope() {
        let entries = [entry("parent", type: "presbytery"), entry("sibling")]
        XCTAssertTrue(NativeGovernancePolicy.access(entries, scopeID: "church").isEmpty)
        XCTAssertFalse(NativeGovernancePolicy.canManageDepartment(entries, scopeID: "church", admin: false))
    }
    func testUnionOfficeNeverBecomesHierarchyAuthority() {
        let union = [entry("union", type: "union_department", offices: ["president"])]
        XCTAssertTrue(NativeGovernancePolicy.access(union, scopeID: "union").isEmpty)
        XCTAssertFalse(NativeGovernancePolicy.canManageDepartment(union, scopeID: "union", admin: false))
    }
    func testDepartmentRequiresExplicitCurrentPastorAccessNotGenericMinisterOrPresident() {
        XCTAssertFalse(NativeGovernancePolicy.canManageDepartment([], scopeID: "church", admin: false))
        XCTAssertFalse(NativeGovernancePolicy.canManageDepartment([entry("church", offices: ["president"])], scopeID: "church", admin: false))
        XCTAssertFalse(NativeGovernancePolicy.canManageDepartment([entry("church", source: "delegation")], scopeID: "church", admin: false))
        XCTAssertTrue(NativeGovernancePolicy.canManageDepartment([entry("church")], scopeID: "church", admin: false))
    }
    func testExactDelegatedCapabilitiesRemainDistinct() {
        let access = NativeGovernancePolicy.access([entry("church", source: "delegation", offices: [], manage: false, delegate: false)], scopeID: "church")
        XCTAssertEqual(access["can_view_roster"] as? Bool, true)
        XCTAssertEqual(access["can_manage_officers"] as? Bool, false)
        XCTAssertEqual(access["can_manage_delegations"] as? Bool, false)
    }
    func testRevokedOrYearRolledServerAccessIsNotRetainedInPolicy() {
        XCTAssertEqual(NativeGovernancePolicy.access([entry("church")], scopeID: "church")["can_manage_officers"] as? Bool, true)
        XCTAssertTrue(NativeGovernancePolicy.access([], scopeID: "church").isEmpty)
        XCTAssertFalse(NativeGovernancePolicy.canManageDepartment([], scopeID: "church", admin: false))
    }
}
