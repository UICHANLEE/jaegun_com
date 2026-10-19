import SwiftUI

@MainActor final class NativeGovernanceWriter: ObservableObject {
    @Published var working = false
    @Published var error: String?
    @Published var pending = false
    @Published var revision = 0
    private var request: (String, [String: Any])?
    func reset() { request = nil; pending = false; error = nil; revision = 0 }
    func submit(session: NativeSession, name: String, body: [String: Any], retry: Bool = false) async {
        guard session.signedIn, !session.consentRequired, !working, (!pending || retry) else { return }
        let generation = session.sessionGeneration; working = true; defer { working = false }
        var submitted = false
        do {
            let proof = try await session.api.rpc("get_sensitive_action_auth_status") as? [String: Any] ?? [:]
            guard proof["verified"] as? Bool == true else { error = "변경 전에 Google로 본인 확인을 해 주세요."; return }
            guard generation == session.sessionGeneration, session.signedIn, !session.consentRequired else { return }
            if !retry { request = (name, body) }
            guard let request else { return }; pending = true; submitted = true
            _ = try await session.api.rpc(request.0, body: request.1)
            guard generation == session.sessionGeneration, session.signedIn, !session.consentRequired else { return }
            self.request = nil; pending = false; error = nil; revision += 1
        } catch {
            guard generation == session.sessionGeneration else { return }
            if case NativeAPIError.response(let status) = error, (400..<500).contains(status) {
                request = nil; pending = false
                self.error = "서버가 변경을 거절했습니다. 현재 권한·연도·만료·최신 revision을 다시 불러오세요."
            } else { self.error = submitted ? "응답을 확인하지 못했습니다. 같은 요청으로 결과를 확인해 주세요." : "본인 확인 상태를 확인하지 못했습니다." }
        }
    }
    func retry(session: NativeSession) async {
        guard let request else { return }; await submit(session: session, name: request.0, body: request.1, retry: true)
    }
}

struct NativeGovernanceWriteStatus: View {
    @EnvironmentObject private var session: NativeSession
    @ObservedObject var writer: NativeGovernanceWriter
    var body: some View {
        if writer.working { ProgressView("저장 결과 확인 중") }
        if let error = writer.error { Text(error).foregroundStyle(.red) }
        if writer.pending { Button("같은 요청으로 결과 확인") { Task { await writer.retry(session: session) } }.disabled(writer.working) }
        if writer.revision > 0 { Text("서버에서 저장 완료를 확인했습니다.").foregroundStyle(NativePalette.forest) }
    }
}

struct NativeGovernanceOrganizationEditor: View {
    @EnvironmentObject private var session: NativeSession
    let scopes: [NativeGovernanceRecord]
    var existing: NativeGovernanceRecord? = nil
    @StateObject private var writer = NativeGovernanceWriter()
    @State private var kind = "church"
    @State private var parent = ""
    @State private var name = ""
    @State private var slug = ""
    @State private var active = true
    @State private var scopeID = UUID().uuidString
    @State private var loaded = false
    var body: some View {
        Form {
            Section(existing == nil ? "조직 생성" : "이름·운영 상태 변경") {
                Text("총회 → 노회 → 교회 구조는 변경하지 않습니다. 조직 생성은 회원·목사·임원 임명과 별개입니다.").font(.footnote)
                if existing == nil {
                    Picker("종류", selection: $kind) { Text("노회").tag("presbytery"); Text("교회").tag("church") }
                    Picker("부모 조직", selection: $parent) {
                        Text("선택").tag("")
                        ForEach(scopes.filter { $0.flag("is_active") && $0.text("scope_type") == (kind == "church" ? "presbytery" : "general_assembly") }) { Text($0.text("display_name")).tag($0.id) }
                    }
                    TextField("영문 소문자·숫자 식별자", text: $slug).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                TextField("표시 이름", text: $name)
                if existing != nil { Toggle("운영 중", isOn: $active) }
                Button("조직 저장") { Task { await save() } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 120 || (existing == nil && (parent.isEmpty || slug.isEmpty)))
            }.disabled(writer.working || writer.pending || writer.revision > 0)
            NativeGovernanceWriteStatus(writer: writer)
            NativeGovernanceAuthenticationControl()
        }.navigationTitle(existing == nil ? "조직 생성" : "조직 관리").nativePageStyle()
            .task {
                guard !loaded else { return }; loaded = true
                if let existing { kind = existing.text("scope_type"); parent = existing.text("parent_scope_id"); name = existing.text("display_name"); slug = existing.text("slug"); active = existing.flag("is_active"); scopeID = existing.id }
            }
            .onChange(of: kind) { _, _ in if existing == nil { parent = "" } }
            .onChange(of: session.sessionGeneration) { _, _ in writer.reset(); name = ""; slug = ""; parent = "" }
            .onChange(of: session.consentRequired) { _, required in if required { writer.reset(); name = "" } }
    }
    private func save() async {
        await writer.submit(session: session, name: "save_governance_organization", body: [
            "p_request_id": UUID().uuidString, "p_scope_id": scopeID,
            "p_expected_updated_at": existing.map { $0.text("updated_at") as Any } ?? NSNull(),
            "p_scope_type": kind, "p_parent_scope_id": parent.isEmpty ? NSNull() : parent as Any,
            "p_slug": slug, "p_display_name": name, "p_is_active": active])
    }
}

struct NativeGovernanceUnionCreator: View {
    @EnvironmentObject private var session: NativeSession
    let scopes: [NativeGovernanceRecord]
    @StateObject private var writer = NativeGovernanceWriter()
    @State private var name = ""
    @State private var boundary = ""
    var body: some View {
        Form {
            Section("명시적 연합부서 범위") {
                Text("총회 또는 노회 안의 활동 회원만 별도로 소속 지정할 수 있습니다. 연합부서 소속·임원·위임은 기본 역할이나 다른 조직 권한을 부여하지 않습니다.").font(.footnote)
                TextField("부서 이름", text: $name)
                Picker("회원 자격 경계", selection: $boundary) {
                    Text("선택").tag("")
                    ForEach(scopes.filter { $0.flag("is_active") && ["general_assembly", "presbytery"].contains($0.text("scope_type")) }) { Text($0.text("display_name")).tag($0.id) }
                }
                Button("연합부서 생성") { Task {
                    await writer.submit(session: session, name: "mutate_union_department", body: ["p_request_id": UUID().uuidString, "p_department_id": UUID().uuidString, "p_expected_revision": NSNull(), "p_action": "create", "p_payload": ["display_name": name, "boundary_scope_id": boundary]])
                } }.disabled(boundary.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 120)
            }.disabled(writer.working || writer.pending || writer.revision > 0)
            NativeGovernanceWriteStatus(writer: writer)
            NativeGovernanceAuthenticationControl()
        }.navigationTitle("연합부서 생성").nativePageStyle()
            .onChange(of: session.sessionGeneration) { _, _ in writer.reset(); name = ""; boundary = "" }
            .onChange(of: session.consentRequired) { _, required in if required { writer.reset(); name = ""; boundary = "" } }
    }
}

struct NativeGovernanceDepartmentView: View {
    @EnvironmentObject private var session: NativeSession
    let scope: NativeGovernanceRecord
    let department: NativeGovernanceRecord
    let initialYear: Int
    @State private var year = 2000
    @State private var history: [NativeGovernanceRecord] = []
    @State private var candidates: [NativeGovernanceRecord] = []
    @State private var office = "president"
    @State private var user = ""
    @State private var search = ""
    @State private var offset = 0
    @State private var error: String?
    @State private var canManage = false
    @State private var working = false
    @State private var uncertain = false
    var body: some View {
        Form {
            Section(department.text("display_name")) {
                Text("부서 직책은 교회 임원 역할을 부여하지 않습니다. 현재 연도에 지정된 교회 담임목사 또는 플랫폼 관리자만 임명합니다.").font(.footnote)
                Stepper("\(String(year))년", value: $year, in: 2000...2100)
                Button("현황·이력 다시 불러오기") { Task { await load() } }
            }
            if let error { Text(error).foregroundStyle(.red) }
            if canManage {
                Section("담당자 지정") {
                    Picker("직책", selection: $office) { ForEach(NativeApprovalPolicy.officeLabels.keys.sorted(), id: \.self) { Text(NativeApprovalPolicy.officeLabels[$0] ?? $0).tag($0) } }
                    TextField("후보 검색", text: $search)
                    Button("후보 조회") { offset = 0; Task { await loadCandidates() } }
                    Picker("담당자", selection: $user) { Text("선택").tag(""); ForEach(candidates) { Text($0.text("display_name")).tag($0.id) } }
                    HStack { Button("이전 후보") { offset = max(0, offset - 30); Task { await loadCandidates() } }.disabled(offset == 0)
                        Button("다음 후보") { offset += 30; Task { await loadCandidates() } }.disabled(candidates.count < 30) }
                    Button("임명") { Task { await save(clear: false) } }.disabled(user.isEmpty)
                    Button("공석 처리", role: .destructive) { Task { await save(clear: true) } }
                }.disabled(working || uncertain)
                NativeGovernanceAuthenticationControl()
            }
            Section("임명·종료 이력") {
                ForEach(history) { row in Text("\(row.text("display_name")) · \(NativeApprovalPolicy.officeLabels[row.text("office_code")] ?? row.text("office_code"))\n\(row.text("created_at").prefix(10)) ~ \(row.text("ended_at").isEmpty ? "재임" : String(row.text("ended_at").prefix(10)))") }
            }
        }.navigationTitle("부서 직책").nativePageStyle()
            .task(id: session.sessionGeneration) { clear(); year = initialYear; await load() }
            .onChange(of: year) { _, _ in Task { await load() } }
            .onChange(of: session.consentRequired) { _, required in if required { clear() } }
    }
    private func clear() { history = []; candidates = []; user = ""; search = ""; canManage = false; uncertain = false }
    private func load() async {
        guard session.signedIn, !session.consentRequired else { return }; let generation = session.sessionGeneration; let selectedYear = year
        do {
            let entries = try await session.api.rpc("get_my_governance_access") as? [[String: Any]] ?? []
            let h = try await session.api.rpc("list_governance_office_history", body: ["p_scope_id": scope.id, "p_service_year": selectedYear, "p_department_id": department.id]) as? [[String: Any]] ?? []
            guard generation == session.sessionGeneration, !session.consentRequired, year == selectedYear else { return }
            history = h.map { NativeGovernanceRecord(value: $0) }
            canManage = NativeGovernancePolicy.canManageDepartment(entries, scopeID: scope.id, admin: session.context["is_platform_admin"] as? Bool == true)
            uncertain = false; error = nil
        } catch { if generation == session.sessionGeneration { history = []; self.error = "부서 직책 이력을 불러오지 못했습니다." } }
    }
    private func loadCandidates() async {
        guard session.signedIn, !session.consentRequired else { return }; let generation = session.sessionGeneration
        do {
            let rows = try await session.api.rpc("list_department_office_candidates", body: ["p_department_id": department.id, "p_service_year": year, "p_search": search, "p_limit": 30, "p_offset": offset]) as? [[String: Any]] ?? []
            guard generation == session.sessionGeneration, !session.consentRequired else { return }; candidates = rows.map { NativeGovernanceRecord(value: $0) }; user = ""
        } catch { if generation == session.sessionGeneration { candidates = []; self.error = "후보를 불러오지 못했습니다." } }
    }
    private func save(clear: Bool) async {
        guard session.signedIn, !session.consentRequired, !working, !uncertain else { return }; let generation = session.sessionGeneration
        working = true; defer { working = false }; var submitted = false
        do {
            let proof = try await session.api.rpc("get_sensitive_action_auth_status") as? [String: Any] ?? [:]
            guard proof["verified"] as? Bool == true else { error = "Google로 본인 확인을 해 주세요."; return }
            guard generation == session.sessionGeneration, !session.consentRequired else { return }
            let holder = history.first { $0.text("office_code") == office && $0.text("ended_at").isEmpty }
            let body: [String: Any] = ["p_request_id": UUID().uuidString, "p_scope_id": scope.id,
                "p_department_id": department.id, "p_service_year": year, "p_office_code": office,
                "p_user_id": clear ? NSNull() : user as Any,
                "p_expected_user_id": holder.map { $0.text("user_id") as Any } ?? NSNull()]
            submitted = true
            _ = try await session.api.rpc("mutate_governance_office", body: body)
            guard generation == session.sessionGeneration else { return }; await load()
        } catch { if generation == session.sessionGeneration { uncertain = submitted; self.error = "저장 결과를 확인하지 못했습니다. 현황·이력을 다시 조회한 뒤 변경을 확인하세요." } }
    }
}
