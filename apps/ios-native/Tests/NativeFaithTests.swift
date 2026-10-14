import XCTest
@testable import JaegunNative

final class NativeFaithTests: XCTestCase {
    func testCanonAndLeapYearPlan() {
        XCTAssertEqual(NativeBibleCanon.books.count, 66)
        XCTAssertEqual(NativeBibleCanon.books.reduce(0) { $0 + $1.chapters }, 1189)
        XCTAssertEqual(NativeBibleCanon.chapterID(book: 0, chapter: 1), 1)
        XCTAssertNil(NativeBibleCanon.chapterID(book: 65, chapter: 23))
        XCTAssertEqual(NativeBibleCanon.reference(1189), "요한계시록 22장")
        XCTAssertFalse(NativeBibleCanon.todayPlan("2024-02-29").isEmpty)
        XCTAssertTrue(NativeBibleCanon.todayPlan("2026-02-31").isEmpty)
    }
    func testConsentResourceAndStrictManifest() throws {
        XCTAssertFalse(try NativeFaithConsentContract.text().isEmpty)
        let document: [String: Any] = ["document_key": "faith_private_records", "version": NativeFaithConsentContract.version, "content_sha256": NativeFaithConsentContract.hash, "title": "개인 통독·QT 기록 이용 동의", "url": "/legal/faith/2026-10-14"]
        XCTAssertFalse(try NativeFaithConsentContract.accepted(["accepted": false, "document": document]))
        XCTAssertThrowsError(try NativeFaithConsentContract.accepted(["accepted": true, "document": ["version": "unknown"]]))
    }
    func testSnapshotRejectsInvalidAndDuplicateChapters() throws {
        var row: [String: Any] = ["server_today": "2026-10-14", "service_year": 2026, "completed_chapters": [1], "completed_count": 1, "total_chapters": 1189, "streak_days": 1, "last_read_date": NSNull(), "latest_private_qt": []]
        XCTAssertEqual(try NativeFaithSnapshot.parse(row).completed_count, 1)
        row["completed_chapters"] = [1190]
        XCTAssertThrowsError(try NativeFaithSnapshot.parse(row))
        row["completed_chapters"] = [1, 1]; row["completed_count"] = 2
        XCTAssertThrowsError(try NativeFaithSnapshot.parse(row))
    }
}
