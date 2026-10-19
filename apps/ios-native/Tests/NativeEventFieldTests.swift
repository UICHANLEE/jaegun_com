import XCTest
@testable import JaegunNative

final class NativeEventFieldTests: XCTestCase {
    private func fixture() -> NativeFieldState {
        let people = (0..<5).map { i in NativeFieldParticipant(user_id: "p\(i)", display_name: "참석자 \(i)", response: "yes", church_id: i < 3 ? "church-a" : "church-b", church_name: i < 3 ? "교회 A" : "교회 B", survey: nil, group_id: nil, vehicle_id: nil, room_id: nil, checked_at: nil) }
        return NativeFieldState(capabilities: ["logistics"], can_grant: false, survey: nil, plan: .init(revision: 4, vehicles: [.init(id: "v1", label: "차량", seat_count: 3, driver_user_id: "p0")]), groups: [.init(id: "g1", name: "1조", capacity: 3), .init(id: "g2", name: "2조", capacity: 3)], rooms: [.init(id: "r1", name: "숙소", capacity: 2)], participants: people, staff: [])
    }
    func testBalancedRoundRobinAndRoomOverflow() {
        let state = fixture(); var draft = NativeFieldDraft(state)
        draft.automatic("group", participants: state.participants)
        XCTAssertEqual(draft.assignments.map(\.group_id), ["g1", "g2", "g1", "g2", "g1"])
        draft.automatic("room", participants: state.participants)
        XCTAssertEqual(draft.assignments.filter { $0.room_id == "r1" }.count, 2)
        XCTAssertNil(draft.capacityError)
        XCTAssertEqual(draft.revision, 4)
    }
    func testDriverSeatAndCapacity() {
        let state = fixture(); var draft = NativeFieldDraft(state)
        draft.automatic("vehicle", participants: state.participants)
        XCTAssertEqual(draft.assignments[0].vehicle_id, "v1")
        XCTAssertEqual(draft.assignments.filter { $0.vehicle_id == "v1" }.count, 3)
        draft.assignments[4].vehicle_id = "v1"
        XCTAssertNotNil(draft.capacityError)
    }
    func testExactChurchGroupsOnlyUseActualMembershipIDs() {
        let state = fixture(); var draft = NativeFieldDraft(state)
        draft.automatic("church", participants: state.participants)
        XCTAssertEqual(draft.groups.map(\.capacity), [3, 2])
        XCTAssertEqual(draft.assignments[0].group_id, draft.assignments[2].group_id)
        XCTAssertNotEqual(draft.assignments[0].group_id, draft.assignments[3].group_id)
    }
    func testXLSXStoredZIPAndInlineStringFormulaDefense() throws {
        let data = try NativeXLSX.write(sheets: [(name: "명단", rows: [["이름"], ["=HYPERLINK(\"evil\")"], ["<교회&>"]]), (name: "조", rows: [["조"]])])
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("[Content_Types].xml"))
        XCTAssertTrue(text.contains("xl/worksheets/sheet2.xml"))
        XCTAssertTrue(text.contains("inlineStr"))
        XCTAssertTrue(text.contains("&apos;=HYPERLINK"))
        XCTAssertTrue(text.contains("&lt;교회&amp;&gt;"))
        XCTAssertFalse(text.contains("<f>"))
    }
    func testDuplicateAndInvalidSheetNamesAreRejected() {
        XCTAssertThrowsError(try NativeXLSX.write(sheets: [(name: "동일", rows: []), (name: "동일", rows: [])]))
        XCTAssertThrowsError(try NativeXLSX.write(sheets: [(name: "../잘못", rows: [])]))
    }
    func testRecordArchiveSplitsBodiesWithoutLosingUnicode() {
        let body = String(repeating: "긴 본문😀", count: 10000)
        let parts = NativeRecordArchiveWorkbook.parts(body)
        XCTAssertEqual(parts.joined(), body)
        XCTAssertTrue(parts.allSatisfy { $0.utf16.count <= 30000 })
        XCTAssertEqual(NativeRecordArchiveWorkbook.parts(""), [""])
    }
}
