import SwiftUI

struct NativeCommunityNavigation: View {
    @Binding var selection: String
    static let items = [("home", "홈", "house"), ("events", "모임", "calendar"), ("posts", "게시판", "doc.text"), ("chats", "채팅", "bubble.left"), ("more", "더보기", "ellipsis")]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.items, id: \.0) { id, label, icon in
                Button { selection = id } label: {
                    VStack(spacing: 5) {
                        Image(systemName: icon).font(.system(size: 21, weight: .regular))
                        Text(label).font(.caption2)
                    }.frame(maxWidth: .infinity, minHeight: 56)
                        .foregroundStyle(selection == id ? NativePalette.blue : NativePalette.muted)
                }.buttonStyle(.plain).accessibilityLabel(label)
                    .accessibilityAddTraits(selection == id ? .isSelected : [])
            }
        }.padding(.horizontal, 8).background(NativePalette.surface)
            .overlay(alignment: .top) { Rectangle().fill(NativePalette.line).frame(height: 1).accessibilityHidden(true) }
    }
}

struct NativeMemberHomeView: View {
    @EnvironmentObject private var session: NativeSession
    @State private var posts: [[String: Any]] = []
    @State private var loading = true
    @State private var error: String?
    @State private var requestID: UUID?
    @State private var loadedIdentity = ""
    private var identity: String {
        guard session.signedIn, !session.consentRequired else { return "" }
        let membership = session.context["membership"] as? [String: Any] ?? [:]
        guard nativeText(membership, "status") == "active" else { return "" }
        return "\(session.sessionGeneration):\(nativeText(membership, "organization_id"))"
    }
    private var visiblePosts: [[String: Any]] { loadedIdentity == identity ? posts : [] }
    private var pinned: [String: Any]? { visiblePosts.first { $0["is_pinned"] as? Bool == true } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("홈").font(.title2.bold())
                    NavigationLink { NativeChurchSummaryView() } label: {
                        Label("소속 교회 확인", systemImage: "building.2").font(.caption).frame(minHeight: 44)
                    }
                }
                NativeLiveHomeBanner()
                NativeFaithHomeSummary()
                VStack(alignment: .leading, spacing: 12) {
                    Text("교회 공지").font(.headline)
                    if loading { ProgressView("소식을 불러오고 있습니다") }
                    else if let error { NativeFailureView(message: error) { Task { await load() } } }
                    else if let pinned {
                        NavigationLink { NativePostDetailView(post: pinned) } label: {
                            NativeCard {
                                NativePostSummary(post: pinned)
                                Label("공지 보기", systemImage: "arrow.right").font(.caption.weight(.semibold)).foregroundStyle(NativePalette.orange)
                            }.overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2).fill(NativePalette.noticeAccent).frame(width: 3)
                            }
                        }.buttonStyle(.plain)
                    } else { Text("등록된 공지가 없습니다.").font(.subheadline).foregroundStyle(NativePalette.muted) }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("게시글").font(.headline)
                        Spacer()
                        NavigationLink { NativeFeedView() } label: { Label("전체 보기", systemImage: "arrow.right").font(.caption) }.frame(minHeight: 44)
                    }
                    ForEach(Array(visiblePosts.prefix(3).enumerated()), id: \.offset) { _, post in
                        NavigationLink { NativePostDetailView(post: post) } label: { NativePostSummary(post: post) }.buttonStyle(.plain)
                        Divider()
                    }
                    if !loading && visiblePosts.isEmpty && error == nil { Text("아직 등록된 게시글이 없습니다.").font(.subheadline).foregroundStyle(NativePalette.muted) }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("소모임").font(.headline)
                    Text("교회 회원끼리 채널에서 대화를 이어가세요.").font(.subheadline).foregroundStyle(NativePalette.muted)
                    NavigationLink { NativeCommunityChatHubView() } label: {
                        NativeCard { Label("소모임 찾기", systemImage: "person.2").font(.subheadline.weight(.semibold)) }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("예배·일정").font(.headline)
                    NavigationLink { NativeEventOperationsView() } label: {
                        Label("모임 일정 확인", systemImage: "calendar").font(.subheadline).frame(minHeight: 44)
                    }
                }
            }.padding(20).frame(maxWidth: 780).frame(maxWidth: .infinity)
        }.background(NativePalette.surface).foregroundStyle(NativePalette.ink)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: identity) {
                if loadedIdentity != identity { posts = []; loadedIdentity = ""; requestID = nil }
                await load()
            }
            .refreshable { await load() }
    }
    private func load() async {
        let actor = identity
        guard !actor.isEmpty, requestID == nil else { return }
        let request = UUID(); requestID = request
        loading = posts.isEmpty; error = nil
        defer { if requestID == request { requestID = nil; loading = false } }
        let churchID = nativeText(session.context["membership"] as? [String: Any] ?? [:], "organization_id")
        guard UUID(uuidString: churchID) != nil else { posts = []; return }
        do {
            guard let rows = try await session.api.rpc("list_community_posts", body: ["p_limit": 20]) as? [[String: Any]] else { throw NativeAPIError.invalidData }
            guard identity == actor, requestID == request, !Task.isCancelled else { return }
            posts = rows; loadedIdentity = actor
        } catch {
            guard identity == actor, requestID == request, !Task.isCancelled else { return }
            if !NativeBoardPolicy.mayRetainProtectedRows(after: error) { posts = []; loadedIdentity = "" }
            self.error = "교회 소식을 불러오지 못했습니다. 연결과 접근 권한을 확인해 주세요."
        }
    }
}

struct NativePostDetailView: View {
    let post: [String: Any]
    var body: some View {
        NativeBoardPostDetailView(postID: nativeText(post, "id"))
    }
}

struct NativeChurchSummaryView: View {
    @EnvironmentObject private var session: NativeSession
    @State private var churches: [[String: Any]] = []
    @State private var error: String?
    @State private var loading = true
    private var churchID: String { nativeText(session.context["membership"] as? [String: Any] ?? [:], "organization_id") }
    var body: some View {
        List {
            Section("내 교회") {
                if loading { ProgressView("교회 정보를 불러오고 있습니다") }
                if let error { Text(error).foregroundStyle(.red) }
                if !loading && churches.isEmpty && error == nil { Text("확인할 소속 교회가 없습니다.").foregroundStyle(NativePalette.muted) }
                ForEach(churches.indices, id: \.self) { index in
                    let church = churches[index]
                    Label(nativeText(church, "display_name"), systemImage: "building.2").font(.headline)
                    Text(nativeText(church, "presbytery")).foregroundStyle(NativePalette.muted)
                }
            }
            Section("공동체") {
                NavigationLink("교회 채널·개인 대화") { NativeCommunityChatHubView() }
                NavigationLink("예배·모임 일정") { NativeEventOperationsView() }
                NavigationLink("조직·명단·직책 이력") { NativeGovernanceView() }
                NavigationLink("교회 라이브·주보") { NativeChurchLiveView() }
                NavigationLink("화상회의") { NativeMeetingsView() }
            }
        }.navigationTitle("교회").nativePageStyle().task { await load() }.refreshable { await load() }
    }
    private func load() async {
        loading = true; error = nil
        guard UUID(uuidString: churchID) != nil else { churches = []; loading = false; return }
        do { churches = try await session.api.rows("public_organization_directory", query: "select=id,display_name,presbytery&id=eq.\(churchID)") }
        catch { churches = []; self.error = "교회 정보를 불러오지 못했습니다." }
        loading = false
    }
}

struct NativeAILandingView: View {
    var body: some View { NativeAIDraftView() }
}
