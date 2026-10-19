import SwiftUI

struct NativeManagementHubView: View {
    @EnvironmentObject private var session: NativeSession
    private var role: String { nativeText(session.context["membership"] as? [String: Any] ?? [:], "role") }
    private var administrator: Bool { session.context["is_platform_admin"] as? Bool == true }
    private var title: String { administrator ? "플랫폼 관리" : role == "minister" ? "사역자 관리" : "임원 운영" }
    var body: some View {
        List {
            Section(title) {
                NavigationLink("가입·직책 신청 심사") { NativeApprovalOperationsView() }
                NavigationLink("조직·임원·부서·권한 위임") { NativeGovernanceView() }
                NavigationLink("예배·행사·참가자 운영") { NativeEventOperationsView() }
            }
            if role == "executive" {
                Section("임원 기록") {
                    NavigationLink("범위·연도별 회의록") { NativeExecutiveRecordsView(kind: .minutes) }
                    NavigationLink("회계장부·영수증·결산") { NativeExecutiveRecordsView(kind: .finance) }
                    Text("조회·작성 권한은 현재 조직과 연도별 직책에 따라 서버에서 확인합니다.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if administrator {
                Section("운영 관제") {
                    NavigationLink("사용량·감사·신고 사건") { NativeOperationsConsoleView() }
                }
            }
            Section("공동체 도구") {
                NavigationLink("채널·개인 대화") { NativeCommunityChatHubView() }
                NavigationLink("화상회의") { NativeMeetingsView() }
                NavigationLink("교회 라이브·주보") { NativeChurchLiveView() }
                NavigationLink("성경 도구") { NativeAIDraftView() }
            }
            Section {
                Text("조회에는 인증 앱 등록이나 Google 재인증이 필요하지 않습니다. 권한 변경 등 민감한 작업은 버튼 실행 전에 최근 Google 본인 확인이 필요합니다.").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline).nativePageStyle()
    }
}
