import SwiftUI

struct NativeEventFeeView: View {
    let occurrenceID: String
    @EnvironmentObject private var session: NativeSession
    @State private var rows: [[String: Any]] = []
    @State private var selected = ""
    @State private var amount = ""
    @State private var reason = ""
    @State private var operationID = UUID().uuidString
    @State private var pendingRequest: [String: Any]?
    @State private var pendingOperationID = ""
    @State private var busy = false
    @State private var error: String?
    private var row: [String: Any]? { rows.first { nativeText($0, "user_id") == selected } }
    private var allowed: Bool { session.signedIn && !session.consentRequired }
    var body: some View {
        List {
            Section {
                Text("행사 회비").font(.title2.bold())
                Text("회비 담당 권한에만 표시됩니다. 납부는 행사 독립 장부 수입으로, 취소·환불은 원 전표를 보존한 역분개로 연결됩니다.").font(.footnote)
                Button("조회·처리 상태 확인") { Task { await load() } }.disabled(busy)
                Picker("참가자", selection: $selected) {
                    Text("선택").tag("")
                    ForEach(rows.indices, id: \.self) { i in
                        let r = rows[i]
                        Text("\(nativeText(r, "display_name")) · \(r["paid"] as? Bool == true ? "납부" : "미납") · \(r["amount"] ?? 0) KRW").tag(nativeText(r, "user_id"))
                    }
                }.disabled(busy)
                TextField("납부 금액 KRW", text: $amount).keyboardType(.decimalPad).disabled(busy)
                TextField("처리 사유 2~500자", text: $reason).disabled(busy)
                Button("납부 기록·금액 정정") { Task { await record(paid: true) } }.disabled(busy || row == nil || reason.count < 2 || reason.count > 500 || (Decimal(string: amount) ?? 0) <= 0)
                Button("취소·환불 역분개", role: .destructive) { Task { await record(paid: false) } }.disabled(busy || row?["paid"] as? Bool != true || reason.count < 2 || reason.count > 500)
                Button("Google 본인 확인") { Task { _ = await session.reauthenticateGoogle() } }.disabled(busy)
                Text("본인 확인 이후 처리 버튼을 직접 다시 누르세요. 응답이 불명확하면 상태 확인 후 같은 요청을 직접 재시도하세요.").font(.footnote)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.listStyle(.plain).navigationTitle("행사 회비").nativePageStyle().task { await load() }
            .onChange(of: selected) { _, _ in operationID = UUID().uuidString; amount = String(describing: row?["amount"] ?? "") }
            .onChange(of: amount) { _, _ in operationID = UUID().uuidString }
            .onChange(of: reason) { _, _ in operationID = UUID().uuidString }
            .onChange(of: session.sessionGeneration) { _, _ in clear(); Task { await load() } }
            .onChange(of: session.consentRequired) { _, required in if required { clear() } }
            .onChange(of: session.signedIn) { _, signed in if !signed { clear() } }
    }
    private func load() async {
        guard allowed else { return }; let generation = session.sessionGeneration
        do {
            let data = try await session.api.rpc("get_event_fee_status", body: ["p_occurrence_id": occurrenceID]) as? [String: Any] ?? [:]
            guard allowed, generation == session.sessionGeneration else { return }
            rows = data["rows"] as? [[String: Any]] ?? []; error = nil
        } catch { if generation == session.sessionGeneration { rows = []; self.error = error.localizedDescription } }
    }
    private func record(paid: Bool) async {
        guard allowed, !busy, let row else { return }; let generation = session.sessionGeneration; let actor = nativeText(session.context["profile"] as? [String: Any] ?? [:], "id")
        if pendingOperationID == operationID, let pendingRequest, pendingRequest["p_paid"] as? Bool != paid { error = "이전 처리 상태를 확인하고 사유를 새로 입력해 다른 처리를 시작하세요."; return }
        busy = true
        defer { busy = false }
        do {
            guard NativeSensitiveAuthStatus.isVerified(try await session.api.rpc("get_sensitive_action_auth_status")) else { throw NativeAPIError.security("최근 Google 본인 확인이 필요합니다.") }
            let raw = paid ? amount : String(describing: row["amount"] ?? "")
            guard let decimal = Decimal(string: raw), decimal > 0 else { throw NativeAPIError.security("양수 금액이 필요합니다.") }
            let body: [String: Any]
            if pendingOperationID == operationID, let pendingRequest { body = pendingRequest }
            else {
                body = ["p_occurrence_id": occurrenceID, "p_user_id": nativeText(row, "user_id"), "p_paid": paid, "p_amount": NSDecimalNumber(decimal: decimal), "p_operation_id": operationID, "p_reason": reason, "p_expected_revision": row["revision"] ?? 0, "p_expected_actor_id": actor]
                pendingRequest = body; pendingOperationID = operationID
            }
            _ = try await session.api.rpc("record_event_fee", body: body)
            guard allowed, generation == session.sessionGeneration else { return }; operationID = UUID().uuidString; await load()
        } catch { if generation == session.sessionGeneration { self.error = error.localizedDescription + " 상태 확인 후 직접 다시 시도하세요." } }
    }
    private func clear() { rows = []; selected = ""; amount = ""; reason = ""; error = nil; operationID = UUID().uuidString; pendingRequest = nil; pendingOperationID = "" }
}
