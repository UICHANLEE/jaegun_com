import SwiftUI

enum NativeCollaborationPolicy {
    static func channelInput(name: String, description: String, visibility: String) -> Bool {
        let length = name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
        return (2...60).contains(length) && description.unicodeScalars.count <= 500 && ["public", "private"].contains(visibility)
    }
    static func textInput(_ body: String) -> Bool {
        let value = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.unicodeScalars.count <= 4000
    }
    static func responseLabel(_ code: String) -> String {
        ["yes": "참석", "maybe": "미정", "no": "불참", "waitlist": "대기" ][code] ?? "미응답"
    }
}

/// Identity is only a stale-response guard. Backend current-consent and scope checks remain authoritative.
@MainActor private func collaborationIdentity(_ session: NativeSession) -> String {
    guard session.signedIn, !session.consentRequired else { return "" }
    let member = session.context["membership"] as? [String: Any] ?? [:]
    guard nativeText(member, "status") == "active" else { return "" }
    let actor = nativeText(session.context["profile"] as? [String: Any] ?? [:], "id")
    let organization = nativeText(member, "organization_id")
    guard UUID(uuidString: actor) != nil, UUID(uuidString: organization) != nil else { return "" }
    return "\(session.sessionGeneration):\(actor):\(organization)"
}

struct NativeCommunityChatHubView: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var channels: [[String: Any]] = []
    @State private var conversations: [[String: Any]] = []
    @State private var loading = false
    @State private var error: String?
    @State private var creating = false
    @State private var starting = false
    @State private var joining: String?
    @State private var generation = UUID()
    @State private var loadedIdentity = ""
    private var identity: String { collaborationIdentity(session) }
    private var organizationID: String { nativeText(session.context["membership"] as? [String: Any] ?? [:], "organization_id") }
    private var actorID: String { nativeText(session.context["profile"] as? [String: Any] ?? [:], "id") }
    var body: some View {
        List {
            Section {
                Button { creating = true } label: { Label("채널·소모임 만들기", systemImage: "plus.circle") }.frame(minHeight: 44).disabled(identity.isEmpty)
                Button { starting = true } label: { Label("1:1 대화 시작", systemImage: "square.and.pencil") }.frame(minHeight: 44).disabled(identity.isEmpty)
            }
            if loading { ProgressView("대화를 불러오고 있습니다") }
            if let error { Text(error).foregroundStyle(.red); Button("다시 불러오기") { Task { await load() } }.frame(minHeight: 44) }
            Section("교회 채널·소모임") {
                if !loading && channels.isEmpty { Text("아직 채널이 없습니다. 교회 회원 누구나 만들 수 있습니다.").foregroundStyle(.secondary) }
                ForEach((loadedIdentity == identity ? channels : []).indices, id: \.self) { index in
                    let channel = channels[index]
                    if nativeText(channel, "status") == "active" {
                        NavigationLink { NativeCollaborationChannelMessagesView(channel: channel, organizationID: organizationID) } label: { channelLabel(channel) }
                    } else {
                        Button { Task { await join(channel) } } label: {
                            HStack { channelLabel(channel); Spacer(); Text(nativeText(channel, "status") == "invited" ? "초대 수락" : "참여").font(.caption.bold()) }
                        }.disabled(joining != nil || channel["archived"] as? Bool == true).frame(minHeight: 44)
                    }
                }
            }
            Section("1:1 대화") {
                if !loading && conversations.isEmpty { Text("아직 개인 대화가 없습니다.").foregroundStyle(.secondary) }
                ForEach((loadedIdentity == identity ? conversations : []).indices, id: \.self) { index in
                    let row = conversations[index]
                    let participants = row["participants"] as? [[String: Any]] ?? []
                    let other = participants.first { nativeText($0, "id").lowercased() != actorID.lowercased() } ?? [:]
                    NavigationLink { NativeDirectConversationView(conversationID: nativeText(row, "id"), title: nativeText(other, "display_name", fallback: "교회 회원")) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(nativeText(other, "display_name", fallback: "교회 회원")).font(.headline)
                            Text(nativeText(row["last_message"] as? [String: Any] ?? [:], "body", fallback: "대화를 시작해 보세요")).lineLimit(2).font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }
                }
            }
            Text("사진·영상 전송과 실시간 갱신은 준비 중입니다. 현재 텍스트 대화를 지원하며 아래로 당겨 새로 확인할 수 있습니다.").font(.footnote).foregroundStyle(.secondary)
        }.listStyle(.plain).navigationTitle("채팅").nativePageStyle().refreshable { await load() }
            .task(id: identity) { clear(); await load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { generation = UUID(); loadedIdentity = ""; channels = []; conversations = [] }
                if phase == .active { Task { await load() } }
            }
            .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) { NavigationStack { NativeChannelCreationView() }.environmentObject(session) }
            .sheet(isPresented: $starting, onDismiss: { Task { await load() } }) { NavigationStack { NativeDirectMemberPicker() }.environmentObject(session) }
    }
    private func channelLabel(_ channel: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(nativeText(channel, "name"), systemImage: nativeText(channel, "visibility") == "private" ? "lock" : "number").font(.headline)
            if channel["archived"] as? Bool == true { Text("보관된 채널").font(.caption).foregroundStyle(.secondary) }
            Text(nativeText(channel, "description")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }.padding(.vertical, 6)
    }
    private func clear() { generation = UUID(); loadedIdentity = ""; channels = []; conversations = []; error = nil; joining = nil; creating = false; starting = false }
    private func load() async {
        let actor = identity; let loadID = UUID(); generation = loadID
        guard scenePhase != .background else { return }
        guard !actor.isEmpty else { channels = []; conversations = []; loading = false; return }
        loading = true
        do {
            let value = try await session.api.rpc("channel_snapshot", body: ["p_organization_id": organizationID])
            guard identity == actor, generation == loadID, !Task.isCancelled else { return }
            guard let snapshot = value as? [String: Any], nativeText(snapshot, "actorId").lowercased() == actorID.lowercased(), let rows = snapshot["channels"] as? [[String: Any]] else { throw NativeAPIError.invalidData }
            let inbox = try await session.api.rpc("get_conversation_summaries")
            guard identity == actor, generation == loadID, !Task.isCancelled else { return }
            guard let summaries = inbox as? [[String: Any]] else { throw NativeAPIError.invalidData }
            channels = rows; conversations = summaries.filter { nativeText($0, "organization_id").lowercased() == organizationID.lowercased() }; loadedIdentity = actor; error = nil
        } catch { guard identity == actor, generation == loadID else { return }; channels = []; conversations = []; self.error = error.localizedDescription }
        if identity == actor, generation == loadID { loading = false }
    }
    private func join(_ channel: [String: Any]) async {
        let actor = identity; guard !actor.isEmpty, joining == nil else { return }
        joining = nativeText(channel, "id")
        do { _ = try await session.api.rpc("channel_command", body: ["p_action": "join", "p_channel_id": nativeText(channel, "id"), "p_payload": ["expectedActorId": actorID]])
            guard identity == actor else { return }; await load()
        } catch { guard identity == actor else { return }; self.error = "참여 결과를 확인하지 못했습니다. 다시 불러온 뒤 상태를 확인해 주세요." }
        if identity == actor { joining = nil }
    }
}

private struct NativeChannelCreationView: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var visibility = "public"
    @State private var channelID = UUID().uuidString
    @State private var frozenPayload: [String: Any]?
    @State private var saving = false
    @State private var error: String?
    private var identity: String { collaborationIdentity(session) }
    var body: some View {
        Form {
            Section("채널 정보") {
                TextField("이름 (2~60자)", text: $name)
                TextField("설명 (선택, 500자 이내)", text: $description, axis: .vertical).lineLimit(3...6)
                Picker("공개 범위", selection: $visibility) { Text("교회 회원 공개").tag("public"); Text("초대받은 회원만").tag("private") }
            }.disabled(saving || frozenPayload != nil)
            Text("채널 생성은 교회 임원이나 관리자 권한을 부여하지 않습니다. 비공개 채널의 회원 초대·관리는 현재 웹에서 지원합니다.").font(.footnote).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            Button(frozenPayload == nil ? "채널 만들기" : "같은 생성 요청 확인") { Task { await save() } }.frame(minHeight: 44).disabled(saving || identity.isEmpty || !NativeCollaborationPolicy.channelInput(name: name, description: description, visibility: visibility))
        }.navigationTitle("채널·소모임 만들기").toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() }.disabled(saving) } }
            .onChange(of: identity) { _, _ in name = ""; description = ""; frozenPayload = nil; dismiss() }
            .interactiveDismissDisabled(saving || frozenPayload != nil)
    }
    private func save() async {
        let actor = identity; guard !actor.isEmpty, !saving else { return }
        saving = true
        let member = session.context["membership"] as? [String: Any] ?? [:]
        let profile = session.context["profile"] as? [String: Any] ?? [:]
        let payload = frozenPayload ?? ["organizationId": nativeText(member, "organization_id"), "expectedActorId": nativeText(profile, "id"), "name": name.trimmingCharacters(in: .whitespacesAndNewlines), "description": description, "visibility": visibility]
        frozenPayload = payload
        do {
            let result = try await session.api.rpc("channel_command", body: ["p_action": "create", "p_channel_id": channelID, "p_payload": payload])
            guard identity == actor else { return }
            guard let row = result as? [String: Any], nativeText(row, "id").lowercased() == channelID.lowercased() else { throw NativeAPIError.invalidData }
            frozenPayload = nil; dismiss()
        } catch { guard identity == actor else { return }; self.error = "생성 결과를 확인하지 못했습니다. 입력 내용은 고정됩니다. 같은 요청을 확인하면 중복 생성을 방지합니다.\n\(error.localizedDescription)" }
        if identity == actor { saving = false }
    }
}

private struct NativeDirectMemberPicker: View {
    @EnvironmentObject private var session: NativeSession
    @State private var members: [[String: Any]] = []
    @State private var query = ""
    @State private var error: String?
    @State private var loading = true
    @State private var saving = false
    @State private var destination: String?
    @State private var selectedName = ""
    @State private var generation = UUID()
    @State private var loadedIdentity = ""
    private var identity: String { collaborationIdentity(session) }
    var body: some View {
        let filtered = loadedIdentity == identity ? members.filter { query.isEmpty || nativeText($0, "display_name").localizedCaseInsensitiveContains(query) } : []
        List {
            if loading { ProgressView("교회 회원 확인 중") }
            if let error { Text(error).foregroundStyle(.red); Button("다시 확인") { Task { await load() } }.frame(minHeight: 44) }
            ForEach(filtered.indices, id: \.self) { index in
                Button(nativeText(filtered[index], "display_name", fallback: "교회 회원")) { Task { await start(filtered[index]) } }.frame(minHeight: 44).disabled(saving)
            }
            if !loading && members.isEmpty { Text("대화를 시작할 교회 회원이 없습니다.").foregroundStyle(.secondary) }
        }.navigationTitle("1:1 대화 시작").searchable(text: $query, prompt: "이름 검색")
            .task(id: identity) { members = []; loadedIdentity = ""; destination = nil; await load() }
            .navigationDestination(isPresented: Binding(get: { destination != nil }, set: { if !$0 { destination = nil } })) { if let destination { NativeDirectConversationView(conversationID: destination, title: selectedName) } }
    }
    private func load() async {
        let actor = identity; let request = UUID(); generation = request
        guard !actor.isEmpty else { members = []; loading = false; return }; loading = true
        let organization = nativeText(session.context["membership"] as? [String: Any] ?? [:], "organization_id")
        let ownID = nativeText(session.context["profile"] as? [String: Any] ?? [:], "id")
        do {
            var ids: [String] = []
            for offset in stride(from: 0, to: 10000, by: 100) {
                let value = try await session.api.rpc("list_visible_organization_memberships", body: ["p_organization_id": organization, "p_limit": 100, "p_offset": offset])
                guard identity == actor, generation == request, !Task.isCancelled else { return }
                guard let rows = value as? [[String: Any]] else { throw NativeAPIError.invalidData }
                ids += rows.filter { nativeText($0, "status") == "active" && nativeText($0, "organization_id").lowercased() == organization.lowercased() }.map { nativeText($0, "user_id") }.filter { UUID(uuidString: $0) != nil && $0.lowercased() != ownID.lowercased() }
                if rows.count < 100 { break }
            }
            var profiles: [[String: Any]] = []
            ids = Array(Set(ids))
            for offset in stride(from: 0, to: ids.count, by: 100) {
                let value = try await session.api.rpc("list_visible_profiles", body: ["p_profile_ids": Array(ids[offset..<min(offset + 100, ids.count)])])
                guard identity == actor, generation == request, !Task.isCancelled else { return }
                guard let rows = value as? [[String: Any]] else { throw NativeAPIError.invalidData }; profiles += rows
            }
            members = profiles.sorted { nativeText($0, "display_name") < nativeText($1, "display_name") }; loadedIdentity = actor; error = nil
        } catch { guard identity == actor, generation == request else { return }; members = []; self.error = error.localizedDescription }
        if identity == actor, generation == request { loading = false }
    }
    private func start(_ profile: [String: Any]) async {
        let actor = identity; guard !actor.isEmpty, !saving else { return }; saving = true
        do { let value = try await session.api.rpc("get_or_create_conversation", body: ["p_other_user_id": nativeText(profile, "id")])
            guard identity == actor else { return }; guard let id = value as? String, UUID(uuidString: id) != nil else { throw NativeAPIError.invalidData }
            selectedName = nativeText(profile, "display_name", fallback: "교회 회원"); destination = id
        } catch { guard identity == actor else { return }; self.error = error.localizedDescription }
        if identity == actor { saving = false }
    }
}

struct NativeDirectConversationView: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.scenePhase) private var scenePhase
    let conversationID: String
    let title: String
    @State private var messages: [[String: Any]] = []
    @State private var draft = ""
    @State private var frozenBody: String?
    @State private var nonce = UUID().uuidString
    @State private var loading = true
    @State private var sending = false
    @State private var error: String?
    @State private var generation = UUID()
    @State private var loadedIdentity = ""
    private var identity: String { collaborationIdentity(session) }
    private var actorID: String { nativeText(session.context["profile"] as? [String: Any] ?? [:], "id") }
    var body: some View {
        VStack(spacing: 0) {
            if loading { ProgressView("대화 확인 중").padding() }
            if let error { Text(error).font(.footnote).foregroundStyle(.red).padding() }
            List {
                if !loading && messages.isEmpty { Text("아직 메시지가 없습니다.").foregroundStyle(.secondary) }
                ForEach((loadedIdentity == identity ? messages : []).indices, id: \.self) { index in
                    let row = messages[index]
                    VStack(alignment: .leading, spacing: 6) {
                        Text(nativeText(row, "sender_id").lowercased() == actorID.lowercased() ? "나" : title).font(.subheadline.bold())
                        if nativeText(row, "kind") == "text" { Text(nativeText(row, "body")).textSelection(.enabled) }
                        else { Text("사진·영상 메시지 (웹에서 확인)").foregroundStyle(.secondary) }
                        Text(nativeText(row, "created_at")).font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
            }.listStyle(.plain).refreshable { await load() }
        }.safeAreaInset(edge: .bottom) {
            HStack {
                TextField("메시지", text: $draft, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder).disabled(sending || frozenBody != nil)
                Button(frozenBody == nil ? "전송" : "결과 확인") { Task { await send() } }.frame(minWidth: 44, minHeight: 44).disabled(sending || identity.isEmpty || !NativeCollaborationPolicy.textInput(draft))
            }.padding().background(.bar)
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .task(id: identity) { generation = UUID(); messages = []; loadedIdentity = ""; draft = ""; frozenBody = nil; nonce = UUID().uuidString; await load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { generation = UUID(); loadedIdentity = ""; messages = [] }
                if phase == .active { Task { await load() } }
            }
    }
    private func load() async {
        let actor = identity; let request = UUID(); generation = request
        guard scenePhase != .background else { return }
        guard !actor.isEmpty else { messages = []; loading = false; return }; loading = true
        do {
            let rows = try await session.api.rows("messages", query: "select=id,sender_id,kind,body,client_nonce,created_at&conversation_id=eq.\(conversationID)&deleted_at=is.null&order=created_at.desc&limit=100")
            guard identity == actor, generation == request, !Task.isCancelled else { return }
            messages = rows.reversed(); loadedIdentity = actor; error = nil
            if frozenBody != nil, rows.contains(where: { nativeText($0, "client_nonce").lowercased() == nonce.lowercased() && nativeText($0, "sender_id").lowercased() == actorID.lowercased() }) { frozenBody = nil; draft = ""; nonce = UUID().uuidString }
        } catch { guard identity == actor, generation == request else { return }; messages = []; self.error = error.localizedDescription }
        if identity == actor, generation == request { loading = false }
    }
    private func send() async {
        let actor = identity; guard !actor.isEmpty, !sending, NativeCollaborationPolicy.textInput(draft) else { return }; sending = true
        let body = frozenBody ?? draft.trimmingCharacters(in: .whitespacesAndNewlines); frozenBody = body
        do {
            _ = try await session.api.rpc("send_message_batch", body: ["p_conversation_id": conversationID, "p_expected_sender_id": actorID, "p_messages": [["kind": "text", "body": body, "media_path": NSNull(), "media_metadata": [String: Any](), "client_nonce": nonce]]])
            guard identity == actor else { return }; frozenBody = nil; draft = ""; nonce = UUID().uuidString; await load()
        } catch { guard identity == actor else { return }; self.error = "전송 결과를 확인하지 못했습니다. 같은 요청으로 다시 확인하면 중복 전송을 방지합니다. 아래로 당겨 서버 메시지를 확인할 수도 있습니다." }
        if identity == actor { sending = false }
    }
}

struct NativeGatheringRSVPView: View {
    @EnvironmentObject private var session: NativeSession
    let occurrence: [String: Any]
    @State private var response: String?
    @State private var waitlistPosition: Int?
    @State private var operationID = UUID().uuidString
    @State private var pendingResponse: String?
    @State private var saving = false
    @State private var error: String?
    private var identity: String { collaborationIdentity(session) }
    private var occurrenceID: String { nativeText(occurrence, "occurrence_id", fallback: nativeText(occurrence, "id")) }
    var body: some View {
        Form {
            Section("일정·모임") {
                Text(nativeText(occurrence, "title")).font(.headline)
                Text(nativeText(occurrence, "starts_at")).foregroundStyle(.secondary)
                Text(nativeText(occurrence, "location_text")).foregroundStyle(.secondary)
                Text(nativeText(occurrence, "description"))
            }
            Section("나의 참석 응답") {
                Text(NativeCollaborationPolicy.responseLabel(response ?? nativeText(occurrence, "own_response")))
                if let position = waitlistPosition { Text("대기 순서: \(position)").foregroundStyle(.secondary) }
                Text("정원이 찬 경우 참석 요청은 대기로 전환될 수 있습니다.").font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
                if let pendingResponse {
                    Button("같은 참석 응답 결과 확인") { Task { await respond(pendingResponse) } }.frame(minHeight: 44).disabled(saving || identity.isEmpty)
                } else {
                    ForEach(["yes", "maybe", "no"], id: \.self) { code in
                        Button(NativeCollaborationPolicy.responseLabel(code)) { Task { await respond(code) } }.frame(minHeight: 44).disabled(saving || identity.isEmpty || nativeText(occurrence, "event_status") == "cancelled" || nativeText(occurrence, "occurrence_status") == "cancelled")
                    }
                }
            }
        }.navigationTitle("참석 응답").navigationBarTitleDisplayMode(.inline)
            .onAppear { waitlistPosition = (occurrence["waitlist_position"] as? NSNumber)?.intValue }
            .onChange(of: identity) { _, _ in response = nil; waitlistPosition = nil; pendingResponse = nil; operationID = UUID().uuidString; error = nil }
    }
    private func respond(_ code: String) async {
        let actor = identity; guard !actor.isEmpty, !saving, UUID(uuidString: occurrenceID) != nil, ["yes", "maybe", "no"].contains(code) else { return }
        saving = true; pendingResponse = code
        do {
            let value = try await session.api.rpc("respond_to_event", body: ["p_occurrence_id": occurrenceID, "p_response": code, "p_client_operation_id": operationID])
            guard identity == actor else { return }
            guard let row = value as? [String: Any], nativeText(row, "occurrence_id").lowercased() == occurrenceID.lowercased(), ["yes", "maybe", "no", "waitlist"].contains(nativeText(row, "response")) else { throw NativeAPIError.invalidData }
            response = nativeText(row, "response"); waitlistPosition = (row["waitlist_position"] as? NSNumber)?.intValue; pendingResponse = nil; operationID = UUID().uuidString; error = nil
        } catch { guard identity == actor else { return }; self.error = "참석 응답 결과를 확인하지 못했습니다. 같은 요청을 확인하면 중복 응답을 방지합니다.\n\(error.localizedDescription)" }
        if identity == actor { saving = false }
    }
}

private struct NativeCollaborationChannelMessagesView: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.scenePhase) private var scenePhase
    let channel: [String: Any]
    let organizationID: String
    @State private var messages: [[String: Any]] = []
    @State private var draft = ""
    @State private var frozenBody: String?
    @State private var messageID = UUID().uuidString
    @State private var loading = true
    @State private var sending = false
    @State private var error: String?
    @State private var generation = UUID()
    @State private var loadedIdentity = ""
    private var identity: String { collaborationIdentity(session) }
    private var actorID: String { nativeText(session.context["profile"] as? [String: Any] ?? [:], "id") }
    private var channelID: String { nativeText(channel, "id") }
    var body: some View {
        VStack(spacing: 0) {
            if loading { ProgressView("대화 확인 중").padding() }
            if let error { Text(error).font(.footnote).foregroundStyle(.red).padding() }
            List {
                if !loading && messages.isEmpty { Text("아직 대화가 없습니다.").foregroundStyle(.secondary) }
                if loadedIdentity == identity && !identity.isEmpty {
                    ForEach(messages.indices, id: \.self) { index in
                        let message = messages[index]
                        VStack(alignment: .leading, spacing: 6) {
                            Text(nativeText(message, "senderName", fallback: "교회 회원")).font(.subheadline.bold())
                            Text(nativeText(message, "body")).textSelection(.enabled)
                        }.padding(.vertical, 6)
                    }
                }
            }.listStyle(.plain).refreshable { await load() }
        }.safeAreaInset(edge: .bottom) {
            HStack {
                TextField("메시지", text: $draft, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder).disabled(sending || frozenBody != nil)
                Button(frozenBody == nil ? "전송" : "결과 확인") { Task { await send() } }.frame(minWidth: 44, minHeight: 44)
                    .disabled(sending || identity.isEmpty || !NativeCollaborationPolicy.textInput(draft) || channel["archived"] as? Bool == true)
            }.padding().background(.bar)
        }.navigationTitle(nativeText(channel, "name", fallback: "채널")).navigationBarTitleDisplayMode(.inline)
            .task(id: identity) { generation = UUID(); messages = []; loadedIdentity = ""; draft = ""; frozenBody = nil; messageID = UUID().uuidString; await load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { generation = UUID(); loadedIdentity = ""; messages = [] }
                if phase == .active { Task { await load() } }
            }
    }
    private func load() async {
        let actor = identity; let request = UUID(); generation = request
        guard scenePhase != .background else { return }
        guard !actor.isEmpty else { messages = []; loading = false; return }; loading = true
        do {
            let value = try await session.api.rpc("channel_snapshot", body: ["p_organization_id": organizationID, "p_channel_id": channelID])
            guard identity == actor, generation == request, !Task.isCancelled else { return }
            guard let snapshot = value as? [String: Any], nativeText(snapshot, "actorId").lowercased() == actorID.lowercased(), let rows = snapshot["messages"] as? [[String: Any]] else { throw NativeAPIError.invalidData }
            messages = rows; loadedIdentity = actor; error = nil
            if frozenBody != nil, rows.contains(where: { nativeText($0, "id").lowercased() == messageID.lowercased() && nativeText($0, "senderId").lowercased() == actorID.lowercased() }) { frozenBody = nil; draft = ""; messageID = UUID().uuidString }
        } catch { guard identity == actor, generation == request else { return }; messages = []; loadedIdentity = ""; self.error = error.localizedDescription }
        if identity == actor, generation == request { loading = false }
    }
    private func send() async {
        let actor = identity; guard !actor.isEmpty, !sending, NativeCollaborationPolicy.textInput(draft) else { return }; sending = true
        let body = frozenBody ?? draft.trimmingCharacters(in: .whitespacesAndNewlines); frozenBody = body
        do {
            _ = try await session.api.rpc("channel_command", body: ["p_action": "send", "p_channel_id": channelID, "p_payload": ["expectedActorId": actorID, "messageId": messageID, "body": body]])
            guard identity == actor else { return }; frozenBody = nil; draft = ""; messageID = UUID().uuidString; await load()
        } catch { guard identity == actor else { return }; self.error = "전송 결과를 확인하지 못했습니다. 같은 요청으로 다시 확인하면 중복 전송을 방지합니다." }
        if identity == actor { sending = false }
    }
}
