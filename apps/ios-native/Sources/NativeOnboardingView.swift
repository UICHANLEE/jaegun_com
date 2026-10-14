import SwiftUI

/// Organization labels are public discovery only. This view requests membership;
/// it never creates an active membership or trusts profile metadata for authority.
struct NativeOnboardingView: View {
    @EnvironmentObject private var session: NativeSession
    @State private var organizations: [[String: Any]] = []
    @State private var presbytery = ""
    @State private var churchID = ""
    @State private var name = ""
    @State private var role = "member"
    @State private var note = ""
    @State private var offices: Set<String> = []
    @State private var serviceYear: Int?
    @State private var selectedYear = 0
    @State private var loading = true
    @State private var submitting = false
    @State private var submitted = false
    @State private var error: String?
    @State private var officeRequests: [NativeScopedOfficeChoice] = []
    @State private var clientRequestID = UUID().uuidString
    @State private var uncertainSubmission = false
    private let officeOptions = [("president", "회장"), ("vice_president", "부회장"), ("general_secretary", "총무"), ("secretary", "서기"), ("treasurer", "회계")]
    private var application: [String: Any] {
        (session.context["latest_application"] ?? session.context["pending_application"]) as? [String: Any] ?? [:]
    }
    private var pending: Bool { submitted || nativeText(application, "status") == "pending" }
    private var presbyteries: [String] {
        Array(Set(organizations.compactMap { $0["presbytery"] as? String }.filter { !$0.isEmpty })).sorted()
    }
    private var churches: [[String: Any]] {
        organizations.filter { nativeText($0, "presbytery") == presbytery }
    }
    private var canSubmit: Bool {
        !loading && !submitting && !uncertainSubmission && officeRequests.count <= 36 && !session.consentRequired && session.signedIn &&
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 80 &&
        !presbytery.isEmpty && churches.contains(where: { nativeText($0, "id") == churchID }) &&
        note.count <= 2000 && (role != "executive" || (!offices.isEmpty && serviceYear != nil && [serviceYear!, serviceYear! + 1].contains(selectedYear)))
    }
    var body: some View {
        NavigationStack {
            Form {
                if pending { pendingSections }
                else {
                    Section {
                        NativeBrandHeader().padding(.vertical, 8)
                        Text("가입 설정 · 소속과 역할 확인").font(.caption.weight(.semibold)).foregroundStyle(NativePalette.orange)
                        Text("어느 공동체와 함께하시나요?").font(.title2.bold())
                        Text("소속 교회와 역할을 선택하면 담당자의 확인 후 모든 기능을 이용할 수 있어요.").font(.subheadline).foregroundStyle(NativePalette.muted)
                    }
                    Group {
                    Section("본인 이름") {
                        TextField("교회에서 사용하는 이름", text: $name).textContentType(.name)
                        Text("Google 계정 이름 대신 소속 확인에 사용할 이름을 직접 입력해 주세요.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("1 · 소속 노회와 교회") {
                        if loading { ProgressView("교회 목록을 불러오고 있습니다") }
                        Picker("노회", selection: $presbytery) {
                            Text("노회 선택").tag("")
                            ForEach(presbyteries, id: \.self) { Text($0).tag($0) }
                        }.onChange(of: presbytery) { _, _ in churchID = "" }
                        Picker("교회", selection: $churchID) {
                            Text("교회 선택").tag("")
                            ForEach(churches.indices, id: \.self) { index in
                                Text(nativeText(churches[index], "display_name")).tag(nativeText(churches[index], "id"))
                            }
                        }.disabled(presbytery.isEmpty)
                        Text("선택한 소속은 가입 승인 전까지 권한을 부여하지 않습니다.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("2 · 신청할 역할") {
                        ForEach([("member", "회원", "교회 소식과 나눔에 참여해요.", "person.2"), ("executive", "임원", "회원 가입과 공동체 운영을 도와요.", "person.badge.shield.checkmark"), ("minister", "사역자", "교회 공동체와 회원을 관리해요.", "building.2")], id: \.0) { code, title, detail, icon in
                            Button { role = code } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: icon).foregroundStyle(NativePalette.blue).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(NativePalette.ink)
                                        Text(detail).font(.caption).foregroundStyle(NativePalette.muted)
                                    }
                                    Spacer()
                                    Image(systemName: role == code ? "checkmark.circle.fill" : "circle").foregroundStyle(role == code ? NativePalette.blue : NativePalette.muted)
                                }.frame(minHeight: 52)
                            }.buttonStyle(.plain).accessibilityAddTraits(role == code ? .isSelected : [])
                        }
                        Text(role == "member" ? "소속 교회의 사역자 또는 임원이 승인합니다." : "사역자·임원 신청은 플랫폼 관리자의 승인이 필요합니다.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if role == "executive" {
                        Section("임원 직책과 연도") {
                            if let serviceYear {
                                Picker("활동 연도", selection: $selectedYear) {
                                    Text("\(serviceYear)년").tag(serviceYear)
                                    Text("\(serviceYear + 1)년").tag(serviceYear + 1)
                                }
                            } else {
                                Text("서버 기준 활동 연도를 확인하지 못했습니다. 다시 불러온 뒤 신청해 주세요.").foregroundStyle(.red)
                            }
                            ForEach(officeOptions, id: \.0) { code, label in
                                Toggle(label, isOn: Binding(get: { offices.contains(code) }, set: {
                                    if $0 { offices.insert(code) } else { offices.remove(code) }
                                }))
                            }
                            Text("직책은 선택한 교회·연도 범위의 신청 정보이며, 승인 전에는 임원 권한이 없습니다.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    NativeSignupOfficeRequestsView(organizationID: churchID, requests: $officeRequests)
                    Section("신청 메모 · 선택") {
                        TextField("소속 확인에 필요한 내용을 적어 주세요", text: $note, axis: .vertical).lineLimit(3...8)
                        Text("\(note.count)/2000자").font(.caption).foregroundStyle(.secondary)
                    }
                    }.disabled(uncertainSubmission)
                    Section {
                        Button("가입 승인 요청") { Task { await submit() } }.frame(minHeight: 44).disabled(!canSubmit)
                        if submitting { ProgressView("가입 신청을 저장하고 있습니다") }
                        if let error { Text(error).foregroundStyle(.red) }
                        if uncertainSubmission {
                            Button("가입 신청 결과 확인") { Task { await reconcileSubmission() } }.disabled(submitting)
                            Text("결과를 확인하기 전에는 내용을 바꾸거나 다시 제출하지 않습니다.").font(.caption).foregroundStyle(NativePalette.muted)
                        }
                        Button("교회 목록 다시 불러오기") { Task { await load() } }.disabled(submitting || uncertainSubmission)
                    }
                }
                Section {
                    Button("로그아웃", role: .destructive) { Task { await session.signOut() } }.disabled(submitting).frame(minHeight: 44)
                }
            }.disabled(submitting).navigationTitle(pending ? "승인 대기" : "교회 가입 신청").nativePageStyle()
                .task { if !pending { await load() } }
        }
    }
    @ViewBuilder private var pendingSections: some View {
        Section {
            Label("가입 승인을 기다리고 있습니다", systemImage: "clock")
            Text("승인이 완료되면 교회 소식과 채널에 들어갈 수 있습니다. 중복 가입 신청은 허용되지 않습니다.")
            if !nativeText(application, "review_reason").isEmpty { Text(nativeText(application, "review_reason")) }
            Button("가입 상태 다시 확인") {
                Task { await session.restore(); if !session.loading && nativeText(application, "status") != "pending" { submitted = false } }
            }.frame(minHeight: 44)
            if let error = session.error { Text(error).foregroundStyle(.red) }
        }
    }
    private func clockYear() async throws -> Int {
        let value = try await session.api.rpc("get_service_clock")
        let row = (value as? [String: Any]) ?? (value as? [[String: Any]])?.first
        guard let year = row?["service_year"] as? Int, year > 2000 && year < 2100 else { throw NativeAPIError.invalidData }
        return year
    }
    private func load() async {
        loading = true; error = nil
        do {
            organizations = try await session.api.rows("public_organization_directory", query: "select=id,slug,display_name,presbytery,status&order=display_name")
                .filter { ["active", "seeded_unclaimed"].contains(nativeText($0, "status")) }
            if name.isEmpty { name = nativeText(session.context["profile"] as? [String: Any] ?? [:], "display_name") }
            do {
                let year = try await clockYear()
                serviceYear = year
                if selectedYear != year && selectedYear != year + 1 { selectedYear = year }
            } catch { serviceYear = nil }
            if !churches.contains(where: { nativeText($0, "id") == churchID }) { churchID = "" }
        } catch { organizations = []; self.error = "교회 목록을 불러오지 못했습니다. 네트워크 연결을 확인해 주세요." }
        loading = false
    }
    private func submit() async {
        guard canSubmit else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            error = "이름에 줄바꿈이나 제어 문자를 넣을 수 없습니다."; return
        }
        submitting = true; error = nil
        defer { submitting = false }
        var attempted = false
        do {
            if role == "executive" {
                let year = try await clockYear()
                guard selectedYear == year || selectedYear == year + 1 else {
                    serviceYear = year; selectedYear = year
                    throw NativeAPIError.security("활동 연도가 변경되었습니다. 연도를 확인하고 다시 신청해 주세요.")
                }
            }
            _ = try await session.api.rpc("update_my_display_name", body: ["p_display_name": cleanName])
            attempted = true
            _ = try await session.api.rpc("submit_membership_with_office_requests", body: [
                "p_organization_id": churchID, "p_requested_role": role,
                "p_client_request_id": clientRequestID,
                "p_applicant_note": note.isEmpty ? NSNull() : note,
                "p_requested_church_title_code": NSNull(),
                "p_requested_executive_office_codes": role == "executive" ? Array(offices).sorted() : [],
                "p_requested_service_year": role == "executive" ? selectedYear : NSNull(),
                "p_office_requests": officeRequests.sorted { $0.id < $1.id }.map(\.payload)
            ])
            submitted = true
            await session.restore()
        } catch {
            uncertainSubmission = attempted
            self.error = "신청을 완료하지 못했습니다. 가입 상태를 다시 확인한 뒤 재시도해 주세요. 이름 변경만 저장되었을 수 있습니다."
        }
    }
    private func reconcileSubmission() async {
        guard !submitting else { return }
        submitting = true
        await session.restore()
        if session.error == nil, session.signedIn, !session.consentRequired {
            submitted = nativeText(application, "status") == "pending"
            uncertainSubmission = false
            if !submitted { clientRequestID = UUID().uuidString }
            error = nil
        }
        submitting = false
    }
}
