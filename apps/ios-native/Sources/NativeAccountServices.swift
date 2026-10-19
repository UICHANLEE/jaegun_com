import SwiftUI

/// Self-service state remains available before renewed consent; it never grants community access.
@MainActor final class NativeAccountServices: ObservableObject {
    @Published var snapshot: [String: Any] = [:]
    @Published var visibility: [String: Bool] = [:]
    @Published var categories: [String: Bool] = [:]
    @Published var pushEnabled = false
    @Published var quietEnabled = false
    @Published var quietStart = "22:00"
    @Published var quietEnd = "07:00"
    @Published var preview = "generic"
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    private var generation: UUID?
    private var requestID: UUID?
    static let visibilityLabels = [("avatar", "프로필 사진"), ("church_title", "교회 직책"), ("email", "이메일"), ("bio", "소개")]
    static let categoryLabels = [("approvals", "가입 승인"), ("posts", "게시글"), ("comments", "댓글"), ("chats", "대화"), ("governance", "조직·직책"), ("events", "일정")]
    var deletion: [String: Any] { snapshot["account_deletion"] as? [String: Any] ?? [:] }
    var blocks: [[String: Any]] { snapshot["blocked_profiles"] as? [[String: Any]] ?? [] }
    func clear() { generation = nil; requestID = nil; snapshot = [:]; visibility = [:]; categories = [:]; busy = false; error = nil; notice = nil }
    private func current(_ session: NativeSession, _ epoch: UUID, _ request: UUID) -> Bool {
        session.signedIn && session.sessionGeneration == epoch && requestID == request && !Task.isCancelled
    }
    func load(_ session: NativeSession) async {
        guard session.signedIn, !busy else { return }
        let epoch = session.sessionGeneration, request = UUID()
        if generation != epoch { clear() }
        generation = epoch; requestID = request; busy = true; error = nil
        defer { if requestID == request { busy = false; requestID = nil } }
        do {
            guard let value = try await session.api.rpc("get_my_safety_privacy_state") as? [String: Any] else { throw NativeAPIError.invalidData }
            guard current(session, epoch, request) else { return }
            snapshot = value
            visibility = value["directory_visibility"] as? [String: Bool] ?? [:]
            let notifications = value["notifications"] as? [String: Any] ?? [:]
            categories = notifications["categories"] as? [String: Bool] ?? [:]
            pushEnabled = notifications["push_enabled"] as? Bool == true
            quietEnabled = notifications["quiet_hours_enabled"] as? Bool == true
            quietStart = nativeText(notifications, "quiet_hours_start", fallback: "22:00")
            quietEnd = nativeText(notifications, "quiet_hours_end", fallback: "07:00")
            preview = nativeText(notifications, "lock_screen_preview", fallback: "generic")
        } catch {
            guard current(session, epoch, request) else { return }
            snapshot = [:]; self.error = error.localizedDescription
        }
    }
    func mutate(_ session: NativeSession, rpc: String, body: [String: Any]) async {
        await perform(session) { _ = try await session.api.rpc(rpc, body: body) }
    }
    func saveVisibility(_ session: NativeSession) async {
        guard !session.consentRequired, snapshot["consent_gate_open"] as? Bool == true,
              let documents = snapshot["current_documents"] as? [String: [String: Any]], documents.count == 5 else { error = "현재 필수 동의를 먼저 확인해 주세요."; return }
        var versions: [String: String] = [:]
        for (key, document) in documents { versions[key] = nativeText(document, "version") }
        await mutate(session, rpc: "save_my_privacy_preferences_v2", body: ["p_required_consents": versions,
            "p_avatar_visible": visibility["avatar"] == true, "p_church_title_visible": visibility["church_title"] == true,
            "p_email_visible": visibility["email"] == true, "p_bio_visible": visibility["bio"] == true])
    }
    func saveNotifications(_ session: NativeSession) async {
        guard NativeAccountPolicy.validTime(quietStart), NativeAccountPolicy.validTime(quietEnd) else { error = "방해금지 시간은 HH:mm 형식으로 입력해 주세요."; return }
        var body: [String: Any] = ["p_push_enabled": pushEnabled, "p_quiet_hours_enabled": quietEnabled,
            "p_quiet_hours_start": quietStart, "p_quiet_hours_end": quietEnd, "p_time_zone": "Asia/Seoul", "p_lock_screen_preview": preview]
        for (key, _) in Self.categoryLabels { body["p_\(key)"] = categories[key] == true }
        await mutate(session, rpc: "save_my_notification_preferences", body: body)
    }
    func requestDeletion(_ session: NativeSession, confirmation: String, reason: String, password: String) async {
        guard NativeAccountPolicy.validDeletion(confirmation: confirmation, reason: reason, password: password) else { error = "‘계정 삭제’를 정확히 입력하고 사유·비밀번호 길이를 확인해 주세요."; return }
        var body: [String: Any] = ["confirmation": "계정 삭제", "reason": reason.isEmpty ? NSNull() as Any : reason as Any]
        if !password.isEmpty { body["password"] = password }
        await perform(session) { _ = try await session.api.invokeFunction("request-account-deletion", body: body) }
    }
    private func perform(_ session: NativeSession, action: () async throws -> Void) async {
        guard !busy, session.signedIn else { return }
        let epoch = session.sessionGeneration, request = UUID()
        generation = epoch; requestID = request; busy = true; error = nil; notice = nil
        do {
            try await action()
            guard current(session, epoch, request) else { return }
            busy = false; requestID = nil; notice = "처리했습니다. 서버 상태를 다시 확인합니다."
            await load(session)
        } catch {
            guard current(session, epoch, request) else { return }
            busy = false; requestID = nil
            self.error = "\(error.localizedDescription) 결과가 불명확하면 다시 불러온 뒤 직접 확인해 주세요. 작업을 자동 재시도하지 않습니다."
        }
    }
}

enum NativeAccountPolicy {
    static func validTime(_ value: String) -> Bool { value.utf8.count == 5 && value.range(of: "^([01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil }
    static func validDeletion(confirmation: String, reason: String, password: String) -> Bool {
        confirmation.trimmingCharacters(in: .whitespacesAndNewlines) == "계정 삭제" && reason.unicodeScalars.count <= 500 && password.count <= 512
    }
}

struct NativeAccountSettingsView: View {
    @EnvironmentObject private var session: NativeSession
    @StateObject private var model = NativeAccountServices()
    var body: some View {
        Form {
            if let error = model.error { Text(error).foregroundStyle(.red) }
            if let notice = model.notice { Text(notice).foregroundStyle(.secondary) }
            Section("다른 회원에게 표시") {
                ForEach(NativeAccountServices.visibilityLabels, id: \.0) { key, label in
                    Toggle(label, isOn: Binding(get: { model.visibility[key] == true }, set: { model.visibility[key] = $0 }))
                }
                Button("공개 범위 저장") { Task { await model.saveVisibility(session) } }.frame(minHeight: 44)
                Text("서버가 프로필 필드와 비공개 사진의 조회 권한을 함께 제한합니다.").font(.footnote).foregroundStyle(.secondary)
            }.disabled(session.consentRequired || model.snapshot.isEmpty)
            Section("알림") {
                Toggle("알림 사용", isOn: $model.pushEnabled)
                ForEach(NativeAccountServices.categoryLabels, id: \.0) { key, label in
                    Toggle(label, isOn: Binding(get: { model.categories[key] == true }, set: { model.categories[key] = $0 }))
                }
                Toggle("방해금지 · 한국 시간", isOn: $model.quietEnabled)
                TextField("시작 HH:mm", text: $model.quietStart).keyboardType(.numbersAndPunctuation)
                TextField("종료 HH:mm", text: $model.quietEnd).keyboardType(.numbersAndPunctuation)
                Picker("잠금 화면 미리보기", selection: $model.preview) { Text("새 알림만 표시").tag("generic"); Text("미리보기 숨김").tag("hidden") }
                Button("알림 설정 저장") { Task { await model.saveNotifications(session) } }.frame(minHeight: 44)
            }.disabled(session.consentRequired || model.snapshot.isEmpty)
            Section("차단한 회원") {
                ForEach(model.blocks.indices, id: \.self) { index in
                    let row = model.blocks[index]
                    HStack { Text(nativeText(row, "display_name", fallback: "차단한 회원")); Spacer()
                        Button("차단 해제") { Task { await model.mutate(session, rpc: "unblock_user", body: ["p_user_id": nativeText(row, "user_id")]) } }
                    }.frame(minHeight: 44)
                }
                NavigationLink("익명 작성자 차단 관리") { NativeAnonymousBlocksView() }
            }
            Section {
                NavigationLink("계정 삭제·예약 취소") { NativeAccountDeletionView() }
                NavigationLink("개인 통독·QT 동의 철회·삭제") { NativeFaithWithdrawalView() }
                Button("서버 상태 다시 불러오기") { Task { await model.load(session) } }.frame(minHeight: 44)
            }
        }.navigationTitle("개인정보·알림").navigationBarTitleDisplayMode(.inline).nativePageStyle()
            .disabled(model.busy || session.loading).overlay { if model.busy { ProgressView() } }
            .task(id: session.sessionGeneration) { model.clear(); await model.load(session) }
            .onChange(of: session.consentRequired) { _, _ in model.clear(); Task { await model.load(session) } }
            .onDisappear { model.clear() }
    }
}

struct NativeAccountDeletionView: View {
    @EnvironmentObject private var session: NativeSession
    @StateObject private var model = NativeAccountServices()
    @State private var confirmation = ""
    @State private var reason = ""
    @State private var password = ""
    @State private var confirming = false
    var body: some View {
        Form {
            if let error = model.error { Text(error).foregroundStyle(.red) }
            if let notice = model.notice { Text(notice) }
            Section("계정 삭제") {
                Text("삭제를 요청하면 공동체 접근이 중지되고 14일 유예 후 계정이 삭제됩니다. 법적 보존 대상과 공유된 자료는 개인정보 처리방침의 보존·삭제 기준을 따릅니다.")
                if nativeText(model.deletion, "status") == "pending" {
                    LabeledContent("상태", value: "삭제 예약됨")
                    Text("예정 시각: " + nativeText(model.deletion, "scheduled_for"))
                    Button("계정 삭제 예약 취소") { Task { await model.mutate(session, rpc: "cancel_account_deletion", body: [:]); await session.restore() } }.frame(minHeight: 44)
                } else {
                    TextField("확인 문구: 계정 삭제", text: $confirmation)
                    TextField("탈퇴 사유 (선택, 500자 이내)", text: $reason, axis: .vertical).lineLimit(2...5)
                    SecureField("현재 비밀번호 (이메일 계정)", text: $password).textContentType(.password)
                    Button("Google로 본인 확인") { Task { _ = await session.reauthenticateForAccountDeletion() } }.frame(minHeight: 44)
                    Button("계정 삭제 요청", role: .destructive) { confirming = true }.frame(minHeight: 44)
                        .disabled(!NativeAccountPolicy.validDeletion(confirmation: confirmation, reason: reason, password: password) || model.snapshot.isEmpty)
                }
            }
            Button("예약 상태 다시 확인") { Task { await model.load(session) } }.frame(minHeight: 44)
        }.navigationTitle("계정 삭제").navigationBarTitleDisplayMode(.inline).nativePageStyle()
            .disabled(model.busy || session.loading).overlay { if model.busy { ProgressView() } }
            .task(id: session.sessionGeneration) { model.clear(); password = ""; await model.load(session) }
            .onDisappear { password = ""; confirmation = ""; reason = ""; model.clear() }
            .confirmationDialog("계정 삭제를 예약할까요?", isPresented: $confirming, titleVisibility: .visible) {
                Button("계정 삭제 예약", role: .destructive) { Task { await model.requestDeletion(session, confirmation: confirmation, reason: reason, password: password); password = ""; await session.restore() } }
            }
    }
}
