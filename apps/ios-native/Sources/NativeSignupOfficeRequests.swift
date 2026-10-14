import SwiftUI

/// Applicant-controlled metadata only; never a membership or authority claim.
struct NativeScopedOfficeChoice: Equatable, Identifiable {
    let scopeID: String
    let departmentID: String?
    let serviceYear: Int
    let officeCode: String
    var id: String { "\(scopeID.lowercased())|\(departmentID?.lowercased() ?? "")|\(serviceYear)|\(officeCode)" }
    var payload: [String: Any] {
        var value: [String: Any] = ["scope_id": scopeID, "service_year": serviceYear, "office_code": officeCode]
        if let departmentID { value["department_id"] = departmentID }
        return value
    }
}

private struct NativeOfficeScopeOption: Identifiable {
    let id: String
    let scopeID: String
    let departmentID: String?
    let label: String
    let codes: [String]
}

struct NativeSignupOfficeRequestsView: View {
    let organizationID: String
    @Binding var requests: [NativeScopedOfficeChoice]
    @EnvironmentObject private var session: NativeSession
    @State private var options: [NativeOfficeScopeOption] = []
    @State private var years: [Int] = []
    @State private var selectedYear = 0
    @State private var loading = false
    @State private var error: String?
    @State private var loadedChurch = ""
    @State private var loadedActor = ""
    @State private var generation = UUID()
    private var actorID: String { nativeText(session.context["profile"] as? [String: Any] ?? [:], "id") }
    private var allowed: Bool { session.signedIn && !session.consentRequired && !actorID.isEmpty }
    private var taskIdentity: String { "\(organizationID)|\(actorID)|\(allowed)" }
    private let labels = ["president": "회장", "vice_president": "부회장", "general_secretary": "총무", "secretary": "서기", "treasurer": "회계", "pastor": "목사"]

    var body: some View {
        Section("직책 신청 · 선택") {
            Text("총회·노회·교회·부서 직책은 가입 승인과 별도로 확인합니다. 선택만으로 권한이 생기지 않습니다.")
                .font(.footnote).foregroundStyle(NativePalette.muted)
            if organizationID.isEmpty { Text("소속 교회를 먼저 선택해 주세요.").foregroundStyle(NativePalette.muted) }
            if loading { ProgressView("소속별 직책을 확인하고 있습니다") }
            if let error {
                Text(error).foregroundStyle(.red)
                Button("직책 목록 다시 불러오기") { Task { await load() } }.frame(minHeight: 44).disabled(loading)
            }
            if !options.isEmpty {
                Picker("직책 활동 연도", selection: $selectedYear) {
                    ForEach(years, id: \.self) { Text("\(String($0))년").tag($0) }
                }.disabled(loading)
                ForEach(options) { option in
                    DisclosureGroup(option.label) {
                        ForEach(option.codes, id: \.self) { code in
                            let choice = NativeScopedOfficeChoice(scopeID: option.scopeID, departmentID: option.departmentID,
                                serviceYear: selectedYear, officeCode: code)
                            Toggle(labels[code] ?? code, isOn: Binding(
                                get: { requests.contains(where: { $0.id == choice.id }) },
                                set: { value in
                                    guard !loading, allowed, years.contains(selectedYear) else { return }
                                    if value && !requests.contains(where: { $0.id == choice.id }) && requests.count < 36 { requests.append(choice) }
                                    if !value { requests.removeAll { $0.id == choice.id } }
                                }
                            )).disabled(loading || (!requests.contains(where: { $0.id == choice.id }) && requests.count >= 36))
                                .frame(minHeight: 44)
                        }
                    }.frame(minHeight: 44)
                }
                Text("선택한 직책 \(requests.count)개 · 현재/다음 연도의 신청은 각각 저장됩니다.")
                    .font(.caption).foregroundStyle(NativePalette.muted)
                Text("회원·사역자·임원 역할은 별도로 승인됩니다. 총회·노회 직책 승인은 기존 사역자·임원 자격을 확인하며, 부서 직책은 가입 승인·회계·임원 관리 권한을 주지 않습니다.")
                    .font(.footnote).foregroundStyle(NativePalette.muted)
            }
        }.task(id: taskIdentity) { await load() }
    }

    @MainActor private func load() async {
        let church = organizationID
        let actor = actorID
        let ticket = UUID(); generation = ticket
        if loadedChurch != church || loadedActor != actor { requests = []; loadedChurch = church; loadedActor = actor }
        options = []; years = []; error = nil
        guard allowed, UUID(uuidString: church) != nil else { requests = []; loading = false; return }
        loading = true
        defer { if generation == ticket { loading = false } }
        do {
            guard let result = try await session.api.rpc("list_signup_office_options", body: ["p_organization_id": church]) as? [String: Any],
                  let year = result["service_year"] as? Int, let next = result["next_service_year"] as? Int,
                  (2000...2099).contains(year), next == year + 1,
                  let scopes = result["scopes"] as? [[String: Any]], scopes.count == 3,
                  let departments = result["departments"] as? [[String: Any]], departments.count == 4,
                  let codes = result["office_codes"] as? [String], Set(codes) == Set(labels.keys), codes.count == 6,
                  let departmentCodes = result["department_office_codes"] as? [String],
                  Set(departmentCodes) == Set(labels.keys.filter { $0 != "pastor" }), departmentCodes.count == 5
            else { throw NativeAPIError.invalidData }
            let types = scopes.map { nativeText($0, "scope_type") }
            guard Set(types) == Set(["general_assembly", "presbytery", "church"]),
                  Set(scopes.map { nativeText($0, "id") }).count == 3,
                  let churchScope = scopes.first(where: { nativeText($0, "scope_type") == "church" }) else { throw NativeAPIError.invalidData }
            let churchScopeID = nativeText(churchScope, "id")
            let fixedCodes = Set(["adult", "young_adult", "teen", "elementary"])
            guard Set(departments.map { nativeText($0, "department_code") }) == fixedCodes,
                  Set(departments.map { nativeText($0, "id") }).count == 4 else { throw NativeAPIError.invalidData }
            var parsed: [NativeOfficeScopeOption] = []
            for scope in scopes {
                let id = nativeText(scope, "id"), label = nativeText(scope, "display_name")
                guard UUID(uuidString: id) != nil, !label.isEmpty else { throw NativeAPIError.invalidData }
                parsed.append(NativeOfficeScopeOption(id: id, scopeID: id, departmentID: nil, label: label, codes: codes))
            }
            for department in departments {
                let id = nativeText(department, "id"), label = nativeText(department, "display_name")
                guard UUID(uuidString: id) != nil, nativeText(department, "scope_id") == churchScopeID,
                      !label.isEmpty else { throw NativeAPIError.invalidData }
                parsed.append(NativeOfficeScopeOption(id: id, scopeID: churchScopeID, departmentID: id, label: "부서 · \(label)", codes: departmentCodes))
            }
            guard !Task.isCancelled, generation == ticket, actorID == actor, organizationID == church, allowed else { return }
            options = parsed; years = [year, next]
            if !years.contains(selectedYear) { selectedYear = year }
            var identifiers = Set<String>()
            requests = requests.filter { choice in
                years.contains(choice.serviceYear) && parsed.contains(where: {
                    $0.scopeID == choice.scopeID && $0.departmentID == choice.departmentID && $0.codes.contains(choice.officeCode)
                }) && identifiers.insert(choice.id).inserted
            }.prefix(36).map { $0 }
        } catch {
            guard !Task.isCancelled, generation == ticket, actorID == actor, organizationID == church, allowed else { return }
            requests = []; self.error = "직책 목록을 확인하지 못했습니다. 소속·동의·연결 상태를 확인한 뒤 다시 불러와 주세요."
        }
    }
}

private struct NativeOfficeDecision: Identifiable {
    let row: [String: Any]
    let rejecting: Bool
    var id: String { nativeText(row, "id") }
}

struct NativeOfficeRequestReviewView: View {
    @EnvironmentObject private var session: NativeSession
    @State private var rows: [[String: Any]] = []
    @State private var names: [String: String] = [:]
    @State private var loading = false
    @State private var working = false
    @State private var error: String?
    @State private var notice: String?
    @State private var decision: NativeOfficeDecision?
    @State private var reason = ""
    @State private var needsAuthentication = false
    @State private var uncertain: NativeOfficeDecision?
    @State private var generation = UUID()
    @State private var offset = 0
    @State private var hasNextPage = false
    private var actorID: String { nativeText(session.context["profile"] as? [String: Any] ?? [:], "id") }
    private var allowed: Bool { session.signedIn && !session.consentRequired && !actorID.isEmpty }
    private var taskIdentity: String { "\(actorID)|\(allowed)" }
    private let labels = ["president":"회장","vice_president":"부회장","general_secretary":"총무","secretary":"서기","treasurer":"회계","pastor":"목사"]
    var body: some View {
        List {
            Section {
                Text("직책 신청 확인").font(.title2.bold())
                Text("가입 승인과 별도로 총회·노회·교회·부서 범위에서 확인합니다. 본인 확인 후에도 결정을 직접 확정해야 합니다.")
                    .font(.footnote).foregroundStyle(NativePalette.muted)
            }
            if let notice { Text(notice).foregroundStyle(NativePalette.forest) }
            if let error { Text(error).foregroundStyle(.red) }
            if loading { ProgressView("직책 신청을 확인하고 있습니다") }
            if !loading && rows.isEmpty && error == nil {
                ContentUnavailableView("확인할 직책 신청이 없습니다", systemImage: "person.badge.shield.checkmark")
            }
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                VStack(alignment: .leading, spacing: 9) {
                    Text(names[nativeText(row,"user_id")] ?? "직책 신청자").font(.headline)
                    Text(nativeText(row,"scope_name") + (nativeText(row,"department_name").isEmpty ? "" : " · " + nativeText(row,"department_name")))
                        .font(.subheadline).foregroundStyle(NativePalette.muted)
                    Text("\(row["service_year"] as? Int ?? 0)년 · \(labels[nativeText(row,"office_code")] ?? "직책")").font(.subheadline.weight(.semibold))
                    if nativeText(row,"membership_status") != "approved" {
                        Text("가입 승인 후 직책을 승인할 수 있습니다.").font(.caption).foregroundStyle(NativePalette.muted)
                    }
                    HStack {
                        Button("반려", role: .destructive) { open(row, rejecting: true) }.buttonStyle(.bordered).frame(minHeight: 44)
                        Spacer()
                        Button("승인") { open(row, rejecting: false) }.buttonStyle(.borderedProminent).tint(NativePalette.solidGreen).frame(minHeight: 44)
                            .disabled(nativeText(row,"membership_status") != "approved")
                    }.disabled(working || loading || uncertain != nil || !allowed || row["can_review"] as? Bool != true)
                }.padding(.vertical,8)
            }
            Button(uncertain == nil ? "다시 불러오기" : "처리 결과 확인") { Task { if uncertain != nil { await reconcile() } else { await load() } } }
                .frame(minHeight:44).disabled(loading || working)
            HStack {
                Button("이전 신청") { offset = max(0,offset-100); Task { await load() } }.disabled(offset == 0)
                Spacer()
                Text("\(offset/100+1)페이지").font(.caption).foregroundStyle(NativePalette.muted)
                Spacer()
                Button("다음 신청") { offset += 100; Task { await load() } }.disabled(!hasNextPage || offset >= 10000)
            }.frame(minHeight:44).disabled(loading || working || uncertain != nil)
        }.listStyle(.plain).navigationTitle("직책 신청").nativePageStyle()
            .task(id:taskIdentity) { clear(); if allowed { await load() } }
            .refreshable { if uncertain != nil { await reconcile() } else { await load() } }
            .sheet(item:$decision) { selection in
                NavigationStack {
                    Form {
                        Section(selection.rejecting ? "반려 확인" : "승인 확인") {
                            Text(nativeText(selection.row,"scope_name"))
                            Text(labels[nativeText(selection.row,"office_code")] ?? "직책")
                            Text("승인 시 이 범위와 연도의 직책만 임명합니다. 가입 역할은 변경하지 않습니다.").font(.footnote).foregroundStyle(NativePalette.muted)
                            TextField(selection.rejecting ? "반려 사유 (필수)" : "승인 메모 (선택)",text:$reason,axis:.vertical).lineLimit(3...7)
                            Text("\(reason.count)/2000자").font(.caption).foregroundStyle(reason.count > 2000 ? .red : NativePalette.muted)
                        }
                        if needsAuthentication {
                            Section {
                                Text("최근 Google 본인 확인이 필요합니다.")
                                Button("Google로 본인 확인") { Task { await authenticate() } }.frame(minHeight:44).disabled(working)
                                Text("확인 후 승인·반려를 직접 다시 눌러 주세요.").font(.caption)
                            }
                        }
                        if let error { Text(error).foregroundStyle(.red) }
                        if uncertain != nil { Button("처리 결과 확인") { Task { await reconcile() } }.disabled(working) }
                        Button(selection.rejecting ? "반려 확정" : "승인 확정",role:selection.rejecting ? .destructive : nil) { Task { await submit(selection) } }
                            .frame(minHeight:44).disabled(working || uncertain != nil || needsAuthentication || !allowed || !validReason(selection))
                    }.navigationTitle("직책 결정").nativePageStyle()
                        .toolbar { ToolbarItem(placement:.cancellationAction) { Button("닫기") { decision = nil }.disabled(working) } }
                }.interactiveDismissDisabled(working)
            }
    }
    private func validReason(_ selection: NativeOfficeDecision) -> Bool {
        reason.count <= 2000 && (!selection.rejecting || !reason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
    }
    private func open(_ row: [String:Any], rejecting:Bool) {
        guard allowed, !working, uncertain == nil, row["can_review"] as? Bool == true,
              nativeText(row,"status") == "pending", UUID(uuidString:nativeText(row,"id")) != nil,
              rejecting || nativeText(row,"membership_status") == "approved" else { return }
        reason = ""; error = nil; needsAuthentication = false
        decision = NativeOfficeDecision(row:row,rejecting:rejecting)
    }
    @MainActor private func load() async {
        guard allowed, !loading else { return }
        let actor = actorID, ticket = generation
        loading = true; defer { if generation == ticket { loading = false } }
        do {
            guard let result = try await session.api.rpc("list_membership_office_requests",body:["p_limit":100,"p_offset":offset]) as? [[String:Any]] else { throw NativeAPIError.invalidData }
            let visible = result.filter { nativeText($0,"status") == "pending" && $0["can_review"] as? Bool == true }
            let ids = Array(Set(visible.map { nativeText($0,"user_id") }.filter { UUID(uuidString:$0) != nil }))
            let profiles = ids.isEmpty ? [] : try await session.api.rpc("list_visible_profiles",body:["p_profile_ids":ids]) as? [[String:Any]] ?? []
            guard !Task.isCancelled, generation == ticket, actorID == actor, allowed else { return }
            rows = visible; hasNextPage = result.count == 100
            names = profiles.reduce(into:[:]) { $0[nativeText($1,"id")] = nativeText($1,"display_name",fallback:"직책 신청자") }
            if uncertain == nil { error = nil }
        } catch {
            guard !Task.isCancelled, generation == ticket, actorID == actor, allowed else { return }
            rows = []; names = [:]; self.error = "직책 신청을 확인하지 못했습니다. 현재 동의·권한·연결 상태를 확인해 주세요."
        }
    }
    @MainActor private func authenticate() async {
        guard allowed, !working else { return }
        let actor = actorID; working = true; defer { working = false }
        let verified = await session.reauthenticateGoogle()
        guard actorID == actor, allowed else { clear(); return }
        if verified { needsAuthentication = false; error = nil; notice = "본인 확인을 마쳤습니다. 결정을 직접 다시 확인해 주세요." }
        else { error = session.error ?? "본인 확인을 완료하지 못했습니다." }
    }
    @MainActor private func submit(_ selection:NativeOfficeDecision) async {
        guard allowed, !working, uncertain == nil, !needsAuthentication, validReason(selection) else { return }
        let actor = actorID; working = true; defer { working = false }
        var attempted = false
        do {
            let result = try await fetch(application:nativeText(selection.row,"application_id"))
            guard let current = result.first(where:{ nativeText($0,"id") == selection.id }),
                  current["can_review"] as? Bool == true, nativeText(current,"status") == "pending",
                  selection.rejecting || nativeText(current,"membership_status") == "approved" else {
                decision = nil; notice = "이미 처리되었거나 현재 승인할 수 없는 신청입니다."; await load(); return
            }
            let proof = try await session.api.rpc("get_sensitive_action_auth_status") as? [String:Any]
            guard actorID == actor, allowed else { return }
            guard proof?["verified"] as? Bool == true else { needsAuthentication = true; return }
            attempted = true
            let memo:Any = reason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? NSNull() : reason
            _ = try await session.api.rpc("review_membership_office_request",body:["p_request_id":selection.id,"p_decision":selection.rejecting ? "reject" : "approve","p_reason":memo])
            guard actorID == actor, allowed else { return }
            decision = nil; error = nil; notice = selection.rejecting ? "직책 신청을 반려했습니다." : "직책 신청을 승인했습니다."
            await load()
        } catch {
            guard actorID == actor, allowed else { return }
            if attempted { uncertain = selection; self.error = "결과를 확인하지 못했습니다. 중복 전송 전에 처리 결과를 조회해 주세요." }
            else { self.error = "신청·권한·본인 확인 상태를 확인하지 못했습니다. 다시 확인해 주세요." }
        }
    }
    @MainActor private func fetch(application:String) async throws -> [[String:Any]] {
        guard UUID(uuidString:application) != nil,
              let result = try await session.api.rpc("list_membership_office_requests",body:["p_application_id":application,"p_limit":100,"p_offset":0]) as? [[String:Any]] else { throw NativeAPIError.invalidData }
        return result
    }
    @MainActor private func reconcile() async {
        guard allowed, !working, let uncertain else { return }
        let actor = actorID; working = true; defer { working = false }
        do {
            let result = try await fetch(application:nativeText(uncertain.row,"application_id"))
            guard actorID == actor, allowed else { return }
            guard let row = result.first(where:{ nativeText($0,"id") == uncertain.id }), row["can_review"] as? Bool == true else {
                error = "현재 권한으로 결과를 조회할 수 없습니다. 결정을 다시 전송하지 말고 담당자에게 확인해 주세요."; return
            }
            let status = nativeText(row,"status")
            guard ["pending","approved","rejected","withdrawn"].contains(status) else { throw NativeAPIError.invalidData }
            self.uncertain = nil; error = nil
            if status == "pending" { notice = "아직 대기 중입니다. 내용을 다시 확인한 뒤 결정을 직접 눌러 주세요." }
            else { decision = nil; notice = "서버에서 처리 완료를 확인했습니다." }
            await load()
        } catch { if actorID == actor, allowed { self.error = "처리 결과 확인에 실패했습니다. 중복 전송하지 않고 다시 조회해 주세요." } }
    }
    private func clear() {
        generation = UUID(); rows = []; names = [:]; decision = nil; uncertain = nil
        reason = ""; error = nil; notice = nil; needsAuthentication = false; loading = false
        offset = 0; hasNextPage = false
    }
}
