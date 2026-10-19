import SwiftUI

func nativeText(_ row: [String: Any], _ key: String, fallback: String = "") -> String {
    row[key] as? String ?? fallback
}

private struct NativeTabActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var nativeTabActive: Bool {
        get { self[NativeTabActiveKey.self] }
        set { self[NativeTabActiveKey.self] = newValue }
    }
}

struct NativeCommunityTabs: View {
    @EnvironmentObject private var session: NativeSession
    private var membership: [String: Any] { session.context["membership"] as? [String: Any] ?? [:] }
    private var isPlatformAdmin: Bool { session.context["is_platform_admin"] as? Bool == true }
    private var isManager: Bool {
        isPlatformAdmin || ["minister", "executive"].contains(nativeText(membership, "role"))
    }
    var body: some View {
        NativeCommunityTabWorkspace(isManager: isManager)
            // Retained screens never cross an actor, church or authorization-role
            // boundary. Core-consent closure removes this entire subtree at root.
            .id("\(session.sessionGeneration):\(nativeText(session.context["profile"] as? [String: Any] ?? [:], "id")):\(nativeText(membership, "organization_id")):\(nativeText(membership, "status")):\(nativeText(membership, "role")):\(isPlatformAdmin)")
    }
}

private struct NativeCommunityTabWorkspace: View {
    let isManager: Bool
    @State private var selectedTab: String
    init(isManager: Bool) {
        self.isManager = isManager
        _selectedTab = State(initialValue: isManager ? "more" : "home")
    }
    var body: some View {
        // A selected-tab switch destroys @State/@StateObject on every hop.
        // System tab containers retain each screen and its own navigation stack,
        // while disappearance still cancels tasks and stops realtime subscriptions.
        TabView(selection: $selectedTab) {
            Tab("홈", systemImage: "house", value: "home") { tabRoot("home") { NativeMemberHomeView() } }
            Tab("모임", systemImage: "calendar", value: "events") { tabRoot("events") { NativeEventOperationsView() } }
            Tab("게시판", systemImage: "doc.text", value: "posts") { tabRoot("posts") { NativeFeedView() } }
            Tab("채팅", systemImage: "bubble.left", value: "chats") { tabRoot("chats") { NativeCommunityChatHubView() } }
            Tab("더보기", systemImage: "ellipsis", value: "more") { tabRoot("more") { NativeMoreView(isManager: isManager) } }
        }.toolbar(.hidden, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                NativeCommunityNavigation(selection: $selectedTab)
            }.tint(NativePalette.blue)
    }
    private func tabRoot<Content: View>(_ id: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content().environment(\.nativeTabActive, selectedTab == id)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { NativeBrandHeader(compact: true) }
                if isManager {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink { NativeManagementHubView() } label: {
                            Text("관리 화면").font(.caption.weight(.semibold)).frame(minHeight: 44)
                        }
                    }
                }
            }
        }.toolbar(.hidden, for: .tabBar)
    }
}

struct NativeMoreView: View {
    let isManager: Bool
    var body: some View {
        List {
            if isManager {
                Section("내 역할의 관리 도구") {
                    NavigationLink { NativeManagementHubView() } label: { Label("관리 화면", systemImage: "person.badge.shield.checkmark") }
                }
            }
            Section("공동체") {
                NavigationLink { NativeChurchSummaryView() } label: { Label("우리 교회", systemImage: "building.2") }
                NavigationLink { NativeOfficeHomeView() } label: { Label("임원실·조직도", systemImage: "person.3") }
                NavigationLink { NativeAILandingView() } label: { Label("AI 도우미", systemImage: "sparkles") }
                NavigationLink { NativeBibleReaderView() } label: { Label("성경 읽기", systemImage: "book") }
            }
            NativeExecutiveRecordLinks()
            Section("내 계정") {
                NavigationLink { NativeProfileView() } label: { Label("내 정보·설정", systemImage: "person.crop.circle") }
            }
            Section("화면 설정") {
                NativeAppearancePicker()
                Text("선택한 화면 모드는 이 기기에만 저장됩니다.").font(.footnote).foregroundStyle(NativePalette.muted)
            }
        }.listStyle(.insetGrouped).navigationTitle("더보기").nativePageStyle()
    }
}

struct NativeOfficeHomeView: View {
    var body: some View {
        List {
            Section("조직·임원") {
                NavigationLink("조직도·명단·직책 이력") { NativeGovernanceView() }
                Text("직책과 기록 접근 권한은 조직·연도·업무 범위별로 서버에서 확인합니다.").font(.footnote).foregroundStyle(.secondary)
            }
            NativeExecutiveRecordLinks()
        }.navigationTitle("임원실").nativePageStyle()
    }
}

struct NativeFailureView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            ContentUnavailableView("정보를 불러오지 못했습니다", systemImage: "wifi.exclamationmark", description: Text(message))
            Button("다시 불러오기", action: retry).buttonStyle(.borderedProminent).frame(minHeight: 44)
        }.padding().accessibilityElement(children: .contain)
    }
}

struct NativeFeedView: View {
    var body: some View { NativeBoardFeedView() }
}

struct NativeProfileView: View {
    @EnvironmentObject private var session: NativeSession
    var body: some View {
        Form {
            Section("내 계정") {
                let profile = session.context["profile"] as? [String: Any] ?? [:]
                LabeledContent("이름", value: nativeText(profile, "display_name", fallback: "이름 미설정"))
                LabeledContent("접속 상태", value: "로그인됨")
            }
            Section("공동체") {
                NavigationLink("성경 본문 · 오프라인 읽기") { NativeBibleReaderView() }
                NavigationLink("조직·명단·직책 이력") { NativeGovernanceView() }
                NavigationLink("예배·행사·현장 운영") { NativeEventOperationsView() }
                NavigationLink("화상회의") { NativeMeetingsView() }
                NavigationLink("교회 라이브·주보") { NativeChurchLiveView() }
            }
            NativeExecutiveRecordLinks()
            Section("계정·안전") {
                NavigationLink("개인정보·알림·차단") { NativeAccountSettingsView() }
                NavigationLink("내 신고·조치·이의신청") { NativeMyReportsView() }
                NavigationLink("개인 통독·QT 동의 철회·삭제") { NativeFaithWithdrawalView() }
                NavigationLink("계정 삭제·예약 취소") { NativeAccountDeletionView() }
            }
            Section {
                Button("계정 다시 확인") { Task { await session.restore() } }
                Button("로그아웃", role: .destructive) { Task { await session.signOut() } }
            }
        }.navigationTitle("내 정보").nativePageStyle()
    }
}
