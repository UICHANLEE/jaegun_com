import XCTest
@testable import JaegunNative

final class NativeCalendarTests: XCTestCase {
    private let scopeID = UUID().uuidString
    private func date(_ text: String) -> Date { NativeEventDraft.parseDate(text)! }
    private func row(start: Date, duration: TimeInterval = 3600) -> [String: Any] {
        ["occurrence_id": UUID().uuidString, "scope_id": scopeID,
         "starts_at": NativeCalendarDates.queryDate(start), "ends_at": NativeCalendarDates.queryDate(start.addingTimeInterval(duration))]
    }

    func testOnlyTransientNetworkFailuresMayRetainSameSessionCalendar() {
        XCTAssertTrue(NativeCalendarFailurePolicy.preservesSnapshot(URLError(.timedOut)))
        XCTAssertTrue(NativeCalendarFailurePolicy.preservesSnapshot(NativeAPIError.response(503)))
        XCTAssertFalse(NativeCalendarFailurePolicy.preservesSnapshot(NativeAPIError.response(401)))
        XCTAssertFalse(NativeCalendarFailurePolicy.preservesSnapshot(NativeAPIError.response(403)))
        XCTAssertFalse(NativeCalendarFailurePolicy.preservesSnapshot(NativeAPIError.sessionExpired))
        XCTAssertFalse(NativeCalendarFailurePolicy.preservesSnapshot(NativeAPIError.invalidData))
        XCTAssertFalse(NativeCalendarFailurePolicy.preservesSnapshot(NativeCalendarLoadError.crowdedInstant))
    }

    func testInitialServerDateUsesSeoulInsteadOfUTCOrDeviceDay() {
        let serverNow = date("2026-10-14T15:01:00Z")
        XCTAssertEqual(NativeEventDraft.iso(NativeCalendarDates.day(serverNow)), "2026-10-14T15:00:00Z")
        XCTAssertEqual(NativeCalendarDates.calendar.component(.day, from: serverNow), 15)
        XCTAssertEqual(NativeCalendarDates.label(serverNow, format: "yyyy-MM-dd"), "2026-10-15")
        XCTAssertEqual(NativeEventDraft.iso(NativeCalendarDates.month(serverNow)), "2026-09-30T15:00:00Z")
    }

    func testOctoberGridIncludesBoundaryDaysAndSevenDayLookback() {
        let month = NativeCalendarMonth(containing: date("2026-10-15T01:00:00Z"))
        XCTAssertEqual(month.days.count, 35)
        XCTAssertEqual(NativeEventDraft.iso(month.grid.start), "2026-09-26T15:00:00Z")
        XCTAssertEqual(NativeEventDraft.iso(month.grid.end), "2026-10-31T15:00:00Z")
        XCTAssertEqual(NativeEventDraft.iso(month.queryRange.start), "2026-09-19T15:00:00Z")
        XCTAssertEqual(month.queryRange.end, month.grid.end)
        XCTAssertEqual(NativeCalendarDates.calendar.component(.weekday, from: month.days.first!), 1)
        XCTAssertEqual(NativeCalendarDates.calendar.component(.weekday, from: month.days.last!), 7)
    }

    func testLeapMonthHasFebruary29AndNeighborMonthCells() {
        let month = NativeCalendarMonth(containing: date("2024-02-10T01:00:00Z"))
        XCTAssertEqual(month.days.count, 35)
        XCTAssertEqual(NativeCalendarDates.label(month.grid.start, format: "yyyy-MM-dd"), "2024-01-28")
        XCTAssertEqual(NativeCalendarDates.label(month.grid.end, format: "yyyy-MM-dd"), "2024-03-03")
        XCTAssertTrue(month.days.contains(date("2024-02-28T15:00:00Z")))
        XCTAssertFalse(month.contains(month.days.first!))
    }

    func testFourAndSixWeekEmptyMonthsHaveNavigableDays() {
        let february = NativeCalendarMonth(containing: date("2026-02-10T01:00:00Z"))
        let august = NativeCalendarMonth(containing: date("2026-08-10T01:00:00Z"))
        XCTAssertEqual(february.days.count, 28)
        XCTAssertEqual(august.days.count, 42)
        let empty = NativeCalendarSnapshot(month: august, occurrences: [])
        XCTAssertEqual(empty.byDay.count, 42)
        XCTAssertTrue(empty.byDay.values.allSatisfy(\.isEmpty))
    }

    func testMonthNavigationClampsDayAndCrossesYearAndLeapYear() {
        let october31 = date("2026-10-30T15:00:00Z")
        let november = NativeCalendarDates.movingMonth(october31, by: 1, selectedDay: october31)
        XCTAssertEqual(NativeCalendarDates.label(november.day, format: "yyyy-MM-dd"), "2026-11-30")
        let january = date("2024-01-30T15:00:00Z")
        let leap = NativeCalendarDates.movingMonth(january, by: 1, selectedDay: january)
        XCTAssertEqual(NativeCalendarDates.label(leap.day, format: "yyyy-MM-dd"), "2024-02-29")
        let december = NativeCalendarDates.movingMonth(january, by: -1, selectedDay: january)
        XCTAssertEqual(NativeCalendarDates.label(december.day, format: "yyyy-MM-dd"), "2023-12-31")
        let nextYear = NativeCalendarDates.movingMonth(december.month, by: 1, selectedDay: december.day)
        XCTAssertEqual(nextYear.day, january)
    }

    func testHalfOpenDayOverlapExcludesMidnightEndAndNextDayStart() throws {
        let day = date("2026-10-14T15:00:00Z")
        let endingAtMidnight = try NativeCalendarOccurrence(row: row(start: day.addingTimeInterval(-3600)))
        let startingTomorrow = try NativeCalendarOccurrence(row: row(start: day.addingTimeInterval(86400)))
        let spanning = try NativeCalendarOccurrence(row: row(start: day.addingTimeInterval(-3600), duration: 7200))
        XCTAssertFalse(endingAtMidnight.overlaps(day: day))
        XCTAssertFalse(startingTomorrow.overlaps(day: day))
        XCTAssertTrue(spanning.overlaps(day: day))
        XCTAssertTrue(spanning.overlaps(day: day.addingTimeInterval(-86400)))
    }

    func testIndicatorsAndDayListsIncludeSevenDayEventStartingBeforeGrid() throws {
        let month = NativeCalendarMonth(containing: date("2026-10-15T01:00:00Z"))
        let event = try NativeCalendarOccurrence(row: row(start: month.grid.start.addingTimeInterval(-6 * 86400), duration: 7 * 86400))
        let snapshot = NativeCalendarSnapshot(month: month, occurrences: [event])
        XCTAssertEqual(snapshot.byDay[month.days[0]]?.map(\.id), [event.id])
        XCTAssertTrue(snapshot.byDay[month.days[1]]!.isEmpty)
        XCTAssertTrue(event.startsAt >= month.queryRange.start)
    }

    func testMidnightUTCEventAppearsOnCorrectSeoulDate() throws {
        let month = NativeCalendarMonth(containing: date("2026-10-15T01:00:00Z"))
        let event = try NativeCalendarOccurrence(row: row(start: date("2026-10-14T15:00:00Z")))
        let snapshot = NativeCalendarSnapshot(month: month, occurrences: [event])
        XCTAssertEqual(snapshot.byDay[date("2026-10-14T15:00:00Z")]?.count, 1)
        XCTAssertTrue(snapshot.byDay[date("2026-10-13T15:00:00Z")]!.isEmpty)
    }

    func testIdentityChangesForSameActorNewSessionAndChurch() {
        let generation = UUID()
        var context: [String: Any] = ["profile": ["id": UUID().uuidString], "membership": ["organization_id": "church-a", "status": "active", "role": "member"]]
        let original = NativeCalendarIdentity(generation: generation, context: context)
        XCTAssertNotEqual(original, NativeCalendarIdentity(generation: UUID(), context: context))
        context["membership"] = ["organization_id": "church-b", "status": "active", "role": "member"]
        XCTAssertNotEqual(original, NativeCalendarIdentity(generation: generation, context: context))
        context["membership"] = ["organization_id": "church-a", "status": "withdrawn", "role": "member"]
        XCTAssertNotEqual(original, NativeCalendarIdentity(generation: generation, context: context))
    }

    @MainActor func testLoaderSplitsFullPagesWithoutDroppingBoundaryEvents() async throws {
        let start = date("2026-10-01T00:00:00Z")
        let range = DateInterval(start: start, end: start.addingTimeInterval(1000))
        // Include an event exactly at the first subdivision boundary.
        let rows = (0..<501).map { row(start: start.addingTimeInterval(Double($0))) }
        var calls = 0
        let events = try await NativeCalendarLoader.fetch(range: range, isCurrent: { true }) { window, limit in
            calls += 1
            XCTAssertEqual(limit, 200)
            return Array(rows.filter {
                let begins = NativeEventDraft.parseDate($0["starts_at"] as! String)!
                return begins >= window.start && begins < window.end
            }.prefix(limit))
        }
        XCTAssertGreaterThan(calls, 1)
        XCTAssertEqual(events.count, 501)
        XCTAssertEqual(Set(events.map(\.id)).count, 501)
        XCTAssertTrue(events.contains { $0.startsAt == start.addingTimeInterval(500) })
    }

    @MainActor func testLoaderDoesNotPresentSaturatedSameInstantAsComplete() async {
        let start = date("2026-10-01T00:00:00Z")
        let rows = (0..<200).map { _ in row(start: start) }
        do {
            _ = try await NativeCalendarLoader.fetch(range: DateInterval(start: start, duration: 86400), isCurrent: { true }) { _, _ in rows }
            XCTFail("A capped page cannot establish completeness at a single timestamp")
        } catch {
            XCTAssertTrue(error is NativeCalendarLoadError)
        }
    }

    @MainActor func testLoaderDropsResponseAfterSessionOrGenerationChanges() async {
        let start = date("2026-10-01T00:00:00Z")
        var current = true
        do {
            _ = try await NativeCalendarLoader.fetch(range: DateInterval(start: start, duration: 86400), isCurrent: { current }) { _, _ in
                current = false
                return [self.row(start: start)]
            }
            XCTFail("Stale protected responses must not be committed")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor func testEmptyMonthFetchKeepsFullGridQueryRatherThanUpcoming90Days() async throws {
        let month = NativeCalendarMonth(containing: date("2025-01-15T01:00:00Z"))
        var requested: DateInterval?
        let events = try await NativeCalendarLoader.fetch(range: month.queryRange, isCurrent: { true }) { range, _ in
            requested = range
            return []
        }
        XCTAssertEqual(requested, month.queryRange)
        XCTAssertTrue(events.isEmpty)
    }
}
