import Foundation

/// Calendar dates are Seoul civil days, regardless of the device's locale or time zone.
enum NativeCalendarDates {
    static let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "ko_KR")
        value.timeZone = TimeZone(identifier: "Asia/Seoul")!
        value.firstWeekday = 1
        return value
    }()
    static func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }
    static func month(_ date: Date) -> Date { calendar.dateInterval(of: .month, for: date)!.start }
    static func movingMonth(_ month: Date, by offset: Int, selectedDay: Date) -> (month: Date, day: Date) {
        let target = calendar.date(byAdding: .month, value: offset, to: self.month(month))!
        let dayNumber = min(calendar.component(.day, from: selectedDay), calendar.range(of: .day, in: .month, for: target)!.count)
        return (target, calendar.date(byAdding: .day, value: dayNumber - 1, to: target)!)
    }
    private static func formatter(_ format: String) -> DateFormatter {
        let value = DateFormatter()
        value.locale = Locale(identifier: "ko_KR")
        value.timeZone = calendar.timeZone
        value.dateFormat = format
        return value
    }
    private static let labels: [String: DateFormatter] = Dictionary(uniqueKeysWithValues: [
        "yyyy년 M월", "M월 d일 (E) 일정", "yyyy년 M월 d일 EEEE", "yyyy-MM-dd"
    ].map { ($0, formatter($0)) })
    private static let queryFormatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()
    static func label(_ date: Date, format: String) -> String {
        (labels[format] ?? formatter(format)).string(from: date)
    }
    static func queryDate(_ date: Date) -> String { queryFormatter.string(from: date) }
}

struct NativeCalendarMonth: Equatable {
    let start: Date
    let grid: DateInterval
    let days: [Date]
    /// The RPC filters starts, not overlaps. SQL caps every occurrence at seven days.
    var queryRange: DateInterval {
        DateInterval(start: NativeCalendarDates.calendar.date(byAdding: .day, value: -7, to: grid.start)!, end: grid.end)
    }
    init(containing date: Date) {
        let calendar = NativeCalendarDates.calendar
        start = NativeCalendarDates.month(date)
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        let leading = calendar.component(.weekday, from: start) - calendar.firstWeekday
        let first = calendar.date(byAdding: .day, value: -leading, to: start)!
        let last = calendar.date(byAdding: .day, value: -1, to: end)!
        let trailing = 7 - calendar.component(.weekday, from: last)
        let gridEnd = calendar.date(byAdding: .day, value: trailing, to: end)!
        grid = DateInterval(start: first, end: gridEnd)
        let count = calendar.dateComponents([.day], from: first, to: gridEnd).day!
        days = (0..<count).map { calendar.date(byAdding: .day, value: $0, to: first)! }
    }
    func contains(_ date: Date) -> Bool { NativeCalendarDates.month(date) == start }
}

struct NativeCalendarOccurrence: Identifiable {
    let id: String
    let startsAt: Date
    let endsAt: Date
    let row: [String: Any]
    var scopeID: String { nativeText(row, "scope_id") }
    init(row: [String: Any]) throws {
        guard let id = row["occurrence_id"] as? String, UUID(uuidString: id) != nil,
              let start = NativeEventDraft.parseDate(nativeText(row, "starts_at")),
              let end = NativeEventDraft.parseDate(nativeText(row, "ends_at")), end > start,
              UUID(uuidString: nativeText(row, "scope_id")) != nil else { throw NativeAPIError.invalidData }
        self.id = id; startsAt = start; endsAt = end; self.row = row
    }
    func overlaps(day: Date) -> Bool {
        let start = NativeCalendarDates.day(day)
        let end = NativeCalendarDates.calendar.date(byAdding: .day, value: 1, to: start)!
        return startsAt < end && endsAt > start
    }
}

struct NativeCalendarSnapshot {
    let month: NativeCalendarMonth
    let occurrences: [NativeCalendarOccurrence]
    let byDay: [Date: [NativeCalendarOccurrence]]
    let counts: [Date: Int]
    init(month: NativeCalendarMonth, occurrences: [NativeCalendarOccurrence]) {
        self.month = month
        self.occurrences = occurrences
        let indexed = Dictionary(uniqueKeysWithValues: month.days.map { day in
            let end = NativeCalendarDates.calendar.date(byAdding: .day, value: 1, to: day)!
            return (day, occurrences.filter { $0.startsAt < end && $0.endsAt > day })
        })
        byDay = indexed
        counts = indexed.mapValues(\.count)
    }
}

struct NativeCalendarIdentity: Equatable, Hashable {
    let generation: UUID
    let actor: String
    let organization: String
    let membershipStatus: String
    let role: String
    let platformAdministrator: Bool
    init(generation: UUID, context: [String: Any]) {
        self.generation = generation
        actor = nativeText(context["profile"] as? [String: Any] ?? [:], "id")
        let membership = context["membership"] as? [String: Any] ?? [:]
        organization = nativeText(membership, "organization_id")
        membershipStatus = nativeText(membership, "status")
        role = nativeText(membership, "role")
        platformAdministrator = context["is_platform_admin"] as? Bool == true
    }
}

struct NativeCalendarLoadKey: Equatable {
    let identity: NativeCalendarIdentity?
    let month: Date?
}

struct NativeCalendarServerClock {
    let serverNow: Date
    let uptime: TimeInterval
    init(serverNow: Date) { self.serverNow = serverNow; uptime = ProcessInfo.processInfo.systemUptime }
    var now: Date { serverNow.addingTimeInterval(max(0, ProcessInfo.processInfo.systemUptime - uptime)) }
}

enum NativeCalendarLoadError: LocalizedError {
    case crowdedInstant
    var errorDescription: String? {
        "같은 시각에 일정이 너무 많아 달력 전체를 확인하지 못했습니다. 일부만 표시하지 않습니다. 관리자에게 조회 범위 분할 또는 서버 페이지 지원을 요청해 주세요."
    }
}

/// This RPC has a 200-row internal cap and no offset. Split capped ranges, never accept a truncated page.
@MainActor enum NativeCalendarLoader {
    static let limit = 200
    static func fetch(range: DateInterval, isCurrent: () -> Bool,
                      request: (DateInterval, Int) async throws -> [[String: Any]]) async throws -> [NativeCalendarOccurrence] {
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        let rows = try await request(range, limit)
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        guard rows.count <= limit else { throw NativeAPIError.invalidData }
        let events = try rows.map(NativeCalendarOccurrence.init)
        guard events.allSatisfy({ $0.startsAt >= range.start && $0.startsAt < range.end }) else { throw NativeAPIError.invalidData }
        if rows.count < limit { return events }
        // An exactly-full same-instant page cannot prove completeness without a server cursor.
        guard Set(events.map(\.startsAt)).count > 1, range.duration > 1 else { throw NativeCalendarLoadError.crowdedInstant }
        let midpoint = Date(timeIntervalSince1970: floor(range.start.timeIntervalSince1970 + range.duration / 2))
        guard midpoint > range.start, midpoint < range.end else { throw NativeCalendarLoadError.crowdedInstant }
        let first = try await fetch(range: DateInterval(start: range.start, end: midpoint), isCurrent: isCurrent, request: request)
        let second = try await fetch(range: DateInterval(start: midpoint, end: range.end), isCurrent: isCurrent, request: request)
        return first + second
    }
}

enum NativeCalendarFailurePolicy {
    static func preservesSnapshot(_ error: Error) -> Bool {
        if let networkError = error as? URLError {
            return networkError.code != .userAuthenticationRequired && networkError.code != .cancelled
        }
        if case NativeAPIError.response(let status) = error {
            return status == 408 || status == 429 || status >= 500
        }
        return false
    }
}
