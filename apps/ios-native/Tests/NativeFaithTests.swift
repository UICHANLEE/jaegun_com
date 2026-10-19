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
    func testAnnualPlanCoversEveryChapterExactlyOnceIncludingLeapYears() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        for year in [2024, 2026, 2028] {
            let first = try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: 1, day: 1)))
            let days = try XCTUnwrap(calendar.range(of: .day, in: .year, for: first))
            var collected: [Int] = []
            for offset in 0..<days.count {
                let date = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: first))
                let target = NativeBibleCanon.todayPlan(formatter.string(from: date))
                XCTAssertTrue([3, 4].contains(target.count)); collected.append(contentsOf: target)
            }
            XCTAssertEqual(collected, Array(1...1189))
            XCTAssertEqual(NativeBibleCanon.todayPlan("\(year)-01-01"), [1, 2, 3])
            XCTAssertEqual(NativeBibleCanon.todayPlan("\(year)-12-31"), [1186, 1187, 1188, 1189])
        }
        XCTAssertEqual(NativeBibleCanon.todayPlan("2024-02-29"), [192, 193, 194])
        XCTAssertEqual(NativeBibleCanon.todayPlan("2024-03-01").first, 195)
        XCTAssertTrue(NativeBibleCanon.todayPlan("2026-02-29").isEmpty)
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
    func testBundledKoreanSourceIntegrityAndRealCoordinates() throws {
        let manifest = try NativeBibleText.manifest()
        XCTAssertEqual(manifest.archive_sha256, "194dd52ceabdefb97a60f6627de22e97990e0a43b1b388caf4013d010884ecd7")
        XCTAssertEqual(manifest.chapters.count, 1189)
        XCTAssertTrue(manifest.attribution.contains("대한성서공회"))
        XCTAssertTrue(manifest.attribution.contains("CrossWire KorRV 2.0.1"))
        XCTAssertTrue(manifest.license.contains("Public Domain"))
        XCTAssertEqual(manifest.source, "https://www.crosswire.org/sword/modules/ModInfo.jsp?modName=KorRV")
        var slots = 0, empty = 0
        for entry in manifest.chapters {
            let chapter = try NativeBibleText.chapter(entry.id, manifest: manifest)
            slots += chapter.verses.count
            empty += chapter.verses.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        }
        XCTAssertEqual(slots, 31104)
        XCTAssertEqual(empty, 20)
        XCTAssertEqual(try NativeBibleText.chapter(1, manifest: manifest).verses.first?.text, "태초에 하나님이 천지를 창조하시니라 ")
        XCTAssertThrowsError(try NativeBibleText.chapter(0, manifest: manifest))
        XCTAssertThrowsError(try NativeBibleText.chapter(1190, manifest: manifest))
    }
    func testUpstreamMergedVerseTextIsNotLostDuringConversion() throws {
        let manifest = try NativeBibleText.manifest()
        let cases: [(String, Int, Int, Int, String)] = [
            ("이사야", 30, 0, 1, "그들이 바로의 세력 안에서"),
            ("로마서", 9, 0, 1, "내게 큰 근심이 있는 것과 마음에 그치지 않는 고통"),
            ("고린도후서", 13, 12, 13, "주 예수 그리스도의 은혜와 하나님의 사랑과 성령의 교통하심")
        ]
        for (book, number, mergedIndex, emptyIndex, phrase) in cases {
            let bookIndex = try XCTUnwrap(NativeBibleCanon.books.firstIndex { $0.name == book })
            let id = try XCTUnwrap(NativeBibleCanon.chapterID(book: bookIndex, chapter: number))
            let value = try NativeBibleText.chapter(id, manifest: manifest)
            XCTAssertTrue(value.verses[mergedIndex].text.contains(phrase))
            XCTAssertEqual(value.verses[emptyIndex].text, "")
        }
    }
    func testFullTextSearchUsesBundledKoreanVerses() throws {
        let manifest = try NativeBibleText.manifest()
        let result = try NativeBibleText.search("태초에", manifest: manifest)
        XCTAssertGreaterThan(result.total, 1)
        XCTAssertEqual(result.hits.first?.chapterID, 1)
        XCTAssertEqual(result.hits.first?.verse, 1)
        XCTAssertTrue(result.hits.allSatisfy { $0.text.contains("태초에") })
        XCTAssertThrowsError(try NativeBibleText.search("한", manifest: manifest))
    }
    func testCommunityParserSuppressesSmallGroupsAndIndividualShapes() throws {
        var row: [String: Any] = ["server_today": "2026-10-15", "service_year": 2026, "opted_in": false, "challenge_department_code": NSNull(), "revision": 0, "notice_version": "2026-10-15", "notice": "집계 참여 선택 안내", "minimum_group": 5, "rankings": []]
        XCTAssertFalse(try NativeFaithCommunity.parse(row).opted_in)
        row["rankings"] = [["kind": "church", "id": UUID().uuidString, "name": "교회", "participants": 4, "chapters": 10, "average_chapters": 2.5, "rank": 1]]
        XCTAssertThrowsError(try NativeFaithCommunity.parse(row))
        row["rankings"] = []
        row["minimum_group"] = 1
        XCTAssertThrowsError(try NativeFaithCommunity.parse(row))
    }
    func testChallengeDepartmentIsOptionalAndNeverAnAuthorityCode() throws {
        var row: [String: Any] = ["server_today": "2026-10-15", "service_year": 2026, "opted_in": true, "challenge_department_code": "teen", "revision": 1, "notice_version": "2026-10-15", "notice": "자기 선택 통독 도전 그룹", "minimum_group": 5, "rankings": [["kind": "department", "id": UUID().uuidString, "name": "청소년부 통독 모임", "participants": 5, "chapters": 10, "average_chapters": 2, "rank": 1]]]
        XCTAssertEqual(try NativeFaithCommunity.parse(row).challenge_department_code, "teen")
        row["challenge_department_code"] = "executive"
        XCTAssertThrowsError(try NativeFaithCommunity.parse(row))
        row["challenge_department_code"] = "teen"; row["opted_in"] = false
        XCTAssertThrowsError(try NativeFaithCommunity.parse(row))
        row["opted_in"] = true
        row["rankings"] = [["kind": "department", "id": UUID().uuidString, "name": "청소년부 통독 모임", "participants": 4, "chapters": 10, "average_chapters": 2.5, "rank": 1]]
        XCTAssertThrowsError(try NativeFaithCommunity.parse(row))
    }
}
