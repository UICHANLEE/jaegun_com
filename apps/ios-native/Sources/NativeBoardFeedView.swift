import SwiftUI

struct NativeBoardFeedView: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.nativeTabActive) private var tabActive
    @StateObject private var composer = NativeBoardComposerModel()
    @State private var boards: [[String: Any]] = []
    @State private var posts: [[String: Any]] = []
    @State private var selectedBoard = ""
    @State private var search = ""
    @State private var loading = false
    @State private var hasMore = false
    @State private var error: String?
    @State private var ticket = UUID()
    @State private var loadedIdentity: NativeBoardIdentity?
    @State private var composing = false
    @State private var publishedID: String?
    private var identity: NativeBoardIdentity? { NativeBoardIdentity.capture(session) }
    private var displayedPosts: [[String: Any]] {
        guard loadedIdentity == identity, identity != nil else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return posts.filter { query.isEmpty || "\(nativeText($0, "title")) \(nativeText($0, "body")) \(nativeText($0, "author_label"))".localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        let visiblePosts = displayedPosts
        let boardNames = Dictionary(boards.map { (nativeText($0, "id"), nativeText($0, "name")) }, uniquingKeysWith: { first, _ in first })
        return List {
            VStack(alignment: .leading, spacing: 18) {
                NativeBrandHeader()
                HStack {
                    Text("공동체 소식").font(.title2.bold())
                    Spacer()
                    Button { composing = true } label: { Label("글쓰기", systemImage: "square.and.pencil") }
                        .buttonStyle(.borderedProminent).frame(minHeight: 44).disabled(identity == nil)
                }
                Text("소속 교회의 게시글과 공동체 공지를 확인합니다.").font(.subheadline).foregroundStyle(.secondary)
                Picker("게시판 필터", selection: $selectedBoard) {
                    Text("전체 게시판").tag("")
                    ForEach((loadedIdentity == identity ? boards : []).indices, id: \.self) { index in
                        Text(nativeText(boards[index], "name")).tag(nativeText(boards[index], "id"))
                    }
                }.pickerStyle(.menu)
                TextField("불러온 글의 제목·내용·작성자 검색", text: $search)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("불러온 게시글 검색")
                Text("불러온 \(loadedIdentity == identity ? posts.count : 0)개 중 \(visiblePosts.count)개 · 고정글 우선, 최신순")
                    .font(.caption).foregroundStyle(.secondary)
                NavigationLink("익명 작성자 차단 관리") { NativeAnonymousBlocksView() }
            }.padding(.vertical, 12).listRowSeparator(.hidden)
            if identity == nil {
                Text("현재 동의와 교회 가입 승인을 확인해 주세요.").foregroundStyle(.secondary)
            }
            if loading { ProgressView("소식을 불러오고 있습니다") }
            if let error {
                Text(error).foregroundStyle(.red)
                Button("다시 불러오기") { Task { await load() } }.frame(minHeight: 44)
            }
            if !loading && visiblePosts.isEmpty && error == nil && identity != nil {
                ContentUnavailableView("아직 등록된 소식이 없습니다", systemImage: "text.bubble", description: Text("게시판이나 검색어를 바꾸거나 위의 글쓰기로 소식을 나눠 보세요."))
                if !search.isEmpty || !selectedBoard.isEmpty {
                    Button("필터 초기화") { search = ""; selectedBoard = "" }.frame(minHeight: 44)
                }
            }
            ForEach(visiblePosts.indices, id: \.self) { index in
                let post = visiblePosts[index]
                NavigationLink { NativeBoardPostDetailView(postID: nativeText(post, "id")) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let name = boardNames[nativeText(post, "board_id")] {
                            Text(name).font(.caption.weight(.semibold)).foregroundStyle(NativePalette.blue)
                        }
                        NativePostSummary(post: post)
                    }
                }
            }
            if hasMore {
                Button("이전 게시글 더 보기") { Task { await load(append: true) } }.frame(minHeight: 44).disabled(loading)
            }
        }.listStyle(.plain).navigationTitle("게시판").nativePageStyle().tint(NativePalette.blue)
            .refreshable { await load() }
            .task(id: identity?.key) {
                if loadedIdentity != identity { clear() }
                await load()
            }
            .onChange(of: selectedBoard) { _, _ in posts = []; hasMore = false; Task { await load() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { ticket = UUID(); posts = []; boards = []; loadedIdentity = nil; loading = false; composer.suspend() }
                if phase == .active && tabActive { Task { await load() } }
            }
            .sheet(isPresented: $composing) {
                NavigationStack {
                    NativeBoardComposerView(model: composer, boards: boards) { id in
                        publishedID = id
                        Task { await load() }
                    }
                }.environmentObject(session)
            }
            .navigationDestination(isPresented: Binding(get: { publishedID != nil }, set: { if !$0 { publishedID = nil } })) {
                if let publishedID { NativeBoardPostDetailView(postID: publishedID) }
            }
    }
    private func clear() {
        ticket = UUID(); loadedIdentity = nil; boards = []; posts = []; error = nil
        hasMore = false; loading = false; composing = false; publishedID = nil; search = ""; selectedBoard = ""; composer.clear()
    }
    private func load(append: Bool = false) async {
        guard tabActive, scenePhase != .background, let identity else { return }
        if append && loading { return }
        let request = UUID(), boardID = selectedBoard
        ticket = request; loading = true; error = nil
        let offset = append ? posts.count : 0
        // Same-scope refresh keeps the visible snapshot. Identity/filter changes
        // and authoritative permission failures still clear it immediately.
        if !append { hasMore = false }
        func current() -> Bool {
            !Task.isCancelled && ticket == request && NativeBoardIdentity.capture(session) == identity && selectedBoard == boardID && scenePhase != .background
        }
        defer { if current() { loading = false } }
        do {
            let boardRows = try await session.api.rows("boards", query: "select=id,organization_id,name,slug,is_global,is_read_only,staff_only_posting&\(identity.scopeQuery)&order=sort_order.asc,name.asc")
            guard current() else { return }
            guard boardID.isEmpty || boardRows.contains(where: { nativeText($0, "id") == boardID }) else { throw NativeAPIError.security("선택한 게시판의 접근 권한을 확인해 주세요.") }
            boards = boardRows; loadedIdentity = identity
            var parameters: [String: Any] = ["p_limit": 50, "p_offset": offset]
            if !boardID.isEmpty { parameters["p_board_id"] = boardID }
            guard let rows = try await session.api.rpc("list_community_posts", body: parameters) as? [[String: Any]] else { throw NativeAPIError.invalidData }
            guard current() else { return }
            hasMore = rows.count == 50
            if append {
                let existing = Set(posts.map { nativeText($0, "id") })
                posts.append(contentsOf: rows.filter { !existing.contains(nativeText($0, "id")) })
            } else { posts = rows }
        } catch {
            guard current() else { return }
            if !NativeBoardPolicy.mayRetainProtectedRows(after: error) {
                posts = []; boards = []; loadedIdentity = nil; hasMore = false
            }
            self.error = error.localizedDescription
        }
    }
}
