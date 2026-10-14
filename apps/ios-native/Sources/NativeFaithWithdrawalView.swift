import SwiftUI

struct NativeFaithWithdrawalView: View {
    @EnvironmentObject private var session: NativeSession
    @State private var confirmed = false
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        Form {
            Section("개인 기록 동의 철회") {
                Text("본인의 모든 연도 통독 진도, 개인 QT와 중복 방지 기록을 삭제합니다. 이미 게시판에 공개한 글은 별도로 삭제해야 합니다. 삭제는 되돌릴 수 없습니다.")
                Toggle("동의 철회와 개인 기록 삭제를 확인했습니다", isOn: $confirmed).disabled(busy)
                Button("동의 철회 및 개인 기록 삭제", role: .destructive) { Task { await withdraw() } }
                    .frame(minHeight: 44).disabled(!confirmed || busy || !session.signedIn)
                if busy { ProgressView("삭제 결과를 확인하고 있습니다") }
                if let message { Text(message).accessibilityAddTraits(.updatesFrequently) }
            }
        }.navigationTitle("개인 기록 삭제").nativePageStyle()
            .task(id: session.sessionGeneration) { confirmed = false; busy = false; message = nil }
    }
    @MainActor private func withdraw() async {
        guard confirmed, !busy, session.signedIn else { return }
        let epoch = session.sessionGeneration
        busy = true; message = nil
        defer { if session.sessionGeneration == epoch { busy = false } }
        do {
            let result = try await session.api.rpc("withdraw_faith_consent", body: ["p_organization_id": NSNull(), "p_confirm_delete": true])
            guard session.sessionGeneration == epoch, !Task.isCancelled else { return }
            guard let row = result as? [String: Any], row["accepted"] as? Bool == false, row["deleted"] as? Bool == true else { throw NativeAPIError.invalidData }
            message = "동의를 철회하고 개인 통독·QT 기록을 삭제했습니다."
        } catch {
            guard session.sessionGeneration == epoch, !Task.isCancelled else { return }
            message = "삭제 결과를 확인하지 못했습니다. 같은 요청으로 다시 확인해 주세요."
        }
    }
}
