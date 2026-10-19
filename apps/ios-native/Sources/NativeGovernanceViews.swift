import SwiftUI

enum NativeGovernancePolicy {
    static func access(_ entries: [[String: Any]], scopeID: String) -> [String: Any] {
        entries.filter {
            nativeText($0, "scope_id") == scopeID
                && ["general_assembly", "presbytery", "church"].contains(nativeText($0, "scope_type"))
        }.reduce(into: [String: Any]()) { result, entry in
            for key in ["can_manage_officers", "can_manage_delegations", "can_view_roster"] {
                result[key] = (result[key] as? Bool == true) || (entry[key] as? Bool == true)
            }
        }
    }
    static func canManageDepartment(_ entries: [[String: Any]], scopeID: String, admin: Bool) -> Bool {
        admin || entries.contains {
            nativeText($0, "scope_id") == scopeID && nativeText($0, "scope_type") == "church"
                && ["office", "church_pastor"].contains(nativeText($0, "authority_source"))
                && ($0["office_codes"] as? [String] ?? []).contains("pastor")
                && $0["can_manage_officers"] as? Bool == true
        }
    }
}

struct NativeGovernanceRecord: Identifiable {
    let value: [String: Any]
    var id: String { nativeText(value, "id", fallback: nativeText(value, "scope_id", fallback: nativeText(value, "user_id", fallback: nativeText(value, "delegation_id")))) }
    func text(_ key: String) -> String { nativeText(value, key) }
    func flag(_ key: String) -> Bool { value[key] as? Bool == true }
}

/// Separate union records never enter the hierarchy access or base-role model.
struct NativeGovernanceView: View {
    @EnvironmentObject private var session: NativeSession
    @State private var scopes: [NativeGovernanceRecord] = []
    @State private var tree: [NativeGovernanceRecord] = []
    @State private var unions: [NativeGovernanceRecord] = []
    @State private var year = 2000
    @State private var error: String?
    @State private var loading = false
    private var allowed: Bool { session.signedIn && !session.consentRequired }
    private var admin: Bool { session.context["is_platform_admin"] as? Bool == true }
    var body: some View {
        List {
            Section {
                Text("조직과 회원·직책 권한은 별개입니다. 상위·하위 조직이나 부서 직책으로 다른 범위의 운영 권한을 얻지 않습니다.").font(.footnote)
                Text("조회에는 추가 인증이 필요하지 않습니다. 변경 시에만 최근 Google 본인 확인이 필요합니다.").font(.footnote)
            }
            if let error { Section { Text(error).foregroundStyle(.red); Button("다시 불러오기") { Task { await load() } } } }
            if loading { ProgressView() }
            Section("총회 → 노회 → 교회 조직 트리") {
                ForEach(tree) { row in
                    VStack(alignment: .leading) {
                        Text(row.text("display_name")).font(.headline)
                        Text(scopeLabel(row.text("scope_type"))).font(.caption)
                        if let parent = tree.first(where: { $0.id == row.text("parent_scope_id") }) {
                            Text("소속: \(parent.text("display_name"))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("정확한 권한 범위 · 명단과 연도별 관리") {
                ForEach(scopes) { scope in
                    NavigationLink(scope.text("display_name")) { NativeGovernanceScopeView(scope: scope, initialYear: year) }
                }
                if scopes.isEmpty && !loading { Text("현재 명단 열람·직책 관리 권한이 있는 범위가 없습니다.") }
            }
            Section("연합부서 · 명시적 소속") {
                ForEach(unions) { department in
                    NavigationLink(department.text("display_name")) { NativeGovernanceUnionView(department: department, initialYear: year) }
                }
                if unions.isEmpty { Text("명시적으로 소속된 연합부서가 없습니다.") }
            }
            if admin {
                Section("관리자 조직 관리") {
                    NavigationLink("노회·교회 생성") { NativeGovernanceOrganizationEditor(scopes: scopes) }
                    NavigationLink("연합부서 생성") { NativeGovernanceUnionCreator(scopes: scopes) }
                    ForEach(scopes) { scope in
                        NavigationLink("\(scope.text("display_name")) 이름·운영 상태") { NativeGovernanceOrganizationEditor(scopes: scopes, existing: scope) }
                    }
                }
            }
        }.navigationTitle("조직·직책·위임").nativePageStyle()
            .task(id: session.sessionGeneration) { clear(); await load() }
            .refreshable { await load() }
            .onChange(of: session.consentRequired) { _, required in if required { clear() } }
            .onChange(of: session.signedIn) { _, signedIn in if !signedIn { clear() } }
    }
    private func clear() { scopes = []; tree = []; unions = []; error = nil }
    private func load() async {
        guard allowed, !loading else { return }
        let generation = session.sessionGeneration; loading = true; defer { loading = false }
        do {
            let clock = try await session.api.rpc("get_service_clock") as? [String: Any] ?? [:]
            guard let serviceYear = clock["service_year"] as? Int, (2000...2100).contains(serviceYear) else { throw NativeAPIError.invalidData }
            let s = try await session.api.rpc("get_governance_management_scopes") as? [[String: Any]] ?? []
            let t = try await session.api.rpc("get_governance_tree") as? [[String: Any]] ?? []
            let u = try await session.api.rpc("get_union_departments") as? [[String: Any]] ?? []
            guard allowed, generation == session.sessionGeneration else { return }
            year = serviceYear
            scopes = s.map { NativeGovernanceRecord(value: $0) }; tree = t.map { NativeGovernanceRecord(value: $0) }
            unions = u.map { NativeGovernanceRecord(value: $0) }; error = nil
        } catch { if generation == session.sessionGeneration { clear(); self.error = "조직을 불러오지 못했습니다. 현재 동의와 조직 권한을 확인해 주세요." } }
    }
    private func scopeLabel(_ value: String) -> String { ["general_assembly": "총회", "presbytery": "노회", "church": "교회"][value] ?? "조직" }
}

struct NativeGovernanceAuthenticationControl: View {
    @EnvironmentObject private var session: NativeSession
    @State private var working = false
    @State private var message: String?
    var body: some View {
        Section("변경 전 본인 확인") {
            Text("조회는 추가 인증 없이 가능합니다. 저장·임명·회수는 서버의 최근 5분 이내 Google 인증으로 확인합니다.").font(.footnote)
            Button("Google로 본인 확인") { Task {
                guard !working else { return }; working = true; defer { working = false }
                let generation = session.sessionGeneration
                let success = await session.reauthenticateGoogle()
                guard generation == session.sessionGeneration else { return }
                message = success ? "본인 확인을 마쳤습니다. 변경 버튼을 직접 눌러 주세요." : "본인 확인을 완료하지 못했습니다."
            } }.disabled(working)
            if let message { Text(message).font(.footnote) }
        }
    }
}

struct NativeGovernanceScopeView: View {
    @EnvironmentObject private var session: NativeSession
    let scope: NativeGovernanceRecord
    let initialYear: Int
    @State private var year = 2000
    @State private var roster: [NativeGovernanceRecord] = []
    @State private var history: [NativeGovernanceRecord] = []
    @State private var access: [String: Any] = [:]
    @State private var delegations: [NativeGovernanceRecord] = []
    @State private var departments: [NativeGovernanceRecord] = []
    @State private var candidates: [NativeGovernanceRecord] = []
    @State private var search = ""
    @State private var offset = 0
    @State private var candidateOffset = 0
    @State private var candidateSearch = ""
    @State private var office = "president"
    @State private var user = ""
    @State private var reason = ""
    @State private var expires = Date()
    @State private var manageOfficers = true
    @State private var viewRoster = false
    @State private var error: String?
    @State private var loading = false
    @State private var working = false
    @State private var uncertain = false
    private var allowed: Bool { session.signedIn && !session.consentRequired }
    private var admin: Bool { session.context["is_platform_admin"] as? Bool == true }
    private var canManage: Bool { admin || access["can_manage_officers"] as? Bool == true }
    private var canDelegate: Bool { admin || access["can_manage_delegations"] as? Bool == true }
    private var offices: [String] { ["pastor", "president", "vice_president", "general_secretary", "secretary", "treasurer"] }
    var body: some View {
        List {
            Section(scope.text("display_name")) {
                Stepper("\(String(year))년", value: $year, in: 2000...2100)
                Text("직책은 선택한 조직·연도에만 적용됩니다. 목사 직책도 명시적으로 임명합니다.").font(.footnote)
            }
            if let error { Section { Text(error).foregroundStyle(.red); Button(uncertain ? "저장 결과 다시 조회" : "다시 조회") { Task { await load() } } } }
            if loading { ProgressView() }
            Section("범위 안의 명단") {
                TextField("이름·교회 검색", text: $search)
                Button("검색") { offset = 0; Task { await load() } }
                ForEach(roster) { member in VStack(alignment: .leading) {
                    Text(member.text("display_name")).font(.headline)
                    Text("\(member.text("organization_name")) · \(member.text("membership_role"))").font(.caption)
                    Text((member.value["office_codes"] as? [String] ?? []).map(label).joined(separator: " · ")).font(.caption)
                } }
                HStack {
                    Button("이전") { offset = max(0, offset - 30); Task { await load() } }.disabled(offset == 0 || loading)
                    Button("다음") { offset += 30; Task { await load() } }.disabled(roster.count < 30 || loading)
                }
            }
            if canManage {
                Section("연도별 직책 지정") {
                    Picker("직책", selection: $office) { ForEach(offices, id: \.self) { Text(label($0)).tag($0) } }
                    TextField("임명 후보 검색", text: $candidateSearch)
                    Button("후보 조회") { candidateOffset = 0; Task { await loadCandidates() } }
                    Picker("담당자", selection: $user) {
                        Text("선택").tag("")
                        ForEach(candidates) { member in Text("\(member.text("display_name")) · \(member.text("organization_name"))").tag(member.id) }
                    }
                    HStack {
                        Button("이전 후보") { candidateOffset = max(0, candidateOffset - 30); Task { await loadCandidates() } }.disabled(candidateOffset == 0)
                        Button("다음 후보") { candidateOffset += 30; Task { await loadCandidates() } }.disabled(candidates.count < 30)
                    }
                    Button("직책 임명") { Task { await mutate("assign_governance_office", body: ["p_scope_id": scope.id, "p_service_year": year, "p_office_code": office, "p_user_id": user]) } }.disabled(user.isEmpty)
                    Button("선택 직책 공석 처리", role: .destructive) { Task { await mutate("clear_governance_office", body: ["p_scope_id": scope.id, "p_service_year": year, "p_office_code": office]) } }
                }.disabled(working || loading || uncertain)
            }
            Section("\(String(year))년 임명·종료 이력") {
                ForEach(history) { row in Text("\(row.text("display_name")) · \(label(row.text("office_code")))\n\(row.text("created_at").prefix(10)) ~ \(row.text("ended_at").isEmpty ? "재임" : String(row.text("ended_at").prefix(10)))") }
                if history.isEmpty { Text("기록된 직책 이력이 없습니다.") }
            }
            if scope.text("scope_type") == "church" && !scope.text("organization_id").isEmpty {
                Section("교회 고정 부서 · 별도 권한") {
                    ForEach(departments) { department in
                        NavigationLink(department.text("display_name")) { NativeGovernanceDepartmentView(scope: scope, department: department, initialYear: year) }
                    }
                }
            }
            if canDelegate {
                Section("같은 범위의 제한 위임") {
                    Text("위임은 다시 위임할 수 없으며 최대 90일·현재 사역 연도 말까지만 유효합니다.").font(.footnote)
                    TextField("위임받을 회원 이름", text: $candidateSearch)
                    Button("위임 후보 조회") { Task { await loadDelegateCandidates() } }
                    Picker("위임받을 회원", selection: $user) { Text("선택").tag(""); ForEach(candidates) { Text($0.text("display_name")).tag($0.id) } }
                    Toggle("직책 관리", isOn: $manageOfficers); Toggle("명단 열람", isOn: $viewRoster)
                    DatePicker("위임 만료", selection: $expires)
                    TextField("위임·회수 사유 (필수)", text: $reason, axis: .vertical)
                    Button("권한 위임") { Task { await mutate("grant_governance_delegation", body: ["p_scope_id": scope.id, "p_delegate_user_id": user, "p_capabilities": (manageOfficers ? ["manage_officers"] : []) + (viewRoster ? ["view_roster"] : []), "p_expires_at": ISO8601DateFormatter().string(from: expires), "p_reason": reason]) } }.disabled(user.isEmpty || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!manageOfficers && !viewRoster))
                    ForEach(delegations) { d in VStack(alignment: .leading) {
                        Text("\(d.text("delegate_name")) · \(d.text("status"))").font(.headline)
                        Text("\(d.text("expires_at")) · \(d.text("reason"))").font(.caption)
                        if d.text("revoked_at").isEmpty {
                            Button("사유를 기록하고 위임 회수", role: .destructive) { Task { await mutate("revoke_governance_delegation", body: ["p_delegation_id": d.id, "p_reason": reason]) } }.disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    } }
                }.disabled(working || loading || uncertain)
            }
            if canManage || canDelegate { NativeGovernanceAuthenticationControl() }
        }.navigationTitle(scope.text("display_name")).nativePageStyle()
            .task(id: session.sessionGeneration) { clear(); year = initialYear; await load() }
            .onChange(of: year) { _, _ in Task { await load() } }
            .onChange(of: office) { _, _ in candidates = []; user = "" }
            .onChange(of: session.consentRequired) { _, required in if required { clear() } }
            .onChange(of: session.signedIn) { _, signedIn in if !signedIn { clear() } }
    }
    private func label(_ code: String) -> String { code == "pastor" ? "목사" : NativeApprovalPolicy.officeLabels[code] ?? code }
    private func clear() { roster = []; history = []; candidates = []; delegations = []; departments = []; user = ""; reason = ""; access = [:]; error = nil; uncertain = false }
    private func load() async {
        guard allowed, !loading else { return }; let generation = session.sessionGeneration; let selectedYear = year
        loading = true; defer { loading = false }
        do {
            let entries = try await session.api.rpc("get_my_governance_access") as? [[String: Any]] ?? []
            let a = NativeGovernancePolicy.access(entries, scopeID: scope.id)
            let r = try await session.api.rpc("list_governance_roster", body: ["p_scope_id": scope.id, "p_service_year": selectedYear, "p_search": search, "p_limit": 30, "p_offset": offset]) as? [[String: Any]] ?? []
            let h = try await session.api.rpc("list_governance_office_history", body: ["p_scope_id": scope.id, "p_service_year": selectedYear]) as? [[String: Any]] ?? []
            let d = admin || a["can_manage_delegations"] as? Bool == true ? try await session.api.rpc("list_governance_delegations", body: ["p_scope_id": scope.id]) as? [[String: Any]] ?? [] : []
            let dep = scope.text("scope_type") == "church" ? try await session.api.rpc("list_church_departments", body: ["p_organization_id": scope.text("organization_id"), "p_service_year": selectedYear]) as? [[String: Any]] ?? [] : []
            guard allowed, generation == session.sessionGeneration, selectedYear == year else { return }
            access = a; roster = r.map { NativeGovernanceRecord(value: $0) }; history = h.map { NativeGovernanceRecord(value: $0) }; delegations = d.map { NativeGovernanceRecord(value: $0) }
            var seen = Set<String>(); departments = dep.compactMap { row in
                let id = nativeText(row, "department_id"); guard seen.insert(id).inserted else { return nil }
                var value = row; value["id"] = id; return NativeGovernanceRecord(value: value)
            }
            uncertain = false; error = nil
        } catch { if generation == session.sessionGeneration { roster = []; history = []; departments = []; delegations = []; self.error = "명단·직책을 불러오지 못했습니다. 현재 범위의 권한을 다시 확인해 주세요." } }
    }
    private func loadCandidates() async {
        guard allowed else { return }; let generation = session.sessionGeneration; let selectedOffice = office; let selectedYear = year
        do {
            let rows = try await session.api.rpc("list_governance_office_candidates", body: ["p_scope_id": scope.id, "p_service_year": selectedYear, "p_office_code": selectedOffice, "p_search": candidateSearch, "p_limit": 30, "p_offset": candidateOffset]) as? [[String: Any]] ?? []
            guard allowed, generation == session.sessionGeneration, year == selectedYear, office == selectedOffice else { return }
            candidates = rows.map { NativeGovernanceRecord(value: $0) }; user = ""
        } catch { if generation == session.sessionGeneration { candidates = []; self.error = "임명 후보를 불러오지 못했습니다." } }
    }
    private func loadDelegateCandidates() async {
        guard allowed else { return }; let generation = session.sessionGeneration
        do {
            let rows = try await session.api.rpc("list_governance_roster", body: ["p_scope_id": scope.id, "p_service_year": year, "p_search": candidateSearch, "p_limit": 30, "p_offset": candidateOffset]) as? [[String: Any]] ?? []
            guard allowed, generation == session.sessionGeneration else { return }; candidates = rows.map { NativeGovernanceRecord(value: $0) }; user = ""
        } catch { if generation == session.sessionGeneration { self.error = "위임 후보를 불러오지 못했습니다." } }
    }
    private func mutate(_ name: String, body: [String: Any]) async {
        guard allowed, !working, !uncertain else { return }; let generation = session.sessionGeneration
        working = true; defer { working = false }; var submitted = false
        do {
            let proof = try await session.api.rpc("get_sensitive_action_auth_status") as? [String: Any] ?? [:]
            guard proof["verified"] as? Bool == true else { error = "변경 전에 Google로 본인 확인을 해 주세요."; return }
            guard generation == session.sessionGeneration, allowed else { return }; submitted = true
            if name == "assign_governance_office" || name == "clear_governance_office" {
                let code = body["p_office_code"] as? String ?? ""
                let holder = history.first { $0.text("office_code") == code && $0.text("ended_at").isEmpty }
                var checked = body
                checked["p_request_id"] = UUID().uuidString; checked["p_department_id"] = NSNull()
                checked["p_expected_user_id"] = holder.map { $0.text("user_id") as Any } ?? NSNull()
                if name == "clear_governance_office" { checked["p_user_id"] = NSNull() }
                _ = try await session.api.rpc("mutate_governance_office", body: checked)
            } else { _ = try await session.api.rpc(name, body: body) }
            guard generation == session.sessionGeneration, allowed else { return }; await load()
        } catch { if generation == session.sessionGeneration { uncertain = submitted; self.error = submitted ? "응답을 확인하지 못했습니다. 저장 결과를 조회한 뒤 내용을 확인하세요. 자동 재전송하지 않습니다." : "본인 확인 상태를 조회하지 못했습니다." } }
    }
}
