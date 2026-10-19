import SwiftUI

/// Native controls for the existing event service. Scope discovery is server-authoritative.
struct NativeEventOperationsView: View {
    @EnvironmentObject private var session: NativeSession
    @State private var scopes: [NativeEventScope] = []
    @State private var snapshot: NativeCalendarSnapshot?
    @State private var displayedMonth: Date?
    @State private var selectedDay: Date?
    @State private var serverClock: NativeCalendarServerClock?
    @State private var loadedIdentity: NativeCalendarIdentity?
    @State private var loadGeneration = UUID()
    @State private var inFlightLoad: NativeCalendarLoadKey?
    @State private var bootstrapReady = false
    @State private var operation: UUID?
    @State private var loading = false
    @State private var draft: NativeEventDraft?
    @State private var error: String?
    @State private var requiresAuth = false
    @State private var cancelling: NativeEventCancellation?
    @State private var cancellationReason = ""
    private var busy: Bool { operation != nil }
    private var identity: NativeCalendarIdentity? {
        guard session.signedIn, !session.consentRequired else { return nil }
        let value = NativeCalendarIdentity(generation: session.sessionGeneration, context: session.context)
        guard UUID(uuidString: value.actor) != nil,
              session.context["is_platform_admin"] as? Bool == true ||
                (value.membershipStatus == "active" && UUID(uuidString: value.organization) != nil) else { return nil }
        return value
    }
    private var writableScopes: [NativeEventScope] { loadedIdentity == identity ? scopes.filter(\.canManage) : [] }
    private var visibleSnapshot: NativeCalendarSnapshot? {
        guard loadedIdentity == identity, snapshot?.month.start == displayedMonth else { return nil }
        return snapshot
    }
    private var dayEvents: [NativeCalendarOccurrence] {
        guard let selectedDay else { return [] }
        return visibleSnapshot?.byDay[selectedDay] ?? []
    }

    var body: some View {
        List {
            if let displayedMonth, let selectedDay, let serverClock {
                Section {
                    NativeCalendarMonthView(month: NativeCalendarMonth(containing: displayedMonth), selectedDay: selectedDay,
                                            today: serverClock.now, counts: visibleSnapshot?.counts ?? [:],
                                            select: select, move: moveMonth, showToday: showToday)
                }.listRowBackground(NativePalette.surface)
            }
            Section {
                Button {
                    if let first = writableScopes.first {
                        var item = NativeEventDraft(scopeId: first.id)
                        if let selectedDay {
                            item.startsAt = NativeCalendarDates.calendar.date(bySettingHour: 10, minute: 0, second: 0, of: selectedDay)!
                            item.endsAt = item.startsAt.addingTimeInterval(3600)
                        }
                        draft = item
                    }
                } label: {
                    Label("일정·모임 추가", systemImage: "plus.circle.fill").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(NativePrimaryButtonStyle()).disabled(busy || writableScopes.isEmpty || session.loading)
                if loading { ProgressView("일정을 확인하고 있습니다").font(.caption) }
                else if writableScopes.isEmpty {
                    Text(error == nil ? "해당 범위의 회장·목사 또는 일정 관리 위임을 받은 계정에서 등록할 수 있습니다." : "등록 권한을 확인하지 못했습니다. 아래에서 다시 불러와 주세요.")
                        .font(.caption).foregroundStyle(NativePalette.muted)
                }
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("다시 불러오기") { Task { await load() } }.frame(minHeight: 44).disabled(loading)
                }
            }
            if requiresAuth {
                Section {
                    Text("일정 등록·변경·취소에는 최근 Google 인증이 필요합니다. 인증 후 원하는 작업 버튼을 다시 눌러 주세요.")
                        .font(.subheadline).foregroundStyle(NativePalette.muted)
                    Button("Google로 본인 확인") { Task { await reauthenticate() } }.frame(minHeight: 44).disabled(busy)
                }
            }
            Section(selectedDay.map { NativeCalendarDates.label($0, format: "M월 d일 (E) 일정") } ?? "일정") {
                if dayEvents.isEmpty && !loading && error == nil {
                    ContentUnavailableView("선택한 날짜에 일정이 없습니다", systemImage: "calendar", description: Text("다른 날짜나 달을 선택해 예배와 모임을 확인하세요."))
                }
                ForEach(dayEvents) { occurrence in
                    let row = occurrence.row
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(nativeText(row, "scope_name")).font(.caption).foregroundStyle(NativePalette.forest)
                            Spacer()
                            if nativeText(row, "event_status") == "cancelled" || nativeText(row, "occurrence_status") == "cancelled" {
                                Text("취소됨").font(.caption).foregroundStyle(.red)
                            }
                        }
                        Text(nativeText(row, "title")).font(.headline).foregroundStyle(NativePalette.ink)
                        Text(NativeEventDraft.dateLabel(occurrence.startsAt) + " ~ " + NativeEventDraft.dateLabel(occurrence.endsAt))
                            .font(.subheadline).foregroundStyle(NativePalette.muted)
                        if !nativeText(row, "host_name").isEmpty { Text("주최자 · " + nativeText(row, "host_name")).font(.subheadline) }
                        if !nativeText(row, "location_text").isEmpty { Label(nativeText(row, "location_text"), systemImage: "mappin.and.ellipse").font(.subheadline) }
                        NavigationLink("참석·미정·불참 응답") { NativeGatheringRSVPView(occurrence: row) }.frame(minHeight: 44)
                        NavigationLink("설문·배정·QR·현장 운영") { NativeEventFieldView(occurrenceID: occurrence.id) }.frame(minHeight: 44)
                        if row["can_manage"] as? Bool == true && writableScopes.contains(where: { $0.id == occurrence.scopeID }) && nativeText(row, "event_status") == "scheduled" {
                            HStack {
                                Button("일정 수정") { Task { await edit(row) } }.frame(minHeight: 44)
                                Spacer()
                                Button("일정 취소", role: .destructive) {
                                    guard let id = UUID(uuidString: nativeText(row, "event_id")) else { return }
                                    cancellationReason = ""
                                    cancelling = NativeEventCancellation(eventId: id.uuidString, scopeId: occurrence.scopeID, title: nativeText(row, "title"))
                                }.frame(minHeight: 44)
                            }.font(.subheadline.weight(.semibold)).disabled(busy || session.loading)
                        }
                    }.padding(.vertical, 10).listRowBackground(NativePalette.surface)
                }
            }
            if !loading && writableScopes.isEmpty && error == nil {
                Section {
                    Text("일정 등록 권한은 총회·노회·교회의 해당 범위 담당자에게 있습니다. 가입 시 선택한 직책만으로 권한이 생기지는 않습니다.")
                        .font(.footnote).foregroundStyle(NativePalette.muted)
                }
            }
        }
        .navigationTitle("일정·모임").nativePageStyle().tint(NativePalette.forest)
        .refreshable { await load() }
        .task(id: NativeCalendarLoadKey(identity: identity, month: displayedMonth)) {
            if loadedIdentity != identity { clearPrivateState() }
            await load(reuseBootstrap: true)
        }
        .onChange(of: identity) { _, _ in clearPrivateState() }
        .sheet(item: $draft) { item in
            NavigationStack { NativeEventEditorView(initial: item, scopes: writableScopes) { await load() } }.environmentObject(session)
        }
        .sheet(item: $cancelling) { cancellation in
            NavigationStack {
                Form {
                    if let error { Section { Text(error).foregroundStyle(.red) } }
                    Section {
                        Text(cancellation.title).font(.headline)
                        Text("반복 일정이라면 전체 일정이 취소됩니다. 기존 참석 응답은 감사 기록과 함께 유지됩니다.").font(.subheadline).foregroundStyle(NativePalette.muted)
                        TextField("취소 사유 (2~500자)", text: $cancellationReason, axis: .vertical).lineLimit(3...8)
                    }
                    Section {
                        Button("일정 전체 취소", role: .destructive) { Task { await cancel(cancellation) } }
                            .frame(minHeight: 44).disabled(busy || cancellationReason.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || cancellationReason.count > 500)
                    }
                }.navigationTitle("일정 취소").nativePageStyle()
                    .disabled(busy || session.loading).interactiveDismissDisabled(busy)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { cancelling = nil }.disabled(busy) } }
            }
        }
    }

    private func select(_ day: Date) {
        selectedDay = NativeCalendarDates.day(day)
        displayedMonth = NativeCalendarDates.month(day)
    }
    private func moveMonth(_ offset: Int) {
        guard let displayedMonth, let selectedDay else { return }
        let target = NativeCalendarDates.movingMonth(displayedMonth, by: offset, selectedDay: selectedDay)
        self.selectedDay = target.day; self.displayedMonth = target.month
    }
    private func showToday() { if let serverClock { select(serverClock.now) } }

    @MainActor private func load(reuseBootstrap: Bool = false) async {
        guard let actor = identity else { clearPrivateState(); return }
        let key = NativeCalendarLoadKey(identity: actor, month: displayedMonth)
        guard !loading || inFlightLoad != key else { return }
        let token = UUID(); loadGeneration = token; inFlightLoad = key
        let requestedMonth = displayedMonth
        let useBootstrap = reuseBootstrap && bootstrapReady && loadedIdentity == actor && serverClock != nil
        bootstrapReady = false
        loading = true; error = nil
        defer {
            if identity == actor && loadGeneration == token { loading = false; inFlightLoad = nil }
        }
        do {
            let freshScopes: [NativeEventScope]
            if useBootstrap {
                freshScopes = scopes
            } else {
                // Capability discovery and the server clock are independent reads.
                async let scopeValue = session.api.rpc("get_my_event_scopes")
                async let clockValue = session.api.rpc("get_sensitive_action_auth_status")
                guard let rows = try await scopeValue as? [[String: Any]] else { throw NativeAPIError.invalidData }
                freshScopes = try rows.map(NativeEventScope.init)
                guard isCurrent(actor, token: token) else { return }
                scopes = freshScopes; loadedIdentity = actor
                if let snapshot {
                    let allowed = Set(freshScopes.map(\.id))
                    self.snapshot = NativeCalendarSnapshot(month: snapshot.month, occurrences: snapshot.occurrences.filter { allowed.contains($0.scopeID) })
                }
                guard let status = try await clockValue as? [String: Any],
                      let now = NativeEventDraft.parseDate(nativeText(status, "server_now")) else { throw NativeAPIError.invalidData }
                guard isCurrent(actor, token: token) else { return }
                serverClock = NativeCalendarServerClock(serverNow: now)
            }
            guard let serverClock else { throw NativeAPIError.invalidData }
            guard let requestedMonth else {
                bootstrapReady = true
                selectedDay = NativeCalendarDates.day(serverClock.now)
                displayedMonth = NativeCalendarDates.month(serverClock.now)
                return
            }
            let month = NativeCalendarMonth(containing: requestedMonth)
            let events = try await NativeCalendarLoader.fetch(range: month.queryRange, isCurrent: { isCurrent(actor, token: token) }) { range, limit in
                guard let result = try await session.api.rpc("list_event_occurrences", body: [
                    "p_from": NativeCalendarDates.queryDate(range.start), "p_to": NativeCalendarDates.queryDate(range.end),
                    "p_scope_id": NSNull(), "p_limit": limit
                ]) as? [[String: Any]] else { throw NativeAPIError.invalidData }
                return result
            }
            guard isCurrent(actor, token: token), displayedMonth == requestedMonth else { return }
            let allowed = Set(freshScopes.map(\.id))
            guard events.allSatisfy({ allowed.contains($0.scopeID) }) else { throw NativeAPIError.invalidData }
            snapshot = NativeCalendarSnapshot(month: month, occurrences: events)
        } catch {
            guard isCurrent(actor, token: token) else { return }
            if !NativeCalendarFailurePolicy.preservesSnapshot(error) { snapshot = nil }
            if case NativeAPIError.response(let code) = error, code == 401 || code == 403 {
                scopes = []; snapshot = nil; draft = nil; cancelling = nil
            }
            if case NativeAPIError.sessionExpired = error { scopes = []; draft = nil; cancelling = nil }
            self.error = error.localizedDescription
        }
    }
    private func isCurrent(_ actor: NativeCalendarIdentity, token: UUID) -> Bool {
        identity == actor && loadGeneration == token && !Task.isCancelled
    }
    private func isCurrentOperation(_ actor: NativeCalendarIdentity, token: UUID) -> Bool {
        identity == actor && operation == token && !Task.isCancelled
    }
    @MainActor private func reauthenticate() async {
        guard !busy, identity != nil else { return }
        let token = UUID(); operation = token
        _ = await session.reauthenticateGoogle()
        if operation == token { operation = nil }
        // Reauthentication changes the session generation. A new task reloads; never replay a mutation.
    }
    @MainActor private func edit(_ occurrence: [String: Any]) async {
        guard !busy, let actor = identity, let id = UUID(uuidString: nativeText(occurrence, "event_id")) else { return }
        let token = UUID(); operation = token; error = nil
        defer { if isCurrentOperation(actor, token: token) { operation = nil } }
        do {
            let rows = try await session.api.rows("events", query: "select=id,scope_id,title,host_name,description,location_text,starts_at,ends_at,capacity,recurrence_frequency,recurrence_interval,recurrence_weekdays,recurrence_month_day,recurrence_month_week,recurrence_month_weekday,recurrence_until,recurrence_count,reminder_offsets_minutes,status,revision&id=eq.\(id.uuidString)&limit=1")
            guard isCurrentOperation(actor, token: token) else { return }
            guard let row = rows.first, nativeText(row, "status") == "scheduled", writableScopes.contains(where: { $0.id == nativeText(row, "scope_id") }) else { throw NativeAPIError.security("수정 권한 또는 일정 상태가 변경되었습니다. 다시 불러와 주세요.") }
            draft = try NativeEventDraft(row: row)
        } catch { if isCurrentOperation(actor, token: token) { self.error = error.localizedDescription } }
    }
    @MainActor private func cancel(_ cancellation: NativeEventCancellation) async {
        guard !busy, let actor = identity else { return }
        let token = UUID(); operation = token; error = nil
        let reason = cancellationReason.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { if isCurrentOperation(actor, token: token) { operation = nil } }
        do {
            let status = try await session.api.rpc("get_sensitive_action_auth_status") as? [String: Any]
            guard isCurrentOperation(actor, token: token) else { return }
            guard status?["verified"] as? Bool == true else { requiresAuth = true; cancelling = nil; return }
            let currentScopes = try await session.api.rpc("get_my_event_scopes") as? [[String: Any]]
            guard isCurrentOperation(actor, token: token) else { return }
            guard currentScopes?.contains(where: { nativeText($0, "scope_id") == cancellation.scopeId && $0["can_manage_events"] as? Bool == true }) == true else { throw NativeAPIError.security("일정 취소 권한이 변경되었습니다. 다시 불러와 주세요.") }
            let result = try await session.api.rpc("cancel_event", body: ["p_event_id": cancellation.eventId, "p_client_operation_id": cancellation.id.uuidString, "p_reason": reason])
            guard isCurrentOperation(actor, token: token) else { return }
            guard let row = result as? [String: Any], nativeText(row, "status") == "cancelled" else { throw NativeAPIError.invalidData }
            cancelling = nil; operation = nil; await load()
        } catch { if isCurrentOperation(actor, token: token) { self.error = error.localizedDescription } }
    }
    private func clearPrivateState() {
        loadGeneration = UUID(); operation = nil; loading = false
        inFlightLoad = nil; bootstrapReady = false
        loadedIdentity = nil; scopes = []; snapshot = nil; displayedMonth = nil; selectedDay = nil; serverClock = nil
        draft = nil; cancelling = nil; cancellationReason = ""; requiresAuth = false; error = nil
    }
}

struct NativeEventScope: Identifiable {
    let id: String
    let name: String
    let canManage: Bool
    init(row: [String: Any]) throws {
        guard let id = row["scope_id"] as? String, UUID(uuidString: id) != nil, let name = row["scope_name"] as? String, let allowed = row["can_manage_events"] as? Bool else { throw NativeAPIError.invalidData }
        self.id = id; self.name = name; canManage = allowed
    }
}

private struct NativeEventCancellation: Identifiable {
    let id = UUID()
    let eventId: String
    let scopeId: String
    let title: String
}

struct NativeEventDraft: Identifiable {
    let id: UUID
    let create: Bool
    var scopeId: String
    var title = ""
    var host = ""
    var description = ""
    var location = ""
    var startsAt = Date().addingTimeInterval(86400)
    var endsAt = Date().addingTimeInterval(90000)
    var capacity = ""
    var frequency = "none"
    var interval = 1
    var weekdays: [Int] = []
    var monthDay: Int?
    var monthWeek: Int?
    var monthWeekday: Int?
    var recurrenceUntil: String?
    var recurrenceCount: Int?
    var reminders: [Int] = []
    let originalRevision: Int?

    init(scopeId: String) { id = UUID(); create = true; self.scopeId = scopeId; originalRevision = nil }
    init(row: [String: Any]) throws {
        guard let id = UUID(uuidString: nativeText(row, "id")), let start = Self.parseDate(nativeText(row, "starts_at")), let end = Self.parseDate(nativeText(row, "ends_at")), let revision = row["revision"] as? Int else { throw NativeAPIError.invalidData }
        self.id = id; create = false; scopeId = nativeText(row, "scope_id"); title = nativeText(row, "title"); host = nativeText(row, "host_name")
        description = nativeText(row, "description"); location = nativeText(row, "location_text"); startsAt = start; endsAt = end
        capacity = (row["capacity"] as? Int).map(String.init) ?? ""
        frequency = nativeText(row, "recurrence_frequency", fallback: "none"); interval = row["recurrence_interval"] as? Int ?? 1
        weekdays = row["recurrence_weekdays"] as? [Int] ?? []; monthDay = row["recurrence_month_day"] as? Int
        monthWeek = row["recurrence_month_week"] as? Int; monthWeekday = row["recurrence_month_weekday"] as? Int
        recurrenceUntil = row["recurrence_until"] as? String; recurrenceCount = row["recurrence_count"] as? Int
        reminders = row["reminder_offsets_minutes"] as? [Int] ?? []; originalRevision = revision
    }
    private static let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoFormatter = ISO8601DateFormatter()
    private static let seoulDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "M월 d일 (E) a h:mm"
        return formatter
    }()
    static func parseDate(_ text: String) -> Date? {
        fractionalISOFormatter.date(from: text) ?? isoFormatter.date(from: text)
    }
    static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }
    static func dateLabel(_ text: String) -> String {
        guard let date = parseDate(text) else { return "일시를 확인해 주세요" }
        return dateLabel(date)
    }
    static func dateLabel(_ date: Date) -> String { seoulDateFormatter.string(from: date) }
    var validation: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 200 { return "제목은 1~200자로 입력해 주세요." }
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || host.count > 100 { return "주최자를 1~100자로 입력해 주세요." }
        if description.count > 10000 || location.count > 500 { return "설명은 10,000자, 장소는 500자 이내로 입력해 주세요." }
        if endsAt <= startsAt || endsAt.timeIntervalSince(startsAt) > 7 * 86400 { return "종료는 시작 이후 7일 이내여야 합니다." }
        if UUID(uuidString: scopeId) == nil { return "공개 범위를 선택해 주세요." }
        if !capacity.isEmpty && (Int(capacity) == nil || (Int(capacity) ?? 0) < 1 || (Int(capacity) ?? 0) > 100000) { return "정원은 1~100,000명 또는 비워 두세요." }
        if !["none", "daily", "weekly", "monthly"].contains(frequency) { return "반복 방식을 확인해 주세요." }
        if reminders.count > 5 || Set(reminders).count != reminders.count || reminders.contains(where: { $0 < 0 || $0 > 40320 }) { return "알림은 최대 5개, 시작 4주 전까지 설정할 수 있습니다." }
        if frequency != "none" && recurrenceUntil == nil && ((recurrenceCount ?? 0) < 2 || (recurrenceCount ?? 0) > (frequency == "monthly" ? 25 : 366)) { return frequency == "monthly" ? "매월 반복은 2~25회로 지정해 주세요. 서버에서 2년 이내 생성 가능한지도 확인합니다." : "반복 횟수는 2~366회로 지정해 주세요." }
        if frequency != "none" && interval < 1 { return "반복 간격을 확인해 주세요." }
        if frequency == "daily" && interval > 30 || frequency == "weekly" && interval > 4 || frequency == "monthly" && interval > 12 { return "반복 간격을 확인해 주세요." }
        if let until = recurrenceUntil, frequency != "none" {
            guard let date = Self.parseDate(until), date > startsAt, date.timeIntervalSince(startsAt) <= 2 * 366 * 86400 else { return "반복 종료일은 시작 이후 2년 이내여야 합니다." }
        }
        if frequency == "monthly" && monthWeek != nil {
            guard [-1, 1, 2, 3, 4].contains(monthWeek!), (1...7).contains(monthWeekday ?? 0),
                  Self.matchesMonthWeekday(startsAt, week: monthWeek!, weekday: monthWeekday!) else { return "첫 시작일이 선택한 주차·요일과 일치해야 합니다." }
        } else if frequency == "monthly" && !(1...31).contains(monthDay ?? 0) { return "매월 반복할 날짜를 선택해 주세요." }
        if frequency == "weekly" && weekdays.isEmpty { return "매주 반복할 요일을 선택해 주세요." }
        return nil
    }
    static let seoulCalendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return value
    }()
    static func matchesMonthWeekday(_ date: Date, week: Int, weekday: Int) -> Bool {
        let calendar = seoulCalendar
        let isoDay = (calendar.component(.weekday, from: date) + 5) % 7 + 1
        guard isoDay == weekday else { return false }
        if week == -1 { return calendar.component(.month, from: calendar.date(byAdding: .day, value: 7, to: date)!) != calendar.component(.month, from: date) }
        return (calendar.component(.day, from: date) - 1) / 7 + 1 == week
    }
    mutating func alignMonthlyStart() {
        guard let week = monthWeek, let weekday = monthWeekday else { return }
        let calendar = Self.seoulCalendar, duration = endsAt.timeIntervalSince(startsAt)
        for offset in 0...62 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: startsAt) else { continue }
            if Self.matchesMonthWeekday(candidate, week: week, weekday: weekday) { startsAt = candidate; endsAt = candidate.addingTimeInterval(duration); return }
        }
    }
    mutating func alignWeeklyStart() {
        let calendar = Self.seoulCalendar, duration = endsAt.timeIntervalSince(startsAt)
        guard !weekdays.isEmpty else { return }
        for offset in 0...6 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: startsAt) else { continue }
            if weekdays.contains((calendar.component(.weekday, from: candidate) + 5) % 7 + 1) { startsAt = candidate; endsAt = candidate.addingTimeInterval(duration); return }
        }
    }
    var body: [String: Any] {
        ["p_id": id.uuidString, "p_create": create, "p_scope_id": scopeId, "p_title": title.trimmingCharacters(in: .whitespacesAndNewlines), "p_host_name": host.trimmingCharacters(in: .whitespacesAndNewlines), "p_description": description.trimmingCharacters(in: .whitespacesAndNewlines), "p_location_text": location.trimmingCharacters(in: .whitespacesAndNewlines), "p_starts_at": Self.iso(startsAt), "p_ends_at": Self.iso(endsAt), "p_capacity": Int(capacity).map { $0 as Any } ?? NSNull(), "p_recurrence_frequency": frequency, "p_recurrence_interval": frequency == "none" ? 1 : interval, "p_recurrence_weekdays": frequency == "weekly" ? weekdays.sorted() : [], "p_recurrence_month_day": frequency == "monthly" ? (monthDay.map { $0 as Any } ?? NSNull()) : NSNull(), "p_recurrence_until": frequency == "none" ? NSNull() : (recurrenceUntil.map { $0 as Any } ?? NSNull()), "p_recurrence_count": frequency == "none" ? NSNull() : (recurrenceCount.map { $0 as Any } ?? NSNull()), "p_reminder_offsets_minutes": reminders]
    }
    var recurrenceBody: [String: Any] {
        var value = body
        if frequency == "monthly" && monthWeek != nil { value["p_recurrence_month_day"] = NSNull() }
        value["p_recurrence_month_week"] = frequency == "monthly" ? monthWeek.map { $0 as Any } ?? NSNull() : NSNull()
        value["p_recurrence_month_weekday"] = frequency == "monthly" ? monthWeekday.map { $0 as Any } ?? NSNull() : NSNull()
        return value
    }
}

private struct NativeEventEditorView: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NativeEventDraft
    @State private var busy = false
    @State private var error: String?
    @State private var requiresAuth = false
    @State private var retryPayload: [String: Any]?
    let scopes: [NativeEventScope]
    let saved: () async -> Void
    private var identity: NativeCalendarIdentity? {
        guard session.signedIn, !session.consentRequired else { return nil }
        let value = NativeCalendarIdentity(generation: session.sessionGeneration, context: session.context)
        guard UUID(uuidString: value.actor) != nil,
              session.context["is_platform_admin"] as? Bool == true ||
                (value.membershipStatus == "active" && UUID(uuidString: value.organization) != nil) else { return nil }
        return value
    }
    init(initial: NativeEventDraft, scopes: [NativeEventScope], saved: @escaping () async -> Void) { _draft = State(initialValue: initial); self.scopes = scopes; self.saved = saved }
    var body: some View {
        Form {
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Group {
            Section("기본 정보") {
                Picker("공개 범위", selection: $draft.scopeId) { ForEach(scopes) { Text($0.name).tag($0.id) } }.disabled(!draft.create)
                TextField("일정·모임 제목", text: $draft.title)
                TextField("주최자 (사람·기관명)", text: $draft.host)
                Text("주최자 표시는 운영 권한을 부여하지 않습니다. 실제 등록·수정자는 서버에 별도로 기록됩니다.").font(.caption).foregroundStyle(NativePalette.muted)
                TextField("장소", text: $draft.location)
                TextField("일정 설명", text: $draft.description, axis: .vertical).lineLimit(3...8)
            }
            Section("일시 · 한국 시간") {
                DatePicker("시작", selection: $draft.startsAt)
                DatePicker("종료", selection: $draft.endsAt)
                TextField("정원 (비워 두면 제한 없음)", text: $draft.capacity).keyboardType(.numberPad)
            }
            Section("반복 일정") {
                Picker("반복", selection: $draft.frequency) { Text("반복 안 함").tag("none"); Text("매일").tag("daily"); Text("매주").tag("weekly"); Text("매월").tag("monthly") }
                    .onChange(of: draft.frequency) { _, frequency in
                        draft.interval = 1; draft.weekdays = frequency == "weekly" ? [(NativeEventDraft.seoulCalendar.component(.weekday, from: draft.startsAt) + 5) % 7 + 1] : []; draft.monthDay = frequency == "monthly" ? NativeEventDraft.seoulCalendar.component(.day, from: draft.startsAt) : nil
                        draft.monthWeek = nil; draft.monthWeekday = nil
                        draft.recurrenceUntil = nil; draft.recurrenceCount = frequency == "none" ? nil : 12
                    }
                if draft.frequency != "none" {
                    Stepper("\(draft.interval)\(draft.frequency == "daily" ? "일" : draft.frequency == "weekly" ? "주" : "개월")마다", value: $draft.interval, in: 1...(draft.frequency == "weekly" ? 4 : draft.frequency == "daily" ? 30 : 12))
                    if draft.frequency == "weekly" {
                        ForEach(1...7, id: \.self) { weekday in
                            Toggle(["월요일", "화요일", "수요일", "목요일", "금요일", "토요일", "일요일"][weekday - 1], isOn: Binding(get: { draft.weekdays.contains(weekday) }, set: { enabled in draft.weekdays.removeAll { $0 == weekday }; if enabled { draft.weekdays.append(weekday) }; draft.alignWeeklyStart() }))
                        }
                        Text("여러 요일을 선택할 수 있습니다. 첫 시작일도 선택한 요일에 맞춰 변경되므로 위의 일시를 확인해 주세요.").font(.caption).foregroundStyle(NativePalette.muted)
                    }
                    if draft.frequency == "monthly" {
                        Picker("매월 반복 기준", selection: Binding(get: { draft.monthWeek == nil ? "date" : "weekday" }, set: { mode in
                            if mode == "date" { draft.monthWeek = nil; draft.monthWeekday = nil; draft.monthDay = NativeEventDraft.seoulCalendar.component(.day, from: draft.startsAt) }
                            else { draft.monthWeek = 1; draft.monthWeekday = (NativeEventDraft.seoulCalendar.component(.weekday, from: draft.startsAt) + 5) % 7 + 1; draft.monthDay = nil; draft.alignMonthlyStart() }
                        })) { Text("날짜 기준").tag("date"); Text("주차·요일 기준").tag("weekday") }
                        if draft.monthWeek != nil {
                            Picker("주차", selection: Binding(get: { draft.monthWeek ?? 1 }, set: { draft.monthWeek = $0; draft.alignMonthlyStart() })) { Text("첫째").tag(1); Text("둘째").tag(2); Text("셋째").tag(3); Text("넷째").tag(4); Text("마지막").tag(-1) }
                            Picker("요일", selection: Binding(get: { draft.monthWeekday ?? 1 }, set: { draft.monthWeekday = $0; draft.alignMonthlyStart() })) { ForEach(1...7, id: \.self) { Text(["월요일","화요일","수요일","목요일","금요일","토요일","일요일"][$0-1]).tag($0) } }
                            Text("선택한 규칙에 맞는 다음 날짜로 첫 시작일을 맞춥니다. 위의 시작·종료 일시를 확인해 주세요. 마지막 주는 해당 요일의 마지막 날짜입니다.").font(.caption).foregroundStyle(NativePalette.muted)
                        } else {
                            Picker("매월 날짜", selection: Binding(get: { draft.monthDay ?? 1 }, set: { draft.monthDay = $0 })) { ForEach(1...31, id: \.self) { Text("\($0)일").tag($0) } }
                        }
                    }
                    if let until = draft.recurrenceUntil {
                        Text("기존 반복 종료: " + NativeEventDraft.dateLabel(until)).font(.subheadline)
                        Button("반복 횟수로 변경") { draft.recurrenceUntil = nil; draft.recurrenceCount = 12 }
                    } else {
                        Stepper("반복 \(draft.recurrenceCount ?? 12)회", value: Binding(get: { draft.recurrenceCount ?? 12 }, set: { draft.recurrenceCount = $0 }), in: 2...(draft.frequency == "monthly" ? 25 : 366))
                    }
                    Text("수정과 취소는 반복 일정 전체에 적용됩니다.").font(.caption).foregroundStyle(NativePalette.muted)
                }
            }
            Section("알림") {
                Toggle("하루 전 알림", isOn: Binding(get: { draft.reminders.contains(1440) }, set: { enabled in draft.reminders.removeAll { $0 == 1440 }; if enabled { draft.reminders.append(1440) } }))
                Toggle("한 시간 전 알림", isOn: Binding(get: { draft.reminders.contains(60) }, set: { enabled in draft.reminders.removeAll { $0 == 60 }; if enabled { draft.reminders.append(60) } }))
            }
            }.disabled(retryPayload != nil)
            if requiresAuth {
                Section {
                    Text("최근 Google 인증이 필요합니다. 본인 확인 후 저장 버튼을 다시 눌러 주세요.").font(.subheadline)
                    Button("Google로 본인 확인") { Task { await reauthenticate() } }.frame(minHeight: 44)
                }
            }
            Section {
                if let validation = draft.validation { Text(validation).font(.footnote).foregroundStyle(NativePalette.muted) }
                Button(retryPayload != nil ? "같은 일정 등록 결과 확인" : draft.create ? "일정 등록" : "변경사항 저장") { Task { await save() } }.buttonStyle(NativePrimaryButtonStyle()).disabled(draft.validation != nil)
                if retryPayload != nil { Text("내용을 유지한 채 같은 식별자로 확인합니다. 이미 등록됐다면 중복 생성하지 않습니다.").font(.caption).foregroundStyle(NativePalette.muted) }
            }
        }
        .environment(\.timeZone, TimeZone(identifier: "Asia/Seoul")!)
        .navigationTitle(draft.create ? "일정 추가" : "일정 수정").nativePageStyle().tint(NativePalette.forest)
        .disabled(busy || session.loading).interactiveDismissDisabled(busy)
        .onChange(of: identity) { _, _ in retryPayload = nil; dismiss() }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() }.disabled(busy) } }
    }
    @MainActor private func reauthenticate() async {
        guard !busy, let actor = identity else { return }
        busy = true
        let verified = await session.reauthenticateGoogle()
        guard identity == actor else { return }
        requiresAuth = !verified; busy = false
    }
    @MainActor private func save() async {
        guard !busy, draft.validation == nil, let actor = identity,
              scopes.contains(where: { $0.id == draft.scopeId && $0.canManage }) else { return }
        busy = true; error = nil
        var payload = retryPayload ?? draft.recurrenceBody
        payload["p_expected_revision"] = draft.originalRevision.map { $0 as Any } ?? NSNull()
        var attempted = false
        defer { if identity == actor { busy = false } }
        do {
            let statusValue = try await session.api.rpc("get_sensitive_action_auth_status")
            guard identity == actor, !Task.isCancelled else { return }
            guard let status = statusValue as? [String: Any] else { throw NativeAPIError.invalidData }
            guard status["verified"] as? Bool == true else { requiresAuth = true; return }
            let scopeValue = try await session.api.rpc("get_my_event_scopes")
            guard identity == actor, !Task.isCancelled else { return }
            guard let currentScopes = scopeValue as? [[String: Any]], currentScopes.contains(where: { nativeText($0, "scope_id") == draft.scopeId && $0["can_manage_events"] as? Bool == true }) else { throw NativeAPIError.security("일정 등록 권한이 변경되었습니다. 다시 불러와 주세요.") }
            if !draft.create {
                let latest = try await session.api.rows("events", query: "select=revision,status,scope_id&id=eq.\(draft.id.uuidString)&limit=1")
                guard identity == actor, !Task.isCancelled else { return }
                guard let row = latest.first, nativeText(row, "scope_id") == draft.scopeId,
                      row["revision"] as? Int == draft.originalRevision, nativeText(row, "status") == "scheduled" else { throw NativeAPIError.security("다른 관리자가 변경한 일정입니다. 닫고 다시 불러온 후 수정해 주세요.") }
            }
            guard identity == actor, !Task.isCancelled else { return }
            attempted = true
            let result = try await session.api.rpc("save_event_recurrence_checked", body: payload)
            guard identity == actor, !Task.isCancelled else { return }
            guard let id = result as? String, UUID(uuidString: id) == draft.id else { throw NativeAPIError.invalidData }
            dismiss(); await saved()
        } catch {
            guard identity == actor, !Task.isCancelled else { return }
            if attempted && draft.create { retryPayload = payload }
            self.error = error.localizedDescription
        }
    }
}
