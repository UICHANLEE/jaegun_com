import XCTest
@testable import JaegunNative

final class NativeEventRecurrenceTests: XCTestCase {
    func testMonthWeekdayIncludesLeapYearAndLastOccurrence() {
        let leap = NativeEventDraft.parseDate("2024-02-29T01:00:00Z")!
        XCTAssertTrue(NativeEventDraft.matchesMonthWeekday(leap, week: -1, weekday: 4))
        XCTAssertFalse(NativeEventDraft.matchesMonthWeekday(leap, week: 4, weekday: 4))
        let lastFriday = NativeEventDraft.parseDate("2026-05-29T01:00:00Z")!
        XCTAssertTrue(NativeEventDraft.matchesMonthWeekday(lastFriday, week: -1, weekday: 5))
        XCTAssertFalse(NativeEventDraft.matchesMonthWeekday(lastFriday, week: 4, weekday: 5))
    }
    func testMonthlyRuleAlignsFirstStartAndPreservesDuration() {
        var draft = NativeEventDraft(scopeId: UUID().uuidString)
        draft.title = "매월 모임"; draft.host = "교회"; draft.frequency = "monthly"; draft.recurrenceCount = 6
        draft.startsAt = NativeEventDraft.parseDate("2026-10-14T01:00:00Z")!; draft.endsAt = draft.startsAt.addingTimeInterval(3600)
        draft.monthWeek = 2; draft.monthWeekday = 5; draft.alignMonthlyStart()
        XCTAssertEqual(NativeEventDraft.iso(draft.startsAt), "2026-11-13T01:00:00Z")
        XCTAssertEqual(draft.endsAt.timeIntervalSince(draft.startsAt), 3600)
        XCTAssertNil(draft.validation)
        XCTAssertEqual(draft.recurrenceBody["p_recurrence_month_week"] as? Int, 2)
        XCTAssertEqual(draft.recurrenceBody["p_recurrence_month_weekday"] as? Int, 5)
        XCTAssertTrue(draft.recurrenceBody["p_recurrence_month_day"] is NSNull)
    }
    func testWeeklyRuleAlignsAndRetainsMultipleWeekdays() {
        var draft = NativeEventDraft(scopeId: UUID().uuidString)
        draft.startsAt = NativeEventDraft.parseDate("2026-10-14T01:00:00Z")!; draft.endsAt = draft.startsAt.addingTimeInterval(3600)
        draft.frequency = "weekly"; draft.weekdays = [1, 5]; draft.alignWeeklyStart()
        XCTAssertEqual(NativeEventDraft.iso(draft.startsAt), "2026-10-16T01:00:00Z")
        XCTAssertEqual(draft.body["p_recurrence_weekdays"] as? [Int], [1, 5])
    }
}
