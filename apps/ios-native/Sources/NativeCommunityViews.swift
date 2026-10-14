import SwiftUI

func nativeText(_ row: [String: Any], _ key: String, fallback: String = "") -> String {
    row[key] as? String ?? fallback
}

struct NativeCommunityTabs: View {
    @EnvironmentObject private var session: NativeSession
    @State private var selectedTab = "feed"
    private var membership: [String: Any] { session.context["membership"] as? [String: Any] ?? [:] }
    private var isManager: Bool {
        session.context["is_platform_admin"] as? Bool == true || ["minister", "executive"].contains(nativeText(membership, "role"))
    }
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { NativeFeedView() }.tabItem { Label("소식", systemImage: "list.bullet.rectangle") }.tag("feed")
            NavigationStack { NativeChannelListView() }.tabItem { Label("채널", systemImage: "bubble.left.and.bubble.right") }.tag("channels")
            NavigationStack { NativeEventsView() }.tabItem { Label("일정", systemImage: "calendar") }.tag("events")
            if isManager {
                NavigationStack { NativeManagementView() }.tabItem { Label("관리", systemImage: "person.badge.shield.checkmark") }.tag("management")
            }
            NavigationStack { NativeProfileView() }.tabItem { Label("내 정보", systemImage: "person.crop.circle") }.tag("profile")
        }.onAppear { if isManager { selectedTab = "management" } }
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
    @EnvironmentObject private var session: NativeSession
    @State private var posts: [[String: Any]] = []
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        Group {
            if loading { ProgressView("소식을 불러오고 있습니다") }
            else if let error { NativeFailureView(message: error) { Task { await load() } } }
            else if posts.isEmpty { ContentUnavailableView("아직 등록된 소식이 없습니다", systemImage: "text.bubble") }
            else {
                List(posts.indices, id: \.self) { index in
                    let post = posts[index]
                    NavigationLink {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(nativeText(post, "title")).font(.title2.bold())
                                Text(nativeText(post, "author_label")).font(.subheadline).foregroundStyle(.secondary)
                                Text(nativeText(post, "body")).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding()
                        }.navigationTitle("게시글").navigationBarTitleDisplayMode(.inline)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            if post["is_pinned"] as? Bool == true { Label("공지", systemImage: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                            Text(nativeText(post, "title", fallback: "제목 없음")).font(.headline).lineLimit(3)
                            Text(nativeText(post, "body")).foregroundStyle(.secondary).lineLimit(2)
                            Text(nativeText(post, "author_label")).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }
                }.refreshable { await load() }
            }
        }.navigationTitle("공동체 소식").task { await load() }
    }
    private func load() async {
        loading = true; error = nil
        do { posts = try await session.api.rows("posts", query: "select=id,title,body,author_label,is_pinned,published_at&status=eq.published&order=is_pinned.desc,published_at.desc&limit=50") }
        catch { posts = []; self.error = "네트워크 연결이나 접근 권한을 확인해 주세요." }
        loading = false
    }
}

struct NativeChannelListView: View {
    @EnvironmentObject private var session: NativeSession
    @State private var channels: [[String: Any]] = []
    @State private var loading = true
    @State private var error: String?
    private var organizationID: String { nativeText(session.context["membership"] as? [String: Any] ?? [:], "organization_id") }
    var body: some View {
        Group {
            if loading { ProgressView("채널을 불러오고 있습니다") }
            else if let error { NativeFailureView(message: error) { Task { await load() } } }
            else if channels.isEmpty { ContentUnavailableView("참여할 채널이 없습니다", systemImage: "bubble.left.and.bubble.right", description: Text("교회 가입 승인 후 교회 채널을 확인할 수 있습니다.")) }
            else {
                List(channels.indices, id: \.self) { index in
                    let channel = channels[index]
                    NavigationLink { NativeChannelMessagesView(channel: channel, organizationID: organizationID) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(nativeText(channel, "name"), systemImage: nativeText(channel, "visibility") == "private" ? "lock" : "number")
                            Text(nativeText(channel, "description")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }.padding(.vertical, 6)
                    }.disabled(nativeText(channel, "status") != "active")
                }.refreshable { await load() }
            }
        }.navigationTitle("채널").task { await load() }
    }
    private func load() async {
        loading = true; error = nil
        guard !organizationID.isEmpty else { channels = []; loading = false; return }
        do {
            guard let snapshot = try await session.api.rpc("channel_snapshot", body: ["p_organization_id": organizationID]) as? [String: Any],
                  let channels = snapshot["channels"] as? [[String: Any]] else { throw NativeAPIError.invalidData }
            self.channels = channels
        } catch { channels = []; self.error = "교회 채널 조회에 실패했습니다. 권한과 네트워크를 확인해 주세요." }
        loading = false
    }
}

struct NativeChannelMessagesView: View {
    @EnvironmentObject private var session: NativeSession
    let channel: [String: Any]
    let organizationID: String
    @State private var messages: [[String: Any]] = []
    @State private var draft = ""
    @State private var error: String?
    @State private var loading = true
    @State private var sending = false
    @State private var operationID = UUID().uuidString
    private var channelID: String { nativeText(channel, "id") }
    var body: some View {
        VStack(spacing: 0) {
            if loading { ProgressView("대화를 불러오고 있습니다").padding() }
            if let error { Text(error).foregroundStyle(.red).padding().accessibilityAddTraits(.isStaticText) }
            List {
                if !loading && messages.isEmpty { Text("아직 대화가 없습니다.").foregroundStyle(.secondary) }
                ForEach(messages.indices, id: \.self) { index in
                    let message = messages[index]
                    VStack(alignment: .leading, spacing: 6) {
                        Text(nativeText(message, "senderName", fallback: "교회 회원")).font(.subheadline.bold())
                        Text(nativeText(message, "body")).textSelection(.enabled)
                    }.padding(.vertical, 6)
                }
            }.refreshable { await load() }
        }.safeAreaInset(edge: .bottom) {
            HStack(alignment: .bottom) {
                TextField("메시지", text: $draft, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder).disabled(sending)
                Button { Task { await send() } } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .accessibilityLabel("메시지 보내기").frame(minWidth: 44, minHeight: 44)
                    .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 4000 || channel["archived"] as? Bool == true)
            }.padding().background(.bar)
        }.navigationTitle(nativeText(channel, "name", fallback: "채널"))
            .navigationBarTitleDisplayMode(.inline).task { await load() }
            .onChange(of: draft) { _, _ in if !sending { operationID = UUID().uuidString } }
    }
    private func load() async {
        loading = true
        do {
            guard let snapshot = try await session.api.rpc("channel_snapshot", body: ["p_organization_id": organizationID, "p_channel_id": channelID]) as? [String: Any],
                  let messages = snapshot["messages"] as? [[String: Any]] else { throw NativeAPIError.invalidData }
            self.messages = messages; error = nil
        } catch { messages = []; self.error = "대화를 불러오지 못했습니다. 아래로 당겨 다시 시도해 주세요." }
        loading = false
    }
    private func send() async {
        guard !sending else { return }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.count <= 4000 else { return }
        sending = true
        do {
            _ = try await session.api.rpc("channel_command", body: ["p_action": "send", "p_channel_id": channelID, "p_payload": ["messageId": operationID, "body": body]])
            draft = ""; operationID = UUID().uuidString; await load()
        } catch { self.error = "전송 결과를 확인하지 못했습니다. 같은 내용으로 재시도하면 중복 전송을 방지합니다." }
        sending = false
    }
}

struct NativeEventsView: View {
    @EnvironmentObject private var session: NativeSession
    @State private var events: [[String: Any]] = []
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        Group {
            if loading { ProgressView("일정을 불러오고 있습니다") }
            else if let error { NativeFailureView(message: error) { Task { await load() } } }
            else if events.isEmpty { ContentUnavailableView("예정된 일정이 없습니다", systemImage: "calendar") }
            else {
                List(events.indices, id: \.self) { index in
                    let event = events[index]
                    VStack(alignment: .leading, spacing: 8) {
                        Text(nativeText(event, "title")).font(.headline)
                        Text(nativeText(event, "starts_at")).font(.subheadline).foregroundStyle(.secondary)
                        Text(nativeText(event, "location_text")).foregroundStyle(.secondary)
                        Text(nativeText(event, "description")).lineLimit(5)
                    }.padding(.vertical, 6)
                }.refreshable { await load() }
            }
        }.navigationTitle("공동체 일정").task { await load() }
    }
    private func load() async {
        loading = true; error = nil
        let formatter = ISO8601DateFormatter()
        do {
            guard let events = try await session.api.rpc("list_event_occurrences", body: ["p_from": formatter.string(from: Date()), "p_to": formatter.string(from: Date().addingTimeInterval(90 * 86400)), "p_limit": 100]) as? [[String: Any]] else { throw NativeAPIError.invalidData }
            self.events = events
        }
        catch { events = []; self.error = "일정 조회에 실패했습니다. 다시 시도해 주세요." }
        loading = false
    }
}

struct NativeManagementView: View {
    @EnvironmentObject private var session: NativeSession
    @State private var applications: [[String: Any]] = []
    @State private var error: String?
    @State private var loading = true
    private var role: String { nativeText(session.context["membership"] as? [String: Any] ?? [:], "role") }
    private var title: String { session.context["is_platform_admin"] as? Bool == true ? "플랫폼 관리" : role == "minister" ? "사역자 관리" : "임원 운영" }
    var body: some View {
        List {
            Section {
                Text("가입 승인 대기 현황").font(.headline)
                Text("권한은 서버에서 확인합니다. 네이티브 승인·임명 기능은 아직 제공하지 않으며 이 화면에서는 조회만 가능합니다.").font(.footnote).foregroundStyle(.secondary)
            }
            if loading { ProgressView("신청을 확인하고 있습니다") }
            if let error { Text(error).foregroundStyle(.red) }
            if !loading && error == nil && applications.isEmpty { Text("대기 중인 신청이 없습니다.").foregroundStyle(.secondary) }
            ForEach(applications.indices, id: \.self) { index in
                let application = applications[index]
                VStack(alignment: .leading, spacing: 6) {
                    Text(nativeText(application, "requested_role")).font(.headline)
                    Text(nativeText(application, "applicant_note", fallback: "신청 메모 없음")).foregroundStyle(.secondary)
                    Text(nativeText(application, "created_at")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle(title).task { await load() }.refreshable { await load() }
    }
    private func load() async {
        loading = true; error = nil
        do { applications = try await session.api.rows("membership_applications", query: "select=id,requested_role,applicant_note,created_at&status=eq.pending&order=created_at.desc&limit=100") }
        catch { applications = []; self.error = "신청 조회 권한이나 네트워크를 확인해 주세요." }
        loading = false
    }
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
            Section("앱 기능 안내") {
                Text("소식·채널 대화·일정·관리 현황은 실제 서버 데이터로 표시됩니다.")
                Text("사진·동영상 업로드, 고급 채널 기능, 계정 삭제 및 임원 기록 편집은 네이티브 전환 작업 중입니다.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("계정 다시 확인") { Task { await session.restore() } }
                Button("로그아웃", role: .destructive) { Task { await session.signOut() } }
            }
        }.navigationTitle("내 정보")
    }
}
