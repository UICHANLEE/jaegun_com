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
@MainActor func collaborationIdentity(_ session: NativeSession) -> String {
    guard session.signedIn, !session.consentRequired else { return "" }
    let member = session.context["membership"] as? [String: Any] ?? [:]
    guard nativeText(member, "status") == "active" else { return "" }
    let actor = nativeText(session.context["profile"] as? [String: Any] ?? [:], "id")
    let organization = nativeText(member, "organization_id")
    guard UUID(uuidString: actor) != nil, UUID(uuidString: organization) != nil else { return "" }
    return "\(session.sessionGeneration):\(actor):\(organization)"
}

private enum NativeChatSection: String, CaseIterable {
    case channels = "채널·소모임"
    case direct = "1:1 대화"
}

private enum NativeChatDestination {
    case channel([String: Any], organization: String, identity: String)
    case direct(String, title: String, identity: String)
}

struct NativeCommunityChatHubView: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.nativeTabActive) private var tabActive
    @State private var channels: [[String: Any]] = []
    @State private var conversations: [[String: Any]] = []
    @State private var section = NativeChatSection.channels
    @State private var loading = false
    @State private var error: String?
    @State private var creating = false
    @State private var starting = false
    @State private var joining: String?
    @State private var declinedInvitations: [String:String] = [:]
    @State private var reads = NativeChatReadGate()
    @State private var loadedIdentity = ""
    @State private var boundIdentity = ""
    @State private var destination: NativeChatDestination?
    @State private var pendingDestination: NativeChatDestination?
    @StateObject private var channelDraft = NativeChatChannelDraft()
    @StateObject private var realtime = NativeChatRealtime()
    private var identity: String { collaborationIdentity(session) }
    private var organizationID: String { nativeText(session.context["membership"] as? [String: Any] ?? [:], "organization_id") }
    private var actorID: String { nativeText(session.context["profile"] as? [String: Any] ?? [:], "id") }
    var body: some View {
        List {
            Section {
                Picker("대화 종류", selection: $section) {
                    ForEach(NativeChatSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Button { if section == .channels { creating = true } else { starting = true } } label: {
                    Label(section == .channels ? (channelDraft.frozenPayload == nil ? "채널·소모임 만들기" : "채널 생성 결과 확인") : "1:1 대화 시작", systemImage: "square.and.pencil")
                }.frame(minHeight: 44).disabled(identity.isEmpty)
            }
            if loading { ProgressView("대화를 불러오고 있습니다") }
            if let error { Text(error).foregroundStyle(.red); Button("다시 불러오기") { Task { await load() } }.frame(minHeight: 44).disabled(loading) }
            if section == .channels {
                Section("교회 채널·소모임") {
                    if !loading && channels.isEmpty { Text("아직 채널이 없습니다. 교회 회원 누구나 만들 수 있습니다.").foregroundStyle(.secondary) }
                    ForEach((loadedIdentity == identity ? channels : []).indices, id: \.self) { index in
                        let channel = channels[index]
                        if nativeText(channel, "status") == "active" {
                            Button { destination = .channel(channel, organization: organizationID, identity: identity) } label: { channelLabel(channel) }.foregroundStyle(.primary)
                        } else {
                            Button { Task { await join(channel) } } label: {
                                HStack { channelLabel(channel); Spacer(); Text(nativeText(channel, "status") == "invited" ? "초대 수락" : "참여").font(.caption.bold()) }
                            }.disabled(joining != nil || channel["archived"] as? Bool == true).frame(minHeight: 44)
                            if nativeText(channel,"status") == "invited" {
                                Button("초대 거절",role:.destructive) { Task { await decline(channel) } }.frame(minHeight:44).disabled(joining != nil)
                            }
                        }
                    }
                }
            } else {
                Section("1:1 대화") {
                    if !loading && conversations.isEmpty { Text("아직 개인 대화가 없습니다. 위에서 교회 회원을 선택해 대화를 시작하세요.").foregroundStyle(.secondary) }
                    ForEach((loadedIdentity == identity ? conversations : []).indices, id: \.self) { index in
                        let row = conversations[index]
                        let participants = row["participants"] as? [[String: Any]] ?? []
                        let other = participants.first { nativeText($0, "id").lowercased() != actorID.lowercased() } ?? [:]
                        Button { destination = .direct(nativeText(row, "id"), title: nativeText(other, "display_name", fallback: "교회 회원"), identity: identity) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(nativeText(other, "display_name", fallback: "교회 회원")).font(.headline)
                                Text(nativeText(row["last_message"] as? [String: Any] ?? [:], "body", fallback: "대화를 시작해 보세요")).lineLimit(2).font(.subheadline).foregroundStyle(.secondary)
                            }.padding(.vertical, 6)
                        }.foregroundStyle(.primary)
                    }
                }
            }
            Text(realtime.status).font(.footnote).foregroundStyle(.secondary)
        }.listStyle(.plain).navigationTitle("채팅").nativePageStyle().refreshable { await load(); connect() }
            .task(id: "\(identity):\(scenePhase == .active):\(tabActive)") {
                if boundIdentity != identity { clear(); boundIdentity = identity }
                guard tabActive, scenePhase == .active else { realtime.stop(); return }
                await load(); connect()
            }
            .onDisappear { reads.invalidate(); loading = false; realtime.stop() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { realtime.stop(); reads.invalidate(); loadedIdentity = ""; channels = []; conversations = []; loading = false }
            }
            .sheet(isPresented: $creating, onDismiss: finishSheet) {
                NavigationStack {
                    NativeChannelCreationView(draft: channelDraft) { row, actor in
                        guard identity == actor else { return }
                        pendingDestination = .channel(row, organization: organizationID, identity: actor)
                        creating = false
                    }
                }.environmentObject(session)
            }
            .sheet(isPresented: $starting, onDismiss: finishSheet) {
                NavigationStack {
                    NativeDirectMemberPicker { id, title, actor in
                        guard identity == actor else { return }
                        pendingDestination = .direct(id, title: title, identity: actor)
                        starting = false
                    }
                }.environmentObject(session)
            }
            .navigationDestination(isPresented: Binding(get: { destination != nil }, set: { if !$0 { destination = nil } })) {
                switch destination {
                case .channel(let row, let organization, let actor):
                    if identity == actor { NativeCollaborationChannelMessagesView(channel: row, organizationID: organization, accessIdentity: actor) }
                case .direct(let id, let title, let actor):
                    if identity == actor { NativeDirectConversationView(conversationID: id, title: title, accessIdentity: actor) }
                case nil: EmptyView()
                }
            }
    }
    private func channelLabel(_ channel: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(nativeText(channel, "name"), systemImage: nativeText(channel, "visibility") == "private" ? "lock" : "number").font(.headline)
            if channel["archived"] as? Bool == true { Text("보관된 채널").font(.caption).foregroundStyle(.secondary) }
            Text(nativeText(channel, "description")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }.padding(.vertical, 6)
    }
    private func connect() {
        let actor = identity
        guard tabActive, !actor.isEmpty, scenePhase == .active else { realtime.stop(); return }
        realtime.start(session: session, changes: [
            NativeRealtimeChange(table: "channel_change_events", filter: nil),
            NativeRealtimeChange(table: "messages", filter: nil),
            NativeRealtimeChange(table: "conversations", filter: nil),
            NativeRealtimeChange(table: "conversation_reads", filter: "user_id=eq.\(actorID)")
        ], validate: { identity == actor && scenePhase == .active }, reconcile: { await load() },
        revoked: { message in clear(); error=message })
    }
    private func clear() {
        realtime.stop(); reads.invalidate(); loadedIdentity = ""; channels = []; conversations = []; loading = false
        error = nil; joining = nil; declinedInvitations=[:]; creating = false; starting = false
        destination = nil; pendingDestination = nil; channelDraft.reset()
    }
    private func finishSheet() {
        if let pendingDestination {
            switch pendingDestination {
            case .channel(_, _, let actor), .direct(_, _, let actor):
                if identity == actor { destination = pendingDestination }
            }
        }
        pendingDestination = nil
        Task { await load() }
    }
    private func load() async {
        let actor = identity
        guard scenePhase != .background, let request = reads.begin(identity: actor) else { return }
        let organization = organizationID; let ownID = actorID
        loading = true
        defer { if reads.accepts(request, identity: identity) { reads.finish(request); loading = false } }
        do {
            async let channelRead = session.api.rpc("channel_snapshot", body: ["p_organization_id": organization])
            async let inboxRead = session.api.rpc("get_conversation_summaries")
            let (value, inbox) = try await (channelRead, inboxRead)
            guard identity == actor, reads.accepts(request, identity: actor), !Task.isCancelled else { return }
            guard let snapshot = value as? [String: Any], nativeText(snapshot, "actorId").lowercased() == ownID.lowercased(),
                  let rows = snapshot["channels"] as? [[String: Any]], let summaries = inbox as? [[String: Any]] else { throw NativeAPIError.invalidData }
            channels = rows; conversations = summaries.filter { nativeText($0, "organization_id").lowercased() == organization.lowercased() }
            loadedIdentity = actor; error = nil
        } catch {
            guard identity == actor, reads.accepts(request, identity: actor), !Task.isCancelled else { return }
            channels = []; conversations = []; self.error = error.localizedDescription
        }
    }
    private func join(_ channel: [String: Any]) async {
        let actor = identity; guard !actor.isEmpty, joining == nil else { return }
        joining = nativeText(channel, "id")
        do {
            _ = try await session.api.rpc("channel_command", body: ["p_action": "join", "p_channel_id": nativeText(channel, "id"), "p_payload": ["expectedActorId": actorID]])
            guard identity == actor else { return }
            reads.invalidate(); await load()
        } catch {
            guard identity == actor else { return }
            if NativeChatFailurePolicy.requiresClearingProtectedContent(error) {
                reads.invalidate(); channels = []; conversations = []; loadedIdentity = ""; loading = false
            }
            self.error = "참여 결과를 확인하지 못했습니다. 다시 불러온 뒤 상태를 확인해 주세요."
        }
        if identity == actor { joining = nil }
    }
    private func decline(_ channel:[String:Any]) async {
        let actor=identity; let id=nativeText(channel,"id")
        guard !actor.isEmpty, joining == nil else { return }
        let operation=declinedInvitations[id] ?? UUID().uuidString
        declinedInvitations[id]=operation; joining=id
        defer { if identity == actor { joining=nil } }
        do {
            _=try await session.api.rpc("channel_command",body:["p_action":"leave","p_channel_id":id,"p_payload":["expectedActorId":actorID,"operationId":operation]])
            guard identity == actor else { return }
            declinedInvitations[id]=nil; reads.invalidate(); await load()
        } catch { guard identity == actor else { return }; self.error="초대 거절 결과를 확인하지 못했습니다. 같은 요청으로 다시 확인해 주세요." }
    }
}

private struct NativeChannelCreationView: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var draft: NativeChatChannelDraft
    let onCreated: ([String: Any], String) -> Void
    @State private var saving = false
    @State private var error: String?
    private var identity: String { collaborationIdentity(session) }
    var body: some View {
        Form {
            Section("채널 정보") {
                TextField("이름 (2~60자)", text: $draft.name)
                TextField("설명 (선택, 500자 이내)", text: $draft.description, axis: .vertical).lineLimit(3...6)
                Picker("공개 범위", selection: $draft.visibility) { Text("교회 회원 공개").tag("public"); Text("초대받은 회원만").tag("private") }
            }.disabled(saving || draft.frozenPayload != nil)
            Text("채널 생성은 교회 임원이나 관리자 권한을 부여하지 않습니다. 비공개 채널은 초대를 받은 회원이 직접 수락해야 참여할 수 있습니다.").font(.footnote).foregroundStyle(.secondary)
            if draft.frozenPayload != nil && !saving { Text("이전 요청의 결과를 확인할 때까지 입력 내용은 고정됩니다. 닫아도 이 화면에서 같은 요청을 다시 확인할 수 있습니다.").font(.footnote).foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.red) }
            Button(draft.frozenPayload == nil ? "채널 만들고 입장" : "같은 생성 요청 확인") { Task { await save() } }.frame(minHeight: 44)
                .disabled(saving || identity.isEmpty || !NativeCollaborationPolicy.channelInput(name: draft.name, description: draft.description, visibility: draft.visibility))
        }.navigationTitle("채널·소모임 만들기")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() }.disabled(saving) } }
            .onChange(of: identity) { _, _ in dismiss() }
            .interactiveDismissDisabled(saving)
    }
    private func save() async {
        let actor = identity; guard !actor.isEmpty, !saving else { return }
        saving = true
        let member = session.context["membership"] as? [String: Any] ?? [:]
        let profile = session.context["profile"] as? [String: Any] ?? [:]
        let channelID = draft.channelID
        let payload = draft.frozenPayload ?? ["organizationId": nativeText(member, "organization_id"), "expectedActorId": nativeText(profile, "id"), "name": draft.name.trimmingCharacters(in: .whitespacesAndNewlines), "description": draft.description, "visibility": draft.visibility]
        draft.frozenPayload = payload
        do {
            let result = try await session.api.rpc("channel_command", body: ["p_action": "create", "p_channel_id": channelID, "p_payload": payload])
            guard identity == actor else { return }
            guard let row = result as? [String: Any], nativeText(row, "id").lowercased() == channelID.lowercased() else { throw NativeAPIError.invalidData }
            let channel: [String: Any] = ["id": channelID, "name": nativeText(payload, "name"), "description": nativeText(payload, "description"), "visibility": nativeText(payload, "visibility"), "status": "active"]
            draft.reset(); onCreated(channel, actor)
        } catch { guard identity == actor else { return }; self.error = "생성 결과를 확인하지 못했습니다. 입력 내용은 고정됩니다. 같은 요청을 확인하면 중복 생성을 방지합니다.\n\(error.localizedDescription)" }
        if identity == actor { saving = false }
    }
}
private struct NativeDirectMemberPicker: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let onSelected: (String, String, String) -> Void
    @State private var directory = NativeChatMemberDirectory()
    @State private var query = ""
    @State private var error: String?
    @State private var loading = false
    @State private var saving = false
    @State private var reads = NativeChatReadGate()
    @State private var loadedIdentity = ""
    private var identity: String { collaborationIdentity(session) }
    var body: some View {
        let filtered = loadedIdentity == identity ? directory.matching(query) : []
        List {
            Text("불러온 회원 \(loadedIdentity == identity ? directory.members.count : 0)명에서 검색합니다. 더 많은 회원은 아래에서 직접 불러오세요.").font(.footnote).foregroundStyle(.secondary)
            if loading { ProgressView("교회 회원 확인 중") }
            if let error { Text(error).foregroundStyle(.red); Button("이 페이지 다시 확인") { Task { await loadMore() } }.frame(minHeight: 44).disabled(loading || saving) }
            ForEach(filtered.indices, id: \.self) { index in
                Button(nativeText(filtered[index], "display_name", fallback: "교회 회원")) { Task { await start(filtered[index]) } }.frame(minHeight: 44).disabled(saving)
            }
            if !loading && filtered.isEmpty {
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "현재 불러온 회원 중 대화를 시작할 회원이 없습니다." : "불러온 회원 중 검색 결과가 없습니다.")
                    .foregroundStyle(.secondary)
            }
            if directory.hasMore {
                Button("교회 회원 더 불러오기") { Task { await loadMore() } }.frame(minHeight: 44).disabled(loading || saving || identity.isEmpty)
            } else if directory.reachedLimit {
                Text("서버에서 허용하는 회원 조회 범위에 도달했습니다. 아직 불러오지 못한 회원이 있을 수 있습니다.").font(.footnote).foregroundStyle(.secondary)
            } else if !loading {
                Text("조회 가능한 교회 회원을 모두 불러왔습니다.").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("1:1 대화 시작").searchable(text: $query, prompt: "불러온 회원 이름 검색")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() }.disabled(saving) } }
            .interactiveDismissDisabled(saving)
            .task(id: identity) { reads.invalidate(); directory = NativeChatMemberDirectory(); loadedIdentity = ""; query = ""; error = nil; loading = false; await loadMore() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { reads.invalidate(); directory = NativeChatMemberDirectory(); loadedIdentity = ""; loading = false }
                if phase == .active && loadedIdentity.isEmpty { Task { await loadMore() } }
            }
    }
    private func loadMore() async {
        let actor = identity
        guard scenePhase != .background, directory.hasMore, let request = reads.begin(identity: actor) else { return }
        loading = true
        let organization = nativeText(session.context["membership"] as? [String: Any] ?? [:], "organization_id")
        let ownID = nativeText(session.context["profile"] as? [String: Any] ?? [:], "id")
        let offset = directory.offset
        defer { if reads.accepts(request, identity: identity) { reads.finish(request); loading = false } }
        do {
            let value = try await session.api.rpc("list_visible_organization_memberships", body: ["p_organization_id": organization, "p_limit": NativeChatMemberDirectory.pageSize, "p_offset": offset])
            guard identity == actor, reads.accepts(request, identity: actor), !Task.isCancelled else { return }
            guard let rows = value as? [[String: Any]], rows.count <= NativeChatMemberDirectory.pageSize else { throw NativeAPIError.invalidData }
            let ids = NativeChatMemberDirectory.profileIDs(in: rows, organization: organization, ownID: ownID)
            var profiles: [[String: Any]] = []
            if !ids.isEmpty {
                let value = try await session.api.rpc("list_visible_profiles", body: ["p_profile_ids": ids])
                guard identity == actor, reads.accepts(request, identity: actor), !Task.isCancelled else { return }
                guard let rows = value as? [[String: Any]] else { throw NativeAPIError.invalidData }
                profiles = rows
            }
            directory.append(memberships: rows, profiles: profiles, organization: organization, ownID: ownID)
            loadedIdentity = actor; error = nil
        } catch {
            guard identity == actor, reads.accepts(request, identity: actor), !Task.isCancelled else { return }
            if NativeChatFailurePolicy.requiresClearingProtectedContent(error) { directory = NativeChatMemberDirectory(); loadedIdentity = "" }
            self.error = error.localizedDescription
        }
    }
    private func start(_ profile: [String: Any]) async {
        let actor = identity
        guard !actor.isEmpty, loadedIdentity == actor, !saving else { return }
        saving = true
        do {
            let value = try await session.api.rpc("get_or_create_conversation", body: ["p_other_user_id": nativeText(profile, "id")])
            guard identity == actor else { return }
            guard let id = value as? String, UUID(uuidString: id) != nil else { throw NativeAPIError.invalidData }
            onSelected(id, nativeText(profile, "display_name", fallback: "교회 회원"), actor)
        } catch {
            guard identity == actor else { return }
            if NativeChatFailurePolicy.requiresClearingProtectedContent(error) {
                reads.invalidate(); directory = NativeChatMemberDirectory(); loadedIdentity = ""; loading = false
            }
            self.error = "대화를 열지 못했습니다. 다시 회원을 선택해 확인해 주세요.\n\(error.localizedDescription)"
        }
        if identity == actor { saving = false }
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
            Section {
                NavigationLink("설문·배정·QR·현장 운영") { NativeEventFieldView(occurrenceID: occurrenceID) }
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
