import SwiftUI

/// Native controls for the existing event service. Scope discovery is server-authoritative.
struct NativeEventOperationsView: View {
    @EnvironmentObject private var session: NativeSession
    @State private var scopes: [NativeEventScope] = []
    @State private var occurrences: [[String: Any]] = []
    @State private var draft: NativeEventDraft?
    @State private var busy = false
    @State private var error: String?
    @State private var requiresAuth = false
    @State private var cancelling: NativeEventCancellation?
    @State private var cancellationReason = ""
    private var writableScopes: [NativeEventScope] { scopes.filter(\.canManage) }
    private var actorID: String { nativeText(session.context["profile"] as? [String: Any] ?? [:], "id") }

    var body: some View {
        List {
            Section {
                Button {
                    if let first = writableScopes.first { draft = NativeEventDraft(scopeId: first.id) }
                } label: {
                    Label("일정·모임 추가", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(NativePrimaryButtonStyle())
                    .disabled(busy || writableScopes.isEmpty)
                if busy { Text("등록 가능한 범위를 확인하고 있습니다.").font(.caption).foregroundStyle(NativePalette.muted) }
                else if writableScopes.isEmpty {
                    Text(error == nil ? "해당 범위의 회장·목사 또는 일정 관리 위임을 받은 계정에서 등록할 수 있습니다." : "등록 권한을 확인하지 못했습니다. 아래에서 다시 불러와 주세요.")
                        .font(.caption).foregroundStyle(NativePalette.muted)
                }
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("다시 불러오기") { Task { await load() } }.frame(minHeight: 44)
                }
            }
            if requiresAuth {
                Section {
                    Text("일정 등록·변경·취소에는 최근 Google 인증이 필요합니다. 인증 후 원하는 작업 버튼을 다시 눌러 주세요.")
                        .font(.subheadline).foregroundStyle(NativePalette.muted)
                    Button("Google로 본인 확인") {
                        Task {
                            guard !busy else { return }; busy = true
                            let verified = await session.reauthenticateGoogle()
                            busy = false
                            if verified { requiresAuth = false; await load() }
                        }
                    }.frame(minHeight: 44)
                }
            }
            if busy { ProgressView("일정을 확인하고 있습니다") }
            if !busy && occurrences.isEmpty && error == nil {
                ContentUnavailableView("예정된 일정이 없습니다", systemImage: "calendar", description: Text("등록된 예배와 모임이 여기에 표시됩니다."))
            }
            ForEach(occurrences.indices, id: \.self) { index in
                let row = occurrences[index]
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(nativeText(row, "scope_name")).font(.caption).foregroundStyle(NativePalette.forest)
                        Spacer()
                        if nativeText(row, "event_status") == "cancelled" { Text("취소됨").font(.caption).foregroundStyle(.red) }
                    }
                    Text(nativeText(row, "title")).font(.headline).foregroundStyle(NativePalette.ink)
                    Text(NativeEventDraft.dateLabel(nativeText(row, "starts_at"))).font(.subheadline).foregroundStyle(NativePalette.muted)
                    if !nativeText(row, "host_name").isEmpty { Text("주최자 · " + nativeText(row, "host_name")).font(.subheadline) }
                    if !nativeText(row, "location_text").isEmpty { Label(nativeText(row, "location_text"), systemImage: "mappin.and.ellipse").font(.subheadline) }
                    if row["can_manage"] as? Bool == true && nativeText(row, "event_status") == "scheduled" {
                        HStack {
                            Button("일정 수정") { Task { await edit(row) } }.frame(minHeight: 44)
                            Spacer()
                            Button("일정 취소", role: .destructive) {
                                guard let id = UUID(uuidString: nativeText(row, "event_id")) else { return }
                                cancellationReason = ""
                                cancelling = NativeEventCancellation(eventId: id.uuidString, title: nativeText(row, "title"))
                            }.frame(minHeight: 44)
                        }.font(.subheadline.weight(.semibold))
                    }
                }.padding(.vertical, 10).listRowBackground(NativePalette.surface)
            }
            if !busy && writableScopes.isEmpty && error == nil {
                Section {
                    Text("일정 등록 권한은 총회·노회·교회의 해당 범위 담당자에게 있습니다. 가입 시 선택한 직책만으로 권한이 생기지는 않습니다.")
                        .font(.footnote).foregroundStyle(NativePalette.muted)
                }
            }
        }
        .navigationTitle("일정·모임").nativePageStyle().tint(NativePalette.forest)
        .disabled(busy || session.loading)
        .refreshable { await load() }.task { await load() }
        .onChange(of: actorID) { _, _ in clearPrivateState() }
        .onChange(of: session.consentRequired) { _, required in if required { clearPrivateState() } }
        .onChange(of: session.signedIn) { _, signedIn in if !signedIn { clearPrivateState() } }
        .sheet(item: $draft) { item in
            NavigationStack { NativeEventEditorView(initial: item, scopes: writableScopes) { await load() } }
                .environmentObject(session)
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

    @MainActor private func load() async {
        guard !busy, session.signedIn, !session.consentRequired, !actorID.isEmpty else { return }
        let actor = actorID
        busy = true; error = nil; scopes = []
        defer { busy = false }
        do {
            guard let rows = try await session.api.rpc("get_my_event_scopes") as? [[String: Any]] else { throw NativeAPIError.invalidData }
            let freshScopes = try rows.map(NativeEventScope.init)
            guard session.signedIn, !session.consentRequired, actor == actorID else { clearPrivateState(); return }
            // Calendar reads must not hide independently verified creation capabilities.
            scopes = freshScopes
            // Server time avoids a wrong device clock hiding valid forthcoming events.
            let status = try await session.api.rpc("get_sensitive_action_auth_status") as? [String: Any]
            guard let nowText = status?["server_now"] as? String, let now = NativeEventDraft.parseDate(nowText) else { throw NativeAPIError.invalidData }
            guard let events = try await session.api.rpc("list_event_occurrences", body: [
                "p_from": NativeEventDraft.iso(now), "p_to": NativeEventDraft.iso(now.addingTimeInterval(90 * 86400)), "p_scope_id": NSNull(), "p_limit": 100
            ]) as? [[String: Any]] else { throw NativeAPIError.invalidData }
            guard session.signedIn, !session.consentRequired, actor == actorID else { clearPrivateState(); return }
            scopes = freshScopes; occurrences = events
        } catch {
            guard session.signedIn, !session.consentRequired, actor == actorID else { clearPrivateState(); return }
            occurrences = []; self.error = error.localizedDescription
        }
    }

    @MainActor private func edit(_ occurrence: [String: Any]) async {
        guard !busy, let id = UUID(uuidString: nativeText(occurrence, "event_id")) else { return }
        let actor = actorID
        busy = true; error = nil
        defer { busy = false }
        do {
            // Load the series definition, never overwrite its initial date with a later occurrence.
            let rows = try await session.api.rows("events", query: "select=id,scope_id,title,host_name,description,location_text,starts_at,ends_at,capacity,recurrence_frequency,recurrence_interval,recurrence_weekdays,recurrence_month_day,recurrence_until,recurrence_count,reminder_offsets_minutes,status,revision&id=eq.\(id.uuidString)&limit=1")
            guard let row = rows.first, nativeText(row, "status") == "scheduled", writableScopes.contains(where: { $0.id == nativeText(row, "scope_id") }) else { throw NativeAPIError.security("수정 권한 또는 일정 상태가 변경되었습니다. 다시 불러와 주세요.") }
            guard session.signedIn, !session.consentRequired, actor == actorID else { return }
            draft = try NativeEventDraft(row: row)
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func cancel(_ cancellation: NativeEventCancellation) async {
        guard !busy, session.signedIn, !session.consentRequired else { return }; busy = true; error = nil
        let actor = actorID
        do {
            let status = try await session.api.rpc("get_sensitive_action_auth_status") as? [String: Any]
            guard status?["verified"] as? Bool == true else { requiresAuth = true; cancelling = nil; busy = false; return }
            guard actor == actorID, session.signedIn, !session.consentRequired else { clearPrivateState(); busy = false; return }
            let result = try await session.api.rpc("cancel_event", body: ["p_event_id": cancellation.eventId, "p_client_operation_id": cancellation.id.uuidString, "p_reason": cancellationReason.trimmingCharacters(in: .whitespacesAndNewlines)])
            guard let row = result as? [String: Any], nativeText(row, "status") == "cancelled" else { throw NativeAPIError.invalidData }
            cancelling = nil; busy = false; await load()
        } catch { busy = false; self.error = error.localizedDescription }
    }
    private func clearPrivateState() { scopes = []; occurrences = []; draft = nil; cancelling = nil; cancellationReason = ""; requiresAuth = false; error = nil }
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
        recurrenceUntil = row["recurrence_until"] as? String; recurrenceCount = row["recurrence_count"] as? Int
        reminders = row["reminder_offsets_minutes"] as? [Int] ?? []; originalRevision = revision
    }
    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func dateLabel(_ text: String) -> String {
        guard let date = parseDate(text) else { return "일시를 확인해 주세요" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ko_KR"); formatter.timeZone = TimeZone(identifier: "Asia/Seoul"); formatter.dateFormat = "M월 d일 (E) a h:mm"
        return formatter.string(from: date)
    }
    var validation: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 200 { return "제목은 1~200자로 입력해 주세요." }
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || host.count > 100 { return "주최자를 1~100자로 입력해 주세요." }
        if description.count > 10000 || location.count > 500 { return "설명은 10,000자, 장소는 500자 이내로 입력해 주세요." }
        if endsAt <= startsAt || endsAt.timeIntervalSince(startsAt) > 7 * 86400 { return "종료는 시작 이후 7일 이내여야 합니다." }
        if UUID(uuidString: scopeId) == nil { return "공개 범위를 선택해 주세요." }
        if !capacity.isEmpty && (Int(capacity) == nil || (Int(capacity) ?? 0) < 1 || (Int(capacity) ?? 0) > 100000) { return "정원은 1~100,000명 또는 비워 두세요." }
        if !["none", "daily", "weekly", "monthly"].contains(frequency) { return "반복 방식을 확인해 주세요." }
        if reminders.count > 5 || Set(reminders).count != reminders.count || reminders.contains(where: { $0 < 0 || $0 > 40320 }) { return "알림은 최대 5개, 시작 4주 전까지 설정할 수 있습니다." }
        if frequency != "none" && recurrenceUntil == nil && ((recurrenceCount ?? 0) < 2 || (recurrenceCount ?? 0) > 366) { return "반복 횟수는 2~366회로 지정해 주세요." }
        if frequency != "none" && interval < 1 { return "반복 간격을 확인해 주세요." }
        if frequency == "daily" && interval > 30 || frequency == "weekly" && interval > 4 || frequency == "monthly" && interval > 12 { return "반복 간격을 확인해 주세요." }
        if let until = recurrenceUntil, frequency != "none" {
            guard let date = Self.parseDate(until), date > startsAt, date.timeIntervalSince(startsAt) <= 2 * 366 * 86400 else { return "반복 종료일은 시작 이후 2년 이내여야 합니다." }
        }
        if frequency == "monthly" && !(1...31).contains(monthDay ?? 0) { return "매월 반복할 날짜를 선택해 주세요." }
        if frequency == "weekly" && weekdays.isEmpty { return "매주 반복할 요일을 선택해 주세요." }
        return nil
    }
    var body: [String: Any] {
        ["p_id": id.uuidString, "p_create": create, "p_scope_id": scopeId, "p_title": title.trimmingCharacters(in: .whitespacesAndNewlines), "p_host_name": host.trimmingCharacters(in: .whitespacesAndNewlines), "p_description": description.trimmingCharacters(in: .whitespacesAndNewlines), "p_location_text": location.trimmingCharacters(in: .whitespacesAndNewlines), "p_starts_at": Self.iso(startsAt), "p_ends_at": Self.iso(endsAt), "p_capacity": Int(capacity).map { $0 as Any } ?? NSNull(), "p_recurrence_frequency": frequency, "p_recurrence_interval": frequency == "none" ? 1 : interval, "p_recurrence_weekdays": frequency == "weekly" ? weekdays.sorted() : [], "p_recurrence_month_day": frequency == "monthly" ? (monthDay.map { $0 as Any } ?? NSNull()) : NSNull(), "p_recurrence_until": frequency == "none" ? NSNull() : (recurrenceUntil.map { $0 as Any } ?? NSNull()), "p_recurrence_count": frequency == "none" ? NSNull() : (recurrenceCount.map { $0 as Any } ?? NSNull()), "p_reminder_offsets_minutes": reminders]
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
    private var actorID: String { nativeText(session.context["profile"] as? [String: Any] ?? [:], "id") }
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
                        draft.interval = 1; draft.weekdays = []; draft.monthDay = frequency == "monthly" ? 1 : nil
                        draft.recurrenceUntil = nil; draft.recurrenceCount = frequency == "none" ? nil : 12
                    }
                if draft.frequency != "none" {
                    Stepper("\(draft.interval)\(draft.frequency == "daily" ? "일" : draft.frequency == "weekly" ? "주" : "개월")마다", value: $draft.interval, in: 1...(draft.frequency == "weekly" ? 4 : draft.frequency == "daily" ? 30 : 12))
                    if draft.frequency == "weekly" {
                        ForEach(1...7, id: \.self) { weekday in
                            Toggle(["월요일", "화요일", "수요일", "목요일", "금요일", "토요일", "일요일"][weekday - 1], isOn: Binding(get: { draft.weekdays.contains(weekday) }, set: { enabled in draft.weekdays.removeAll { $0 == weekday }; if enabled { draft.weekdays.append(weekday) } }))
                        }
                    }
                    if draft.frequency == "monthly" {
                        Picker("매월 날짜", selection: Binding(get: { draft.monthDay ?? 1 }, set: { draft.monthDay = $0 })) { ForEach(1...31, id: \.self) { Text("\($0)일").tag($0) } }
                    }
                    if let until = draft.recurrenceUntil {
                        Text("기존 반복 종료: " + NativeEventDraft.dateLabel(until)).font(.subheadline)
                        Button("반복 횟수로 변경") { draft.recurrenceUntil = nil; draft.recurrenceCount = 12 }
                    } else {
                        Stepper("반복 \(draft.recurrenceCount ?? 12)회", value: Binding(get: { draft.recurrenceCount ?? 12 }, set: { draft.recurrenceCount = $0 }), in: 2...366)
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
                    Button("Google로 본인 확인") { Task { busy = true; if await session.reauthenticateGoogle() { requiresAuth = false }; busy = false } }.frame(minHeight: 44)
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
        .onChange(of: actorID) { _, _ in dismiss() }
        .onChange(of: session.consentRequired) { _, required in if required { dismiss() } }
        .onChange(of: session.signedIn) { _, signedIn in if !signedIn { dismiss() } }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() }.disabled(busy) } }
    }
    @MainActor private func save() async {
        guard !busy, draft.validation == nil, session.signedIn, !session.consentRequired else { return }
        busy = true; error = nil
        let actor = actorID
        var payload = retryPayload ?? draft.body
        payload["p_expected_revision"] = draft.originalRevision.map { $0 as Any } ?? NSNull()
        var attempted = false
        defer { busy = false }
        do {
            guard let status = try await session.api.rpc("get_sensitive_action_auth_status") as? [String: Any] else { throw NativeAPIError.invalidData }
            guard status["verified"] as? Bool == true else { requiresAuth = true; return }
            guard let currentScopes = try await session.api.rpc("get_my_event_scopes") as? [[String: Any]], currentScopes.contains(where: { nativeText($0, "scope_id") == draft.scopeId && $0["can_manage_events"] as? Bool == true }) else { throw NativeAPIError.security("일정 등록 권한이 변경되었습니다. 다시 불러와 주세요.") }
            if !draft.create {
                let latest = try await session.api.rows("events", query: "select=revision,status&id=eq.\(draft.id.uuidString)&limit=1")
                guard let row = latest.first, row["revision"] as? Int == draft.originalRevision, nativeText(row, "status") == "scheduled" else { throw NativeAPIError.security("다른 관리자가 변경한 일정입니다. 닫고 다시 불러온 후 수정해 주세요.") }
            }
            guard actor == actorID, session.signedIn, !session.consentRequired else { dismiss(); return }
            attempted = true
            let result = try await session.api.rpc("save_event_checked", body: payload)
            guard let id = result as? String, UUID(uuidString: id) == draft.id else { throw NativeAPIError.invalidData }
            dismiss(); await saved()
        } catch {
            guard actor == actorID, session.signedIn, !session.consentRequired else { return }
            if attempted && draft.create { retryPayload = payload }
            self.error = error.localizedDescription
        }
    }
}
