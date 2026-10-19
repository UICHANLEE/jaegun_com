import XCTest
@testable import JaegunNative

final class NativeAccountServicesTests: XCTestCase {
    func testQuietHoursRequireValidKoreanCivilTime() {
        for value in ["00:00", "07:30", "23:59"] { XCTAssertTrue(NativeAccountPolicy.validTime(value)) }
        for value in ["24:00", "12:60", "7:30", "23:59:00", "07:30\n", ""] { XCTAssertFalse(NativeAccountPolicy.validTime(value)) }
    }
    func testDeletionRequiresExactConfirmationAndBoundedInputs() {
        XCTAssertTrue(NativeAccountPolicy.validDeletion(confirmation: "계정 삭제", reason: "", password: ""))
        XCTAssertFalse(NativeAccountPolicy.validDeletion(confirmation: "삭제", reason: "", password: ""))
        XCTAssertFalse(NativeAccountPolicy.validDeletion(confirmation: "계정 삭제", reason: String(repeating: "가", count: 501), password: ""))
        XCTAssertFalse(NativeAccountPolicy.validDeletion(confirmation: "계정 삭제", reason: "", password: String(repeating: "a", count: 513)))
    }
}
