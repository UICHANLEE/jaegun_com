import SwiftUI

struct NativeGovernanceUnionView: View {
    @EnvironmentObject private var session: NativeSession
    let department: NativeGovernanceRecord
    let initialYear: Int
    @StateObject private var writer = NativeGovernanceWriter()
    @State private var current: NativeGovernanceRecord?
    @State private var year = 2000
    @State private var members: [NativeGovernanceRecord] = []
    @State private var offices: [NativeGovernanceRecord] = []
    @State private var delegations: [NativeGovernanceRecord] = []
    @State private var candidates: [NativeGovernanceRecord] = []
    @State private var memberID = ""
    @State private var candidateID = ""
    @State private var office = "president"
    @State private var search = ""
    @State private var offset = 0
    @State private var expires = Date()
    @State private var reason = ""
    @State private var name = ""
    @State private var error: String?
    @State private var loading = false
    private var allowed: Bool { session.signedIn && !session.consentRequired }
    private var canManage: Bool { current?.flag("can_manage") == true }
    private var canDelegate: Bool { current?.flag("can_delegate") == true }
    private var admin: Bool { session.context["is_platform_admin"] as? Bool == true }
    var body: some View {
        List {
            Section(current?.text("display_name") ?? department.text("display_name")) {
                Text("경계: \(current?.text("boundary_name") ?? department.text("boundary_name"))").font(.subheadline)
                Text("연합부서의 명시적 소속만 조회합니다. 부서 직책·위임은 기본 임원 역할이나 교회·노회·총회 운영 권한을 부여하지 않습니다.").font(.footnote)
                Stepper("\(String(year))년", value: $year, in: 2000...2100)
                Button("최신 현황 불러오기") { Task { await load() } }
            }
            if loading { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
            NativeGovernanceWriteStatus(writer: writer)
            Section("명시적 소속 회원") {
                ForEach(members) { member in HStack {
                    Text(member.text("display_name")); Spacer()
                    if canDelegate { Button("소속 해제", role: .destructive) { Task { await action("remove_member", payload: ["user_id": member.id]) } }.disabled(writer.working || writer.pending) }
                } }
                if members.isEmpty { Text("지정된 소속 회원이 없습니다.") }
            }
            if canDelegate {
                Section("경계 안의 회원 소속 지정") {
                    TextField("이름·교회 검색", text: $search)
                    Button("후보 조회") { offset = 0; Task { await loadCandidates() } }
                    Picker("추가할 회원", selection: $candidateID) { Text("선택").tag(""); ForEach(candidates) { Text("\($0.text("display_name")) · \($0.text("organization_name"))").tag($0.id) } }
                    HStack {
                        Button("이전 후보") { offset = max(0, offset - 30); Task { await loadCandidates() } }.disabled(offset == 0)
                        Button("다음 후보") { offset += 30; Task { await loadCandidates() } }.disabled(candidates.count < 30)
                    }
                    Button("소속 지정") { Task { await action("add_member", payload: ["user_id": candidateID]) } }.disabled(candidateID.isEmpty)
                }.disabled(writer.working || writer.pending || loading)
            }
            if canManage {
                Section("연도별 임원 임명") {
                    Picker("소속 회원", selection: $memberID) { Text("선택").tag(""); ForEach(members) { Text($0.text("display_name")).tag($0.id) } }
                    Picker("직책", selection: $office) { ForEach(NativeApprovalPolicy.officeLabels.keys.sorted(), id: \.self) { Text(NativeApprovalPolicy.officeLabels[$0] ?? $0).tag($0) } }
                    Button("임명") { Task { await action("assign_office", payload: ["user_id": memberID, "office_code": office, "service_year": year]) } }.disabled(memberID.isEmpty)
                    Button("선택 직책 공석 처리", role: .destructive) { Task { await action("clear_office", payload: ["office_code": office, "service_year": year]) } }
                }.disabled(writer.working || writer.pending || loading)
            }
            Section("\(String(year))년 임명·종료 이력") {
                ForEach(offices) { row in Text("\(row.text("display_name")) · \(NativeApprovalPolicy.officeLabels[row.text("office_code")] ?? row.text("office_code"))\n\(row.text("created_at").prefix(10)) ~ \(row.text("ended_at").isEmpty ? "재임" : String(row.text("ended_at").prefix(10)))") }
                if offices.isEmpty { Text("기록된 직책 이력이 없습니다.") }
            }
            if canDelegate {
                Section("부서 직책 관리 위임 · 회수") {
                    Text("현재 연도 부서 회장 또는 플랫폼 관리자가 같은 부서 회원에게 직책 관리만 위임합니다. 소속·회장 변경·재위임은 허용하지 않습니다. 최대 90일이며 현재 사역 연도 말에 종료됩니다.").font(.footnote)
                    Picker("위임받을 소속 회원", selection: $memberID) { Text("선택").tag(""); ForEach(members) { Text($0.text("display_name")).tag($0.id) } }
                    DatePicker("만료 시각", selection: $expires)
                    TextField("위임·회수 사유 (필수)", text: $reason, axis: .vertical)
                    Button("직책 관리 위임") { Task { await action("delegate", payload: ["user_id": memberID, "expires_at": ISO8601DateFormatter().string(from: expires), "reason": reason]) } }.disabled(memberID.isEmpty || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reason.count > 500)
                    ForEach(delegations) { row in VStack(alignment: .leading) {
                        Text(row.text("display_name")).font(.headline)
                        Text("\(row.text("expires_at")) · \(row.text("reason"))").font(.caption)
                        if row.text("revoked_at").isEmpty {
                            Button("위임 회수", role: .destructive) { Task { await action("revoke_delegation", payload: ["delegation_id": row.id, "reason": reason]) } }.disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reason.count > 500)
                        } else { Text("회수됨").font(.caption) }
                    } }
                }.disabled(writer.working || writer.pending || loading)
            }
            if admin {
                Section("부서 이름") { TextField("표시 이름", text: $name); Button("이름 저장") { Task { await action("rename", payload: ["display_name": name]) } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 120) }.disabled(writer.working || writer.pending || loading)
            }
            if canManage { NativeGovernanceAuthenticationControl() }
        }.navigationTitle("연합부서").nativePageStyle()
            .task(id: session.sessionGeneration) { clear(); year = initialYear; await load() }
            .onChange(of: writer.revision) { _, _ in Task { await load() } }
            .onChange(of: year) { _, _ in Task { await load() } }
            .onChange(of: session.consentRequired) { _, required in if required { clear() } }
            .onChange(of: session.signedIn) { _, signedIn in if !signedIn { clear() } }
    }
    private func clear() { current = nil; members = []; offices = []; delegations = []; candidates = []; memberID = ""; candidateID = ""; reason = ""; search = ""; name = ""; writer.reset() }
    private func load() async {
        guard allowed, !loading else { return }; let generation = session.sessionGeneration; let selectedYear = year
        loading = true; defer { loading = false }
        do {
            let list = try await session.api.rpc("get_union_departments") as? [[String: Any]] ?? []
            guard let row = list.first(where: { nativeText($0, "id") == department.id }) else { throw NativeAPIError.response(403) }
            let detail = try await session.api.rpc("get_union_department_detail", body: ["p_department_id": department.id, "p_service_year": selectedYear]) as? [String: Any] ?? [:]
            guard allowed, generation == session.sessionGeneration, year == selectedYear else { return }
            current = NativeGovernanceRecord(value: row); name = nativeText(row, "display_name")
            members = (detail["members"] as? [[String: Any]] ?? []).map { NativeGovernanceRecord(value: $0) }
            offices = (detail["offices"] as? [[String: Any]] ?? []).map { NativeGovernanceRecord(value: $0) }
            delegations = (detail["delegations"] as? [[String: Any]] ?? []).map { NativeGovernanceRecord(value: $0) }; error = nil
        } catch { if generation == session.sessionGeneration { current = nil; members = []; offices = []; delegations = []; self.error = "소속·권한이 바뀌었거나 연결할 수 없습니다. 다시 조회해 주세요." } }
    }
    private func loadCandidates() async {
        guard allowed else { return }; let generation = session.sessionGeneration
        do {
            let rows = try await session.api.rpc("list_union_department_candidates", body: ["p_department_id": department.id, "p_search": search, "p_offset": offset]) as? [[String: Any]] ?? []
            guard allowed, generation == session.sessionGeneration else { return }; candidates = rows.map { NativeGovernanceRecord(value: $0) }; candidateID = ""
        } catch { if generation == session.sessionGeneration { candidates = []; self.error = "소속 후보를 불러오지 못했습니다." } }
    }
    private func action(_ action: String, payload: [String: Any]) async {
        guard let current, let revision = current.value["revision"], allowed else { return }
        await writer.submit(session: session, name: "mutate_union_department", body: ["p_request_id": UUID().uuidString, "p_department_id": department.id, "p_expected_revision": revision, "p_action": action, "p_payload": payload])
    }
}
