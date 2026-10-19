import SwiftUI
import CoreImage.CIFilterBuiltins

struct NativeEventFieldView: View {
    @EnvironmentObject private var session: NativeSession
    let occurrenceID: String
    @State private var state: NativeFieldState?
    @State private var draft: NativeFieldDraft?
    @State private var survey = NativeFieldSurvey()
    @State private var partial = false
    @State private var arrival = Date()
    @State private var departure = Date()
    @State private var busy = false
    @State private var error = ""
    @State private var notice = ""
    @State private var badge: UIImage?
    @State private var badgeExpiry = Date.distantPast
    @State private var scanning = false
    @State private var exportURL: URL?
    @State private var staffUser = ""
    @State private var staffCapabilities: Set<String> = ["checkin"]
    @State private var staffExpiry = Date().addingTimeInterval(3600)
    @State private var loadedIdentity: NativeCalendarIdentity?
    @State private var visible = true
    private var identity: NativeCalendarIdentity? {
        guard session.signedIn, !session.consentRequired else { return nil }
        return NativeCalendarIdentity(generation: session.sessionGeneration, context: session.context)
    }
    private var authorized: Bool { identity != nil && loadedIdentity == identity }
    var body: some View {
        Form {
            if !error.isEmpty { Section {
                Text(error).foregroundStyle(.red).accessibilityAddTraits(.isStaticText)
                Button("Google로 본인 확인") { Task { _ = await session.reauthenticateGoogle() } }
                Button("서버 자료 다시 불러오기") { Task {
                    let actor = identity
                    do { try await load(); if actor == identity { loadedIdentity = actor; error = "" } }
                    catch { if actor == identity { self.error = error.localizedDescription } }
                } }
            } }
            if !notice.isEmpty { Section { Text(notice) } }
            if authorized, let state {
                if state.is_closed == true {
                    Section { Text("취소된 행사입니다. 회계 권한이 있는 담당자의 회비 취소·환불만 계속 사용할 수 있습니다.") }
                } else {
                    surveySection
                    badgeSection
                }
                if state.capabilities.contains("checkin") {
                    Section("온라인 QR 출석") {
                        Button(scanning ? "카메라 닫기" : "QR 카메라 체크인") { scanning.toggle() }
                        if scanning { NativeEventQRScanner { token in perform { try await verify(token) } } onError: { error = $0 }.frame(height: 300) }
                        Text("서버 검증 성공 후에만 출석이 완료됩니다. 오프라인 성공 처리는 하지 않습니다.")
                    }
                }
                if state.capabilities.contains("export") {
                    Section("최소 명단 내보내기") {
                        Text("명단·조·차량·교회 4개 시트. 운영 목적으로만 보관하고 목적 달성 후 삭제하세요. 내려받기는 감사 기록에 남습니다.")
                        Button("XLSX 생성") { perform { try await exportRoster() } }
                        if let exportURL { ShareLink("XLSX 파일 공유 / 저장", item: exportURL) }
                    }
                }
                if state.capabilities.contains("logistics"), draft != nil { logisticsSection }
                if !state.capabilities.isEmpty { rosterSection(state) }
                if state.can_grant { staffSection(state) }
                if state.capabilities.contains("fees") { Section { NavigationLink("회비 납부 / 취소", destination: NativeEventFeeView(occurrenceID: occurrenceID)) } }
                Section { Button("Google 최근 본인 확인") { Task { _ = await session.reauthenticateGoogle() } }; Button("최신 서버 자료 다시 불러오기 (미리보기 취소)") { perform { try await load() } } }
            } else if error.isEmpty { ProgressView("현장 운영 확인 중") }
        }
        .navigationTitle("행사 현장 운영")
        .disabled(busy)
        .task(id: identity) {
            clear(); visible = true
            guard let generation = identity else { return }
            do { try await load(); guard generation == identity else { return }; loadedIdentity = generation }
            catch { if generation == identity { self.error = error.localizedDescription } }
        }
        .onChange(of: session.consentRequired) { _, required in if required { clear() } }
        .onDisappear { visible = false; clear() }
    }
    private var surveySection: some View {
        Section("본인 참석·이동 설문") {
            Text("먼저 참석 응답을 저장하세요. 부분 참석 시간은 행사 시간 안으로 지정하세요.")
            Toggle("부분 참석", isOn: $partial)
            if partial { DatePicker("참석 시작", selection: $arrival); DatePicker("참석 종료", selection: $departure) }
            TextField("출발지 (상세 주소 불필요)", text: $survey.departure)
            Stepper("운전 지원 \(survey.driver_seats)석 (운전자 포함, 미지원 0)", value: $survey.driver_seats, in: 0...100)
            Button("설문 저장") { perform { try await saveSurvey() } }
        }
    }
    private var badgeSection: some View {
        Section("본인 QR 명찰") {
            Button("본인 QR 발급 / 갱신 (최대 5분)") { perform { try await issueBadge() } }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let badge, badgeExpiry > context.date { Image(uiImage: badge).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 280).accessibilityLabel("본인 행사 출석 QR"); Text("\(badgeExpiry.formatted()) 만료 · 공유하지 마세요.") }
                else if badge != nil { Text("명찰이 만료되었습니다. 다시 발급하세요.") }
            }
        }
    }
    private var logisticsSection: some View {
        Section("배정 미리보기 · revision \(draft?.revision ?? 0)") {
            Text("실제 회원 교회와 자가 설문만 사용합니다. 모든 변경은 확정 저장 전까지 미리보기입니다.")
            if let draft {
                NativeFieldResourcesEditor(title: "조", resources: Binding(get: { self.draft?.groups ?? [] }, set: { items in
                    self.draft?.groups = items
                    for i in self.draft?.assignments.indices ?? 0..<0 { if !items.contains(where: { $0.id == self.draft?.assignments[i].group_id }) { self.draft?.assignments[i].group_id = nil } }
                }), limit: 50)
                NativeFieldResourcesEditor(title: "숙소", resources: Binding(get: { self.draft?.rooms ?? [] }, set: { items in
                    self.draft?.rooms = items
                    for i in self.draft?.assignments.indices ?? 0..<0 { if !items.contains(where: { $0.id == self.draft?.assignments[i].room_id }) { self.draft?.assignments[i].room_id = nil } }
                }), limit: 100)
                ForEach(draft.vehicles.indices, id: \.self) { index in vehicleEditor(index) }
                Button("차량 추가") { self.draft?.vehicles.append(NativeFieldVehicle(id: UUID().uuidString, label: "새 차량", seat_count: 4)) }.disabled(draft.vehicles.count >= 50)
                ForEach(["group", "church", "room", "vehicle"], id: \.self) { kind in
                    Button(["group":"균등 순환 조", "church":"실제 교회별 조", "room":"숙소 순환", "vehicle":"좌석 기준 차량"][kind]! + " 배정 미리보기") {
                        if kind == "church", Set((state?.participants ?? []).compactMap(\.church_id)).count > 50 { error = "교회가 50개를 초과하여 자동 편성할 수 없습니다."; return }
                        self.draft?.automatic(kind, participants: state?.participants ?? []); notice = "미리보기입니다. 미배정과 정원을 확인한 뒤 저장하세요."
                    }
                }
                if let error = draft.capacityError { Text(error).foregroundStyle(.red) }
                Button("미리보기 확정 저장") { perform {
                    let generation = identity
                    let payload = try draft.payload(occurrenceID: occurrenceID)
                    let value = try await session.api.rpc("save_event_field_plan", body: payload)
                    guard generation == identity, visible else { return }
                    try accept(value); notice = "배정을 저장했습니다."
                } }.disabled(draft.capacityError != nil)
            }
        }
    }
    @ViewBuilder private func vehicleEditor(_ index: Int) -> some View {
        if let d = draft, d.vehicles.indices.contains(index) {
            let v = d.vehicles[index]
            TextField("차량 이름", text: Binding(get: { draft?.vehicles[index].label ?? "" }, set: { draft?.vehicles[index].label = $0 }))
            Stepper("좌석 \(v.seat_count) (운전자 포함)", value: Binding(get: { draft?.vehicles[index].seat_count ?? 1 }, set: { draft?.vehicles[index].seat_count = $0 }), in: 1...100)
            Picker("지원 운전자", selection: Binding(get: { draft?.vehicles[index].driver_user_id ?? "" }, set: { id in
                draft?.vehicles[index].driver_user_id = id.isEmpty ? nil : id
                if let target = draft?.assignments.firstIndex(where: { $0.user_id == id }) { draft?.assignments[target].vehicle_id = v.id }
            })) {
                Text("미지정").tag("")
                ForEach((state?.participants ?? []).filter { p in p.response == "yes" && (p.survey?.driver_seats ?? 0) >= v.seat_count && !d.vehicles.contains(where: { $0.id != v.id && $0.driver_user_id == p.user_id }) }) { p in Text(p.display_name).tag(p.user_id) }
            }
            Button("\(v.label) 삭제", role: .destructive) { draft?.vehicles.remove(at: index); for i in draft?.assignments.indices ?? 0..<0 { if draft?.assignments[i].vehicle_id == v.id { draft?.assignments[i].vehicle_id = nil } } }
        }
    }
    private func rosterSection(_ state: NativeFieldState) -> some View {
        Section("실제 응답 명단") {
            ForEach(state.participants) { participant in
                VStack(alignment: .leading, spacing: 8) {
                    Text(participant.display_name).font(.headline)
                    Text("\(participant.church_name ?? "교회 미확인") · \(participant.response) · \(participant.checked_at == nil ? "미출석" : "출석 완료")")
                    if let survey = participant.survey { Text("출발 \(survey.departure) · 지원 \(survey.driver_seats)석"); if let start = survey.attendance_start { Text("부분 참석 \(start) – \(survey.attendance_end ?? "")") } }
                    if state.capabilities.contains("logistics"), participant.response == "yes", let index = draft?.assignments.firstIndex(where: { $0.user_id == participant.id }) {
                        assignmentPicker("조", index: index, key: \.group_id, resources: draft?.groups ?? [])
                        assignmentPicker("숙소", index: index, key: \.room_id, resources: draft?.rooms ?? [])
                        assignmentPicker("차량", index: index, key: \.vehicle_id, resources: (draft?.vehicles ?? []).map { NativeFieldResource(id: $0.id, name: $0.label, capacity: $0.seat_count) }).disabled(draft?.vehicles.contains(where: { $0.driver_user_id == participant.id }) == true)
                    }
                }
            }
        }
    }
    private func assignmentPicker(_ title: String, index: Int, key: WritableKeyPath<NativeFieldAssignment, String?>, resources: [NativeFieldResource]) -> some View {
        Picker(title, selection: Binding(get: { draft?.assignments[index][keyPath: key] ?? "" }, set: { value in
            guard var next = draft else { return }; next.assignments[index][keyPath: key] = value.isEmpty ? nil : value
            if let problem = next.capacityError { error = problem } else { draft = next }
        })) { Text("미배정").tag(""); ForEach(resources) { Text($0.name).tag($0.id) } }
    }
    private func staffSection(_ state: NativeFieldState) -> some View {
        Section("회차 전용 만료 스태프") {
            Text("기본 역할이나 다른 행사·회원 승인 권한은 부여하지 않습니다. 최대 30일·종료 다음 날 이내 만료.")
            Picker("대상", selection: $staffUser) { Text("응답자 선택").tag(""); ForEach(state.participants) { Text($0.display_name).tag($0.id) } }
            ForEach(["logistics", "checkin", "export", "fees"], id: \.self) { cap in Toggle(cap, isOn: Binding(get: { staffCapabilities.contains(cap) }, set: { if $0 { staffCapabilities.insert(cap) } else { staffCapabilities.remove(cap) } })) }
            DatePicker("만료", selection: $staffExpiry)
            Button("스태프 부여 / 변경") { perform { try await staff(staffUser, capabilities: Array(staffCapabilities)) } }.disabled(staffUser.isEmpty || staffCapabilities.isEmpty)
            ForEach(state.staff) { member in
                Text("\(state.participants.first { $0.id == member.user_id }?.display_name ?? "회원") · \(member.capabilities.joined(separator: ", ")) · \(member.expires_at)")
                Button("권한 철회", role: .destructive) { perform { try await staff(member.user_id, capabilities: []) } }
            }
        }
    }
    @MainActor private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy, authorized else { return }; busy = true; error = ""; notice = ""
        let generation = identity
        Task { defer { if generation == identity { busy = false } }
            do { try await action() } catch {
                if visible && generation == identity {
                    if case NativeAPIError.response(let code) = error, code == 401 || code == 403 { clear() }
                    if case NativeAPIError.sessionExpired = error { clear() }
                    self.error = error.localizedDescription
                }
            }
        }
    }
    @MainActor private func accept(_ value: Any) throws {
        guard visible, session.signedIn, !session.consentRequired else { return }
        let next = try NativeFieldState.parse(value); state = next; draft = NativeFieldDraft(next)
        survey = next.survey ?? NativeFieldSurvey(); partial = survey.attendance_start != nil
        arrival = (survey.attendance_start ?? next.starts_at).flatMap(NativeEventDraft.parseDate) ?? Date()
        departure = (survey.attendance_end ?? next.ends_at).flatMap(NativeEventDraft.parseDate) ?? arrival.addingTimeInterval(3600)
    }
    @MainActor private func load() async throws {
        let generation = identity
        let value = try await session.api.rpc("get_event_field", body: ["p_occurrence_id": occurrenceID])
        guard generation == identity, visible else { return }; try accept(value)
    }
    @MainActor private func saveSurvey() async throws {
        let generation = identity
        let value = try await session.api.rpc("save_event_survey", body: ["p_occurrence_id": occurrenceID, "p_revision": survey.revision, "p_attendance_start": partial ? NativeCalendarDates.queryDate(arrival) as Any : NSNull(), "p_attendance_end": partial ? NativeCalendarDates.queryDate(departure) as Any : NSNull(), "p_departure": survey.departure, "p_driver_seats": survey.driver_seats])
        guard generation == identity, visible else { return }
        survey = try JSONDecoder().decode(NativeFieldSurvey.self, from: JSONSerialization.data(withJSONObject: value)); notice = "설문을 저장했습니다."
    }
    @MainActor private func issueBadge() async throws {
        let generation = identity
        guard let result = try await session.api.rpc("issue_event_badge", body: ["p_occurrence_id": occurrenceID]) as? [String: Any], let token = result["token"] as? String, let expiry = NativeEventDraft.parseDate(nativeText(result, "expires_at")) else { throw NativeAPIError.invalidData }
        guard generation == identity, visible else { return }
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(token.utf8); filter.correctionLevel = "M"
        guard let image = filter.outputImage, let cg = CIContext().createCGImage(image.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: image.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { throw NativeAPIError.invalidData }
        badge = UIImage(cgImage: cg); badgeExpiry = expiry
    }
    @MainActor private func verify(_ token: String) async throws {
        let generation = identity
        guard let result = try await session.api.rpc("verify_event_badge", body: ["p_occurrence_id": occurrenceID, "p_token": token]) as? [String: Any] else { throw NativeAPIError.invalidData }
        guard generation == identity, visible else { return }
        notice = "\(nativeText(result, "display_name")): \(nativeText(result, "checked_at")) 출석 확인"
        let refreshed = try await session.api.rpc("get_event_field", body: ["p_occurrence_id": occurrenceID])
        guard generation == identity, visible else { return }
        state = try NativeFieldState.parse(refreshed) // Preserve the allocation preview.
    }
    @MainActor private func staff(_ userID: String, capabilities: [String]) async throws {
        let generation = identity
        _ = try await session.api.rpc("set_event_staff", body: ["p_occurrence_id": occurrenceID, "p_user_id": userID, "p_capabilities": capabilities, "p_expires_at": NativeCalendarDates.queryDate(staffExpiry)])
        guard generation == identity, visible else { return }
        let refreshed = try await session.api.rpc("get_event_field", body: ["p_occurrence_id": occurrenceID])
        guard generation == identity, visible else { return }
        state = try NativeFieldState.parse(refreshed)
    }
    @MainActor private func exportRoster() async throws {
        let generation = identity
        let value = try await session.api.rpc("export_event_field", body: ["p_occurrence_id": occurrenceID])
        guard generation == identity, visible else { return }
        if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
        let data = try NativeFieldState.parse(value); exportURL = try NativeEventWorkbook.save(data)
    }
    private func clear() {
        if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
        partial = false; arrival = Date(); departure = Date(); staffExpiry = Date().addingTimeInterval(3600)
        state = nil; draft = nil; survey = NativeFieldSurvey(); badge = nil; badgeExpiry = .distantPast; scanning = false; exportURL = nil; staffUser = ""; staffCapabilities = ["checkin"]; loadedIdentity = nil; busy = false; error = ""; notice = ""
    }
}

private struct NativeFieldResourcesEditor: View {
    let title: String
    @Binding var resources: [NativeFieldResource]
    let limit: Int
    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            ForEach($resources) { $item in
                TextField("\(title) 이름", text: $item.name)
                Stepper("정원 \(item.capacity)", value: $item.capacity, in: 1...1000)
                Button("\(item.name) 삭제", role: .destructive) { resources.removeAll { $0.id == item.id } }
            }
            Button("\(title) 추가") { resources.append(NativeFieldResource(id: UUID().uuidString, name: "새 \(title)", capacity: 10)) }.disabled(resources.count >= limit)
        }
    }
}
