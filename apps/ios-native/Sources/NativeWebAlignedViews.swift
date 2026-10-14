import SwiftUI

struct NativeCommunityNavigation: View {
    @Binding var selection: String
    static let items = [("home", "홈", "house"), ("posts", "게시판", "doc.text"), ("chats", "채팅", "bubble.left"), ("churches", "교회", "building.2"), ("ai", "AI", "sparkles"), ("profile", "내 정보", "person.crop.circle")]
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
    private var pinned: [String: Any]? { posts.first { $0["is_pinned"] as? Bool == true } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("홈").font(.title2.bold())
                    NavigationLink { NativeChurchSummaryView() } label: {
                        Label("소속 교회 확인", systemImage: "building.2").font(.caption).frame(minHeight: 44)
                    }
                }
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
                    ForEach(Array(posts.prefix(3).enumerated()), id: \.offset) { _, post in
                        NavigationLink { NativePostDetailView(post: post) } label: { NativePostSummary(post: post) }.buttonStyle(.plain)
                        Divider()
                    }
                    if !loading && posts.isEmpty { Text("아직 등록된 게시글이 없습니다.").font(.subheadline).foregroundStyle(NativePalette.muted) }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("소모임").font(.headline)
                    Text("교회 회원끼리 채널에서 대화를 이어가세요.").font(.subheadline).foregroundStyle(NativePalette.muted)
                    NavigationLink { NativeChannelListView() } label: {
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
            .navigationBarTitleDisplayMode(.inline).task { await load() }.refreshable { await load() }
    }
    private func load() async {
        loading = true; error = nil
        let churchID = nativeText(session.context["membership"] as? [String: Any] ?? [:], "organization_id")
        guard UUID(uuidString: churchID) != nil else { posts = []; loading = false; return }
        do { posts = try await session.api.rows("posts", query: "select=id,title,body,author_label,is_pinned,published_at&organization_id=eq.\(churchID)&status=eq.published&order=is_pinned.desc,published_at.desc&limit=20") }
        catch { posts = []; self.error = "교회 소식을 불러오지 못했습니다. 연결과 접근 권한을 확인해 주세요." }
        loading = false
    }
}

struct NativePostDetailView: View {
    let post: [String: Any]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(nativeText(post, "title")).font(.title2.bold())
                Text(nativeText(post, "author_label")).font(.caption).foregroundStyle(NativePalette.muted)
                Divider()
                Text(nativeText(post, "body")).lineSpacing(5).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }.navigationTitle("게시글").nativePageStyle()
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
                NavigationLink("교회 채널") { NativeChannelListView() }
                NavigationLink("예배·모임 일정") { NativeEventOperationsView() }
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
    @State private var draft = ""
    @State private var pendingTemplate: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("AI 도우미").font(.title2.bold())
                Text("공동체에 필요한 글을 준비하세요.").foregroundStyle(NativePalette.muted)
                NativeCard {
                    Label("AI 연결 준비 중", systemImage: "sparkles").font(.headline)
                    Text("현재는 요청 내용을 정리하는 화면입니다. AI 응답을 생성하거나 교회 정보를 외부로 전송하지 않습니다.").font(.subheadline).foregroundStyle(NativePalette.muted)
                }
                Text("무엇을 준비할까요?").font(.headline)
                ForEach(["모임 준비", "공지 작성", "회의록 정리", "성경 공부"], id: \.self) { title in
                    Button {
                        if draft.isEmpty { apply(title) } else { pendingTemplate = title }
                    } label: {
                        NativeCard { Label(title, systemImage: "doc.text").font(.subheadline) }
                    }.buttonStyle(.plain).foregroundStyle(NativePalette.blue)
                }
                Text("요청 내용").font(.headline)
                TextEditor(text: $draft).frame(minHeight: 150).padding(10)
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(NativePalette.line) }
                    .onChange(of: draft) { _, text in if text.count > 8000 { draft = String(text.prefix(8000)) } }
                Text("\(draft.count)/8000자").font(.caption).foregroundStyle(NativePalette.muted)
                Text("입력 내용은 이 화면의 메모리에만 유지됩니다. 개인정보나 민감한 교회 정보는 입력하지 마세요.").font(.caption).foregroundStyle(NativePalette.muted)
            }.padding(20).frame(maxWidth: 780).frame(maxWidth: .infinity)
        }.nativePageStyle().scrollDismissesKeyboard(.interactively).navigationTitle("AI")
            .alert("작성 중인 내용을 바꿀까요?", isPresented: Binding(get: { pendingTemplate != nil }, set: { if !$0 { pendingTemplate = nil } })) {
                Button("예시로 바꾸기") { if let title = pendingTemplate { apply(title) }; pendingTemplate = nil }
                Button("취소", role: .cancel) { pendingTemplate = nil }
            } message: { Text("현재 입력한 내용은 새 예시로 교체됩니다.") }
    }
    private func apply(_ title: String) { draft = title + "을 도와주세요. 목적과 필요한 내용을 아래에 작성합니다.\n" }
}
