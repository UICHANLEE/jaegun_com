import SwiftUI

/// Supplementary UI policy only. The existing RLS and review RPC remain authoritative.
enum NativeApprovalPolicy {
    static let officeLabels = ["president": "회장", "vice_president": "부회장", "general_secretary": "총무", "secretary": "서기", "treasurer": "회계"]
    static func reviewable(_ application: [String: Any], context: [String: Any]) -> Bool {
        let profile = context["profile"] as? [String: Any] ?? [:]
        let membership = context["membership"] as? [String: Any] ?? [:]
        let role = nativeText(application, "requested_role")
        guard nativeText(application, "status") == "pending",
              !nativeText(profile, "id").isEmpty,
              nativeText(application, "user_id") != nativeText(profile, "id") else { return false }
        if context["is_platform_admin"] as? Bool == true && ["minister", "executive"].contains(role) { return true }
        return role == "member" && nativeText(membership, "status") == "active"
            && ["minister", "executive"].contains(nativeText(membership, "role"))
            && !nativeText(membership, "organization_id").isEmpty
            && nativeText(application, "organization_id") == nativeText(membership, "organization_id")
    }
    static func executiveIssue(_ application: [String: Any], year: Int?) -> String? {
        guard nativeText(application, "requested_role") == "executive" else { return nil }
        guard let year, let requested = application["requested_service_year"] as? Int,
              requested == year || requested == year + 1 else { return "신청 연도가 현재 또는 다음 사역 연도가 아닙니다. 반려 후 다시 신청하도록 안내해 주세요." }
        guard let offices = application["requested_executive_office_codes"] as? [String],
              !offices.isEmpty, Set(offices).count == offices.count,
              offices.allSatisfy({ officeLabels[$0] != nil }) else { return "유효한 임원 직책이 없습니다. 반려 후 직책을 선택하여 다시 신청하도록 안내해 주세요." }
        return nil
    }
    static func validReason(_ reason: String, rejecting: Bool) -> Bool {
        reason.count <= 2000 && (!rejecting || !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

struct NativeApprovalOperationsView: View {
    @EnvironmentObject private var session: NativeSession
    @State private var applications: [[String: Any]] = []
    @State private var names: [String: String] = [:]
    @State private var churches: [String: String] = [:]
    @State private var serviceYear: Int?
    @State private var loading = false
    @State private var working = false
    @State private var error: String?
    @State private var notice: String?
    @State private var selected: ApprovalSelection?
    @State private var reason = ""
    @State private var needsAuthentication = false
    @State private var uncertainID: String?
    @State private var filter = "all"
    private var actorID: String { nativeText(session.context["profile"] as? [String: Any] ?? [:], "id") }
    private var allowed: Bool { session.signedIn && !session.consentRequired && !actorID.isEmpty }
    private var visible: [[String: Any]] { applications.filter { filter == "all" || nativeText($0, "requested_role") == filter } }

    var body: some View {
        List {
            Section {
                Text("가입 승인").font(.title2.bold()).foregroundStyle(NativePalette.ink)
                NavigationLink("총회·노회·교회·부서 직책 신청") { NativeOfficeRequestReviewView() }
                NavigationLink("조직 트리·명단·임원·위임 관리") { NativeGovernanceView() }
                NavigationLink("일정·모임 운영") { NativeEventOperationsView() }
                Text("관리자는 사역자·임원을, 교회 사역자와 임원은 소속 교회 회원을 승인합니다.").font(.subheadline).foregroundStyle(NativePalette.muted)
                Picker("신청 역할", selection: $filter) {
                    Text("전체").tag("all"); Text("성도").tag("member")
                    Text("사역자").tag("minister"); Text("임원").tag("executive")
                }.pickerStyle(.segmented)
            }
            if let notice { Text(notice).foregroundStyle(NativePalette.forest).accessibilityAddTraits(.isStaticText) }
            if let error {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button(uncertainID == nil ? "다시 불러오기" : "처리 결과 확인") { Task { await reloadOrReconcile() } }
                        .frame(minHeight: 44).disabled(loading || working)
                }
            }
            if loading { ProgressView("신청을 확인하고 있습니다") }
            if !loading && error == nil && visible.isEmpty {
                ContentUnavailableView("확인할 신청이 없습니다", systemImage: "checkmark.circle", description: Text("권한 범위 안의 새 신청이 도착하면 표시됩니다."))
            }
            ForEach(visible, id: \.approvalIdentifier) { application in
                VStack(alignment: .leading, spacing: 10) {
                    Text(names[nativeText(application, "user_id")] ?? "가입 신청자").font(.headline)
                    Text(churches[nativeText(application, "organization_id")] ?? "신청 교회").font(.subheadline).foregroundStyle(NativePalette.muted)
                    Text(roleLabel(nativeText(application, "requested_role"))).font(.subheadline.weight(.semibold)).foregroundStyle(NativePalette.blue)
                    if let offices = application["requested_executive_office_codes"] as? [String], !offices.isEmpty {
                        Text(offices.compactMap { NativeApprovalPolicy.officeLabels[$0] }.joined(separator: " · ")).font(.subheadline)
                    }
                    if let year = application["requested_service_year"] as? Int { Text("\(String(year))년 임원 신청").font(.caption).foregroundStyle(NativePalette.muted) }
                    if !nativeText(application, "applicant_note").isEmpty { Text(nativeText(application, "applicant_note")).font(.subheadline).textSelection(.enabled) }
                    if let issue = NativeApprovalPolicy.executiveIssue(application, year: serviceYear) { Text(issue).font(.footnote).foregroundStyle(NativePalette.orange) }
                    HStack {
                        Button("반려", role: .destructive) { open(application, reject: true) }.buttonStyle(.bordered).frame(minHeight: 44)
                        Spacer()
                        Button("승인") { open(application, reject: false) }.buttonStyle(.borderedProminent).tint(NativePalette.solidGreen).frame(minHeight: 44)
                            .disabled(NativeApprovalPolicy.executiveIssue(application, year: serviceYear) != nil)
                    }.disabled(working || loading || uncertainID != nil || !allowed)
                }.padding(.vertical, 8)
            }
        }.listStyle(.plain).navigationTitle("가입 승인").nativePageStyle()
            .task { await load() }.refreshable { await reloadOrReconcile() }
            .sheet(item: $selected) { selection in
                NavigationStack {
                    Form {
                        Section("\(selection.reject ? "반려" : "승인") 확인") {
                            Text(names[nativeText(selection.application, "user_id")] ?? "가입 신청자").font(.headline)
                            Text("\(roleLabel(nativeText(selection.application, "requested_role"))) 신청을 \(selection.reject ? "반려" : "승인")합니다.")
                            TextField(selection.reject ? "반려 사유 (필수)" : "승인 메모 (선택)", text: $reason, axis: .vertical).lineLimit(3...7).disabled(working)
                            Text("\(reason.count)/2000").font(.caption).foregroundStyle(reason.count > 2000 ? .red : NativePalette.muted)
                        }
                        if needsAuthentication {
                            Section {
                                Text("사역자·임원 결정은 최근 5분 이내 Google 본인 확인이 필요합니다.")
                                Button("Google로 본인 확인") { Task { await authenticate() } }.frame(minHeight: 44).disabled(working)
                                Text("본인 확인 뒤에도 승인·반려 버튼을 직접 다시 눌러야 합니다.").font(.footnote).foregroundStyle(NativePalette.muted)
                            }
                        }
                        if let error { Text(error).foregroundStyle(.red) }
                        if uncertainID != nil {
                            Button("처리 결과 확인") { Task { await reconcile() } }.disabled(working)
                        }
                        Button(selection.reject ? "반려 확정" : "승인 확정", role: selection.reject ? .destructive : nil) {
                            Task { await submit(selection) }
                        }.frame(minHeight: 44).disabled(working || needsAuthentication || uncertainID != nil || !allowed || !NativeApprovalPolicy.validReason(reason, rejecting: selection.reject))
                    }.navigationTitle(selection.reject ? "반려 확인" : "승인 확인").nativePageStyle()
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { selected = nil }.disabled(working) } }
                }.interactiveDismissDisabled(working)
            }
            .onChange(of: actorID) { _, _ in clearPrivateState() }
            .onChange(of: session.sessionGeneration) { _, _ in clearPrivateState() }
            .onChange(of: session.consentRequired) { _, required in if required { clearPrivateState() } }
            .onChange(of: session.signedIn) { _, signedIn in if !signedIn { clearPrivateState() } }
    }

    private func open(_ application: [String: Any], reject: Bool) {
        guard allowed, !working, uncertainID == nil, NativeApprovalPolicy.reviewable(application, context: session.context) else { return }
        reason = ""; error = nil; needsAuthentication = false
        selected = ApprovalSelection(application: application, reject: reject)
    }
    private func load() async {
        guard !loading, allowed else { return }
        let actor = actorID
        loading = true; defer { loading = false }
        do {
            let clock = try await session.api.rpc("get_service_clock") as? [String: Any]
            let rows = try await session.api.rows("membership_applications", query: "select=id,organization_id,user_id,requested_role,requested_executive_office_codes,requested_service_year,status,applicant_note,created_at&status=eq.pending&order=created_at.desc&limit=200")
            let reviewable = rows.filter { NativeApprovalPolicy.reviewable($0, context: session.context) }
            let ids = Array(Set(reviewable.compactMap { $0["user_id"] as? String }))
            let profiles = ids.isEmpty ? [] : try await session.api.rpc("list_visible_profiles", body: ["p_profile_ids": ids]) as? [[String: Any]] ?? []
            let organizations = try await session.api.rows("public_organization_directory", query: "select=id,display_name&order=display_name&limit=200")
            guard allowed, actor == actorID else { return }
            serviceYear = clock?["service_year"] as? Int
            applications = reviewable
            names = profiles.reduce(into: [:]) { $0[nativeText($1, "id")] = nativeText($1, "display_name", fallback: "가입 신청자") }
            churches = organizations.reduce(into: [:]) { $0[nativeText($1, "id")] = nativeText($1, "display_name") }
            if uncertainID == nil { error = nil }
        } catch {
            guard actor == actorID else { return }
            applications = []; names = [:]; churches = [:]
            self.error = "신청을 불러오지 못했습니다. 현재 동의·권한·네트워크를 확인해 주세요."
        }
    }
    private func reloadOrReconcile() async {
        if uncertainID != nil { await reconcile() } else if !working { await load() }
    }
    private func authenticate() async {
        guard !working, allowed else { return }
        working = true; defer { working = false }
        let actor = actorID
        let success = await session.reauthenticateGoogle()
        guard actor == actorID, allowed else { clearPrivateState(); return }
        if success { needsAuthentication = false; error = nil; notice = "본인 확인이 완료되었습니다. 결정을 직접 확인해 주세요." }
        else { error = session.error ?? "본인 확인을 완료하지 못했습니다." }
    }
    private func submit(_ selection: ApprovalSelection) async {
        guard !working, allowed, uncertainID == nil, !needsAuthentication,
              NativeApprovalPolicy.reviewable(selection.application, context: session.context),
              NativeApprovalPolicy.validReason(reason, rejecting: selection.reject) else { return }
        working = true; defer { working = false }
        let actor = actorID
        let id = selection.id
        var submitted = false
        do {
            // Check live status before any mutation; never replay a completed review.
            let current = try await session.api.rows("membership_applications", query: "select=id,status&id=eq.\(id)")
            guard let row = current.first, nativeText(row, "status") == "pending" else {
                selected = nil; notice = "이미 처리되었거나 조회 권한이 변경된 신청입니다."; await load(); return
            }
            if nativeText(selection.application, "requested_role") != "member" {
                let status = try await session.api.rpc("get_sensitive_action_auth_status") as? [String: Any]
                guard status?["verified"] as? Bool == true else { needsAuthentication = true; error = nil; return }
            }
            guard allowed, actor == actorID else { return }
            if !selection.reject {
                let clock = try await session.api.rpc("get_service_clock") as? [String: Any]
                if let issue = NativeApprovalPolicy.executiveIssue(selection.application, year: clock?["service_year"] as? Int) {
                    error = issue; return
                }
            }
            submitted = true
            let reasonValue: Any = reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSNull() : reason as Any
            _ = try await session.api.rpc("review_membership_application", body: ["p_application_id": id, "p_decision": selection.reject ? "reject" : "approve", "p_reason": reasonValue])
            guard actor == actorID, allowed else { return }
            selected = nil; notice = selection.reject ? "신청을 반려했습니다." : "가입을 승인했습니다."; error = nil
            await load()
        } catch {
            guard actor == actorID, allowed else { return }
            if submitted {
                uncertainID = id
                self.error = "처리 결과를 확인하지 못했습니다. 중복 요청 전에 ‘처리 결과 확인’을 눌러 주세요."
            } else { self.error = "권한 또는 연결 상태를 확인하지 못했습니다. 다시 확인한 뒤 결정해 주세요." }
        }
    }
    private func reconcile() async {
        guard !working, let id = uncertainID, allowed else { return }
        working = true; defer { working = false }
        let actor = actorID
        do {
            let rows = try await session.api.rows("membership_applications", query: "select=id,status&id=eq.\(id)")
            guard actor == actorID, allowed else { return }
            guard let row = rows.first else {
                error = "현재 권한으로 처리 결과를 조회할 수 없습니다. 결정을 다시 전송하지 말고 관리자에게 확인해 주세요."; return
            }
            let status = nativeText(row, "status")
            guard ["pending", "approved", "rejected"].contains(status) else { throw NativeAPIError.invalidData }
            uncertainID = nil; error = nil
            if status == "pending" { notice = "아직 대기 중입니다. 내용을 확인한 뒤 결정을 직접 다시 눌러 주세요." }
            else { selected = nil; notice = status == "approved" ? "서버에서 승인 완료를 확인했습니다." : "서버에서 반려 완료를 확인했습니다." }
            await load()
        } catch { if actor == actorID { self.error = "처리 결과 확인에 실패했습니다. 중복 전송하지 않고 다시 조회해 주세요." } }
    }
    private func clearPrivateState() {
        applications = []; names = [:]; churches = [:]; selected = nil; reason = ""
        serviceYear = nil; notice = nil; error = nil; uncertainID = nil; needsAuthentication = false
    }
    private func roleLabel(_ role: String) -> String {
        ["member": "일반 성도", "minister": "사역자", "executive": "임원"][role] ?? "가입 신청"
    }
}

private struct ApprovalSelection: Identifiable {
    let application: [String: Any]
    let reject: Bool
    var id: String { nativeText(application, "id") }
}

private extension Dictionary where Key == String, Value == Any {
    var approvalIdentifier: String { self["id"] as? String ?? "" }
}
