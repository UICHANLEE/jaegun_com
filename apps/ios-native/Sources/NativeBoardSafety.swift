import SwiftUI

struct NativeSafetyReportView: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.dismiss) private var dismiss
    let targetType: String
    let targetID: String
    let targetLabel: String
    @State private var reason = "harassment"
    @State private var details = ""
    @State private var busy = false
    @State private var error: String?
    @State private var submitted = false
    @State private var ticket = UUID()
    private var identity: NativeBoardIdentity? { NativeBoardIdentity.capture(session) }
    private let reasons = [("harassment", "괴롭힘"), ("spam", "스팸"), ("hate", "혐오"), ("sexual_content", "성적 콘텐츠"), ("violence", "폭력"), ("privacy", "개인정보"), ("impersonation", "사칭"), ("self_harm", "자해 위험"), ("other", "기타")]
    var body: some View {
        Form {
            Section("신고 대상") { Text(targetLabel) }
            Section("신고 사유") {
                Picker("분류", selection: $reason) { ForEach(reasons, id: \.0) { Text($0.1).tag($0.0) } }
                TextField("설명 (2,000자 이내)", text: $details, axis: .vertical).lineLimit(4...10)
                Text("신고한 대상의 최소 증거만 운영 담당자에게 제출됩니다. 신고가 다른 비공개 대화의 열람 권한을 만들지 않습니다.").font(.footnote).foregroundStyle(.secondary)
            }.disabled(busy || submitted)
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                if submitted { Text("신고가 접수되었습니다."); Button("닫기") { dismiss() } }
                else { Button(busy ? "접수 중" : "신고 접수") { Task { await submit() } }.disabled(busy || details.count > 2000 || identity == nil) }
            }
        }.navigationTitle("신고").nativePageStyle()
            .onChange(of: identity?.key) { _, _ in ticket = UUID(); details = ""; error = nil; submitted = false; busy = false; dismiss() }
            .onDisappear { ticket = UUID() }
    }
    private func submit() async {
        guard !busy, let identity, UUID(uuidString: targetID) != nil else { return }
        let request = ticket
        busy = true; error = nil
        defer { if ticket == request && NativeBoardIdentity.capture(session) == identity { busy = false } }
        do {
            var parameters: [String: Any] = ["p_target_id": targetID, "p_reason_code": reason, "p_details": details.trimmingCharacters(in: .whitespacesAndNewlines)]
            if targetType != "channel_message" { parameters["p_target_type"] = targetType }
            _ = try await session.api.rpc(targetType == "channel_message" ? "report_channel_message" : "create_content_report", body: parameters)
            guard ticket == request, NativeBoardIdentity.capture(session) == identity else { return }
            submitted = true
        } catch { if ticket == request && NativeBoardIdentity.capture(session) == identity { self.error = error.localizedDescription } }
    }
}

struct NativeSafetyBlockButton: View {
    @EnvironmentObject private var session: NativeSession
    let userID: String
    let onBlocked: () -> Void
    @State private var confirm = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        Button("사용자 차단", role: .destructive) { confirm = true }.disabled(busy)
            .confirmationDialog("이 사용자의 글과 메시지를 차단할까요?", isPresented: $confirm, titleVisibility: .visible) {
                Button("차단", role: .destructive) { Task { await block() } }
            }
        if let error { Text(error).font(.footnote).foregroundStyle(.red) }
    }
    private func block() async {
        guard !busy, let identity = NativeBoardIdentity.capture(session), UUID(uuidString: userID) != nil else { return }
        busy = true; error = nil
        do {
            _ = try await session.api.rpc("block_user", body: ["p_user_id": userID, "p_reason": NSNull()])
            guard NativeBoardIdentity.capture(session) == identity else { return }
            busy = false; onBlocked()
        } catch { guard NativeBoardIdentity.capture(session) == identity else { return }; busy = false; self.error = error.localizedDescription }
    }
}

struct NativeAnonymousBlocksView: View {
    @EnvironmentObject private var session: NativeSession
    @State private var rows: [[String: Any]] = []
    @State private var busy = false
    @State private var error: String?
    @State private var ticket = UUID()
    private var identity: NativeBoardIdentity? { NativeBoardIdentity.capture(session) }
    var body: some View {
        List {
            Text("신원 대신 차단 날짜만 표시합니다. 해제해도 작성자의 신원은 공개되지 않습니다.").font(.footnote).foregroundStyle(.secondary)
            if busy { ProgressView("차단 목록을 불러오고 있습니다") }
            if let error { Text(error).foregroundStyle(.red); Button("다시 불러오기") { Task { await load() } } }
            if rows.isEmpty && !busy { Text("차단한 익명 작성자가 없습니다.").foregroundStyle(.secondary) }
            ForEach(rows.indices, id: \.self) { index in
                HStack {
                    Text("익명 작성자 · \(nativeText(rows[index], "created_at").prefix(10))")
                    Spacer()
                    Button("해제") { let id = nativeText(rows[index], "id"); Task { await load(removing: id) } }.disabled(busy)
                }
            }
        }.navigationTitle("익명 작성자 차단").nativePageStyle()
            .task(id: identity?.key) { ticket = UUID(); rows = []; busy = false; error = nil; await load() }
            .onDisappear { ticket = UUID(); rows = [] }
    }
    private func load(removing id: String? = nil) async {
        guard !busy, let identity else { return }
        let request = ticket
        func current() -> Bool { request == ticket && NativeBoardIdentity.capture(session) == identity && !Task.isCancelled }
        busy = true; error = nil
        defer { if current() { busy = false } }
        do {
            if let id { _ = try await session.api.rpc("remove_my_anonymous_block", body: ["p_block_id": id]); guard current() else { return } }
            guard let loaded = try await session.api.rpc("list_my_anonymous_blocks") as? [[String: Any]] else { throw NativeAPIError.invalidData }
            guard current() else { return }; rows = loaded
        } catch { if current() { rows = []; self.error = error.localizedDescription } }
    }
}

struct NativeCommentBlockButton: View {
    @EnvironmentObject private var session: NativeSession
    let commentID: String
    let onBlocked: () async -> Void
    @State private var confirm = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        Button("댓글 작성자 차단", role: .destructive) { confirm = true }.disabled(busy)
            .confirmationDialog("작성자의 글과 메시지를 차단할까요? 익명 신원은 공개되지 않습니다.", isPresented: $confirm, titleVisibility: .visible) {
                Button("차단", role: .destructive) { Task { await block() } }
            }
        if let error { Text(error).font(.footnote).foregroundStyle(.red) }
    }
    private func block() async {
        guard !busy, let identity = NativeBoardIdentity.capture(session) else { return }
        busy = true; error = nil
        do {
            _ = try await session.api.rpc("block_community_comment_author", body: ["p_comment_id": commentID, "p_expected_actor_id": identity.actorID])
            guard NativeBoardIdentity.capture(session) == identity else { return }
            busy = false; await onBlocked()
        } catch { guard NativeBoardIdentity.capture(session) == identity else { return }; busy = false; self.error = error.localizedDescription }
    }
}
