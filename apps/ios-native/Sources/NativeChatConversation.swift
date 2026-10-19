import SwiftUI

@MainActor final class NativeRichChatModel: ObservableObject {
    @Published var messages: [[String: Any]] = []
    @Published var members: [[String: Any]] = []
    @Published var channels: [[String: Any]] = []
    @Published var draft = ""
    @Published var files: [URL] = []
    @Published var mentions: Set<String> = []
    @Published var loading = false
    @Published var sending = false
    @Published var error: String?
    @Published var scrollRequest = UUID()
    @Published var exited = false
    @Published var rootDeleted = false
    @Published var hasOlder = true
    @Published private(set) var frozen: [String: Any]?
    @Published private(set) var uploadUncertain = false
    let realtime = NativeChatRealtime()
    private weak var session: NativeSession?
    private var identity = ""
    private var organization = ""
    private var foreground = false
    private var viewGeneration = UUID()
    private(set) var channelID: String?
    private(set) var conversationID: String?
    private(set) var rootID: String?
    private var reads = NativeChatReadGate()
    private var uploaded: [NativeMediaAttachment] = []
    private var media: NativeMediaService?
    private var messageID = UUID().uuidString
    private var pendingAction: (String, String, [String: Any])?
    private var reloadRequested = false
    var uncertainAction: Bool { pendingAction != nil }
    var actorID: String { nativeText(session?.context["profile"] as? [String: Any] ?? [:], "id") }
    var currentChannel: [String: Any] { channels.first { nativeText($0, "id").lowercased() == channelID?.lowercased() } ?? [:] }
    var archived: Bool { currentChannel["archived"] as? Bool == true }
    var owner: Bool { nativeText(currentChannel, "ownerId").lowercased() == actorID.lowercased() }
    var manager: Bool { owner || nativeText(currentChannel, "role") == "manager" }
    var active: Bool { foreground && !identity.isEmpty && session.map { collaborationIdentity($0) == identity } == true }
    private var gateIdentity: String { active ? "\(identity):\(viewGeneration)" : "" }

    func bind(session: NativeSession, identity: String, organization: String, channelID: String?, conversationID: String?, rootID: String?) async {
        if self.identity == identity, self.session === session, self.channelID == channelID, self.conversationID == conversationID, self.rootID == rootID {
            await resume(); return
        }
        clear(); self.session = session; self.identity = identity; self.organization = organization
        self.channelID = channelID; self.conversationID = conversationID; self.rootID = rootID
        foreground=true
        guard active else { return }
        media = NativeMediaService(session: session)
        await load(jump: true)
        connect()
    }
    func suspend() { foreground=false; viewGeneration=UUID(); realtime.stop(); reads.invalidate(); messages = []; members = []; channels = []; media?.clearSignedURLs(); loading = false; sending=false; reloadRequested=false }
    func clear() {
        suspend(); files.forEach { try? FileManager.default.removeItem(at: $0) }; files = []; uploaded = []
        mentions = []; draft = ""; frozen = nil; pendingAction = nil; identity = ""; session = nil; media?.clear(); media = nil
        messageID = UUID().uuidString; error = nil; sending = false; hasOlder = true; exited = false; rootDeleted=false; reloadRequested=false; uploadUncertain=false
    }
    func resume() async {
        guard !identity.isEmpty, let session, collaborationIdentity(session) == identity else { clear(); return }
        foreground=true; await load(jump:false); connect()
    }
    func refresh() async { await resume() }
    func connect() {
        guard active, let session else { return }
        let actor = gateIdentity
        let changes: [NativeRealtimeChange]
        if let channelID { changes = [NativeRealtimeChange(table: "channel_change_events", filter: "channel_id=eq.\(channelID)")] }
        else { changes = [NativeRealtimeChange(table: "messages", filter: "conversation_id=eq.\(conversationID ?? "")")] }
        realtime.start(session: session, changes: changes, channelID:channelID, conversationID:conversationID, validate: { [weak self] in self?.gateIdentity == actor }, reconcile: { [weak self] in await self?.load(jump: false) }, revoked: { [weak self] message in self?.suspend(); self?.error=message })
    }
    func load(jump: Bool = false, older: Bool = false) async {
        guard let session, active else { return }
        guard let ticket = reads.begin(identity:gateIdentity) else { if !older { reloadRequested=true }; return }
        let actor = gateIdentity; loading = true
        defer {
            if reads.accepts(ticket, identity:gateIdentity) {
                reads.finish(ticket); loading=false
                if reloadRequested { reloadRequested=false; Task { await self.load() } }
            }
        }
        do {
            var rows: [[String: Any]]
            let before = older ? (messages.first?[channelID == nil ? "created_at" : "seq"]) : nil
            if let channelID {
                var body: [String: Any] = ["p_channel_id":channelID]
                let rpc: String
                if let rootID { rpc = "channel_thread_snapshot"; body["p_root_message_id"] = rootID }
                else { rpc = "channel_snapshot"; body["p_organization_id"] = organization }
                if let before { body["p_before_seq"] = before }
                let value = try await session.api.rpc(rpc, body: body)
                guard gateIdentity == actor, reads.accepts(ticket, identity: actor) else { return }
                guard let snapshot = value as? [String: Any], nativeText(snapshot, "actorId").lowercased() == actorID.lowercased(), let valueRows = snapshot["messages"] as? [[String: Any]] else { throw NativeAPIError.invalidData }
                rootDeleted=snapshot["rootDeleted"] as? Bool == true
                if rootID != nil {
                    let scope = try await session.api.rpc("channel_snapshot", body:["p_organization_id":organization,"p_channel_id":channelID])
                    guard gateIdentity == actor, reads.accepts(ticket, identity:actor), let snapshot=scope as? [String:Any],
                          nativeText(snapshot,"actorId").lowercased() == actorID.lowercased(),
                          let channels=snapshot["channels"] as? [[String:Any]], let members=snapshot["members"] as? [[String:Any]] else { throw NativeAPIError.invalidData }
                    self.channels=channels; self.members=members
                }
                rows = valueRows
                if rootID == nil {
                    guard let channels = snapshot["channels"] as? [[String: Any]], let members = snapshot["members"] as? [[String: Any]], channels.contains(where: { nativeText($0,"id").lowercased() == channelID.lowercased() && nativeText($0,"status") == "active" }) else { throw NativeAPIError.security("채널 참여 권한이 없습니다.") }
                    self.channels = channels; self.members = members
                }
                hasOlder = rows.count == (rootID == nil ? 50 : 100)
            } else if let conversationID {
                let beforeQuery: String
                if let time=before as? String, let first=messages.first {
                    let encoded=time.addingPercentEncoding(withAllowedCharacters:.alphanumerics) ?? ""
                    beforeQuery="&or=(created_at.lt.\(encoded),and(created_at.eq.\(encoded),id.lt.\(nativeText(first,"id"))))"
                } else { beforeQuery="" }
                let scope = try await session.api.rpc("validate_chat_access",body:["p_conversation_id":conversationID])
                guard gateIdentity == actor, reads.accepts(ticket, identity:actor) else { return }
                guard let scope=scope as? [String:Any], nativeText(scope,"actorId").lowercased() == actorID.lowercased() else { throw NativeAPIError.security("대화 접근 권한을 확인해 주세요.") }
                rows = try await session.api.rows("messages", query: "select=id,sender_id,kind,body,media_path,media_metadata,client_nonce,created_at&conversation_id=eq.\(conversationID)&deleted_at=is.null&order=created_at.desc,id.desc&limit=100\(beforeQuery)").reversed()
                hasOlder = rows.count == 100
            } else { throw NativeAPIError.invalidData }
            guard gateIdentity == actor, reads.accepts(ticket, identity: actor), !Task.isCancelled else { return }
            if older {
                let known = Set(messages.map { nativeText($0,"id") }); messages = rows.filter { !known.contains(nativeText($0,"id")) } + messages
            } else { messages = rows }
            error = nil
            if jump { scrollRequest = UUID() }
            if !older, let latest = rows.last {
                if let channelID {
                    var payload: [String: Any] = ["expectedActorId":actorID, "seq":latest["seq"] ?? 0]
                    if let rootID { payload["messageId"] = rootID }
                    _ = try await session.api.rpc(rootID == nil ? "channel_command" : "channel_rich_command", body: ["p_action":rootID == nil ? "read" : "read_thread", "p_channel_id":channelID, "p_payload":payload])
                } else if let conversationID { _ = try await session.api.rpc("mark_conversation_read", body: ["p_conversation_id":conversationID, "p_message_id":nativeText(latest,"id")]) }
            }
        } catch {
            guard gateIdentity == actor, reads.accepts(ticket, identity: actor), !Task.isCancelled else { return }
            if NativeChatFailurePolicy.requiresClearingProtectedContent(error) { messages = []; members = []; channels = []; media?.clear() }
            self.error = error.localizedDescription
        }
    }
    func send() async {
        guard active, let session, !sending, !rootDeleted, (NativeCollaborationPolicy.textInput(draft) || !files.isEmpty || frozen != nil), draft.unicodeScalars.count <= 4000, files.count <= 4 else { return }
        let actor = gateIdentity; sending = true; error = nil
        defer { if gateIdentity == actor { sending = false } }
        do {
            if frozen == nil {
                guard let media else { throw NativeAPIError.invalidData }
                // Retain successful uploads across a failed upload. No duplicate bytes on manual retry.
                for file in files.dropFirst(uploaded.count) {
                    let attachment = try await media.upload(fileURL: file, purpose: channelID == nil ? "message" : "channel", targetID: channelID ?? conversationID ?? "", organizationID: organization)
                    guard gateIdentity == actor else { return }; uploaded.append(attachment)
                }
                if channelID != nil {
                    var payload: [String: Any] = ["expectedActorId":actorID,"messageId":messageID,"body":draft.trimmingCharacters(in:.whitespacesAndNewlines),"attachments":uploaded.map(\.channelPayload),"mentionUserIds":Array(mentions).sorted()]
                    if let rootID { payload["parentMessageId"] = rootID }
                    frozen = payload
                } else {
                    var items: [[String: Any]] = []
                    if !draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { items.append(["kind":"text","body":draft.trimmingCharacters(in:.whitespacesAndNewlines),"media_path":NSNull(),"media_metadata":[String:Any](),"client_nonce":messageID]) }
                    for item in uploaded { items.append(["kind":item.kind,"body":NSNull(),"media_path":item.path,"media_metadata":["mime_type":item.mimeType,"byte_size":item.byteSize],"client_nonce":item.id]) }
                    frozen = ["p_conversation_id":conversationID ?? "", "p_expected_sender_id":actorID,"p_messages":items]
                }
            }
            guard gateIdentity == actor, let frozen else { return }
            if let channelID { _ = try await session.api.rpc("channel_rich_command", body:["p_action":"send","p_channel_id":channelID,"p_payload":frozen]) }
            else { _ = try await session.api.rpc("send_message_batch", body:frozen) }
            guard gateIdentity == actor else { return }
            self.frozen = nil; draft = ""; mentions = []; uploaded = []; messageID = UUID().uuidString
            uploadUncertain=false
            files.forEach { try? FileManager.default.removeItem(at:$0) }; files = []
            reads.invalidate(); await load(jump:true)
        } catch {
            guard gateIdentity == actor else { return }
            if NativeChatFailurePolicy.requiresClearingProtectedContent(error) { messages = []; members = []; channels = []; media?.clear() }
            if NativeChatFailurePolicy.isDefinitiveRefusal(error) { frozen=nil; uploaded=[] }
            uploadUncertain=frozen == nil && !files.isEmpty && !NativeChatFailurePolicy.isDefinitiveRefusal(error)
            self.error = "전송을 확인하지 못했습니다. 내용은 고정되며 같은 요청으로 직접 다시 확인할 수 있습니다.\n\(error.localizedDescription)"
        }
    }
    var composerFrozen: Bool { frozen != nil || sending || !uploaded.isEmpty || uploadUncertain }
    func command(_ action: String, rich: Bool = true, payload: [String: Any] = [:]) async {
        guard active, let session, let channelID, !sending, pendingAction == nil else { return }
        var body = payload; body["expectedActorId"] = actorID
        pendingAction = (rich ? "channel_rich_command" : "channel_command", action, body)
        await retryAction(session:session, channelID:channelID)
    }
    func updateChannel(name:String,description:String,expectedName:String,expectedDescription:String) async {
        guard active, let session, let channelID, !sending, pendingAction == nil else { return }
        pendingAction=("update_community_channel","",["p_channel_id":channelID,"p_expected_actor_id":actorID,"p_name":name,"p_description":description,"p_expected_name":expectedName,"p_expected_description":expectedDescription])
        await retryAction(session:session,channelID:channelID)
    }
    func retryAction() async { guard active, let session, let channelID, !sending else { return }; await retryAction(session:session, channelID:channelID) }
    private func retryAction(session: NativeSession, channelID: String) async {
        guard let pendingAction else { return }; let actor = gateIdentity; sending = true
        defer { if gateIdentity == actor { sending = false } }
        do {
            let result=try await session.api.rpc(pendingAction.0, body:pendingAction.1.isEmpty ? pendingAction.2 : ["p_action":pendingAction.1,"p_channel_id":channelID,"p_payload":pendingAction.2])
            guard gateIdentity == actor else { return }
            if pendingAction.1 == "delete", let paths=(result as? [String:Any])?["deletedPaths"] as? [String], !paths.isEmpty {
                messages.removeAll { nativeText($0,"id") == nativeText(pendingAction.2,"messageId") }
                guard let media else { throw NativeAPIError.invalidData }
                try await media.remove(paths:paths)
            }
            guard gateIdentity == actor else { return }; self.pendingAction = nil
            if pendingAction.1 == "leave" { exited=true; suspend(); return }
            reads.invalidate(); await load()
        } catch {
            guard gateIdentity == actor else { return }
            if NativeChatFailurePolicy.isDefinitiveRefusal(error) { self.pendingAction=nil }
            self.error="요청 결과를 확인하지 못했습니다. 결과가 불확실한 요청은 같은 내용으로 다시 확인해 주세요.\n\(error.localizedDescription)"
            if NativeChatFailurePolicy.requiresClearingProtectedContent(error) { messages=[]; members=[]; channels=[]; media?.clear() }
        }
    }
}

struct NativeDirectConversationView: View {
    let conversationID: String
    let title: String
    let accessIdentity: String
    var body: some View { NativeRichConversationView(channel:nil, conversationID:conversationID, organizationID:nil, title:title, accessIdentity:accessIdentity, rootID:nil) }
}
struct NativeCollaborationChannelMessagesView: View {
    let channel: [String: Any]
    let organizationID: String
    let accessIdentity: String
    var body: some View { NativeRichConversationView(channel:channel, conversationID:nil, organizationID:organizationID, title:nativeText(channel,"name",fallback:"채널"), accessIdentity:accessIdentity, rootID:nil) }
}

private struct NativeRichConversationView: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    let channel: [String: Any]?
    let conversationID: String?
    let organizationID: String?
    let title: String
    let accessIdentity: String
    let rootID: String?
    @StateObject private var model = NativeRichChatModel()
    @State private var managing = false
    @State private var mentionPicker = false
    @State private var forwarding: String?
    @State private var editing: String?
    @State private var editBody = ""
    private var identity: String { collaborationIdentity(session) == accessIdentity ? accessIdentity : "" }
    private var organization: String { organizationID ?? nativeText(session.context["membership"] as? [String:Any] ?? [:],"organization_id") }
    var body: some View {
        VStack(spacing:0) {
            NativeChatRealtimeStatus(realtime:model.realtime)
            if model.loading { ProgressView("대화 확인 중").padding(4) }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red).padding(8) }
            if model.uncertainAction { Button("같은 작업 결과 확인") { Task { await model.retryAction() } }.disabled(model.sending) }
            NativeChatMessageList(scrollRequest:model.scrollRequest, refresh:{ await model.refresh() }) {
                if model.hasOlder { Button("이전 메시지 더 보기") { Task { await model.load(older:true) } }.disabled(model.loading) }
                if model.messages.isEmpty && !model.loading { Text("아직 메시지가 없습니다.").foregroundStyle(.secondary) }
                if model.active {
                    ForEach(model.messages.indices, id:\.self) { index in messageRow(model.messages[index]) }
                }
            }
        }.safeAreaInset(edge:.bottom) { composer }
            .navigationTitle(rootID == nil ? title : "답글").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if channel != nil && rootID == nil {
                    NavigationLink { NativeMeetingsView(channelID:channel.map { nativeText($0,"id") }) } label: { Label("회의",systemImage:"video") }
                    Button { managing = true } label: { Label("채널 관리",systemImage:"person.2") }.disabled(model.loading || model.currentChannel.isEmpty || !model.active)
                }
            }
            .task(id:"\(identity):\(phase == .active)") {
                guard phase == .active else { model.suspend(); return }
                await model.bind(session:session,identity:identity,organization:organization,channelID:channel.map { nativeText($0,"id") },conversationID:conversationID,rootID:rootID)
            }
            .onDisappear { model.suspend() }
            .onChange(of:model.exited) { _, value in if value { dismiss() } }
            .sheet(isPresented:$managing) { NavigationStack { NativeChannelManagementView(model:model, organizationID:organization) }.environmentObject(session) }
            .sheet(isPresented:$mentionPicker) { NavigationStack { mentionList }.environmentObject(session) }
            .sheet(isPresented:Binding(get:{ forwarding != nil },set:{ if !$0 { forwarding=nil } })) { NavigationStack { forwardList } }
            .sheet(isPresented:Binding(get:{ editing != nil },set:{ if !$0 { editing=nil } })) { NavigationStack { Form { TextField("메시지",text:$editBody,axis:.vertical); Button("수정 저장") { guard let editing else { return }; Task { await model.command("edit",payload:["messageId":editing,"body":editBody]); self.editing=nil } }.disabled(!NativeCollaborationPolicy.textInput(editBody) || model.sending) }.navigationTitle("메시지 수정") } }
    }
    private var composer: some View {
        VStack(alignment:.leading,spacing:8) {
            if model.rootDeleted { Text("원문이 삭제되어 기존 답글만 볼 수 있습니다.").font(.caption).foregroundStyle(.secondary) }
            if !model.mentions.isEmpty { Text("멘션 \(model.mentions.count)/10명").font(.caption) }
            HStack {
                if channel != nil { Button("멘션") { mentionPicker = true }.disabled(model.composerFrozen) }
                NativeMediaPicker(files:$model.files,maximum:4).disabled(model.composerFrozen)
            }
            HStack {
                TextField("메시지",text:$model.draft,axis:.vertical).lineLimit(1...5).textFieldStyle(.roundedBorder).disabled(model.frozen != nil || model.sending || model.rootDeleted)
                Button(model.frozen == nil ? "전송" : "결과 확인") { Task { await model.send() } }.frame(minWidth:44,minHeight:44).disabled(model.sending || !model.active || model.archived || model.rootDeleted || model.uncertainAction || (!NativeCollaborationPolicy.textInput(model.draft) && model.files.isEmpty && model.frozen == nil))
            }
        }.padding(12).background(.bar)
    }
    @ViewBuilder private func messageRow(_ row: [String: Any]) -> some View {
        let sender = nativeText(row, channel == nil ? "sender_id" : "senderId")
        let own = sender.lowercased() == model.actorID.lowercased()
        let deleted = row["deleted"] as? Bool == true
        VStack(alignment:.leading,spacing:8) {
            Text(own ? "나" : nativeText(row,"senderName",fallback:title)).font(.subheadline.bold())
            if deleted { Text("삭제된 메시지").foregroundStyle(.secondary) }
            else {
                if !nativeText(row,"forwardedSenderName").isEmpty { Label("\(nativeText(row,"forwardedSenderName"))님의 메시지 전달",systemImage:"arrowshape.turn.up.right").font(.caption).foregroundStyle(.secondary) }
                Text(nativeText(row,"body")).textSelection(.enabled)
                if let ids = row["mentionUserIds"] as? [String], !ids.isEmpty { Text(ids.map { id in "@" + nativeText(model.members.first { nativeText($0,"userId") == id } ?? [:],"name",fallback:"참여 회원") }.joined(separator:" ")).font(.caption).foregroundStyle(.secondary) }
                if let path = row["media_path"] as? String { NativeMediaView(path:path,kind:nativeText(row,"kind")) }
                ForEach((row["attachments"] as? [[String:Any]] ?? []).indices,id:\.self) { index in
                    let attachment = (row["attachments"] as? [[String:Any]] ?? [])[index]
                    NativeMediaView(path:nativeText(attachment,"path"),kind:nativeText(attachment,"kind"))
                }
                if channel != nil {
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:48),spacing:4)],alignment:.leading,spacing:4) {
                        ForEach(["👍","❤️","🙏","😂","😮","😢"],id:\.self) { emoji in
                            let reaction = (row["reactions"] as? [[String:Any]] ?? []).first { nativeText($0,"emoji") == emoji } ?? [:]
                            Button { Task { await model.command("react",payload:["messageId":nativeText(row,"id"),"emoji":emoji,"active":reaction["reacted"] as? Bool != true]) } } label: { Text("\(emoji) \((reaction["count"] as? NSNumber)?.intValue ?? 0)").font(.caption).frame(minWidth:44,minHeight:44) }.disabled(model.sending || model.uncertainAction)
                        }
                    }
                }
            }
            if channel != nil && rootID == nil {
                NavigationLink { NativeRichConversationView(channel:channel,conversationID:nil,organizationID:organization,title:title,accessIdentity:accessIdentity,rootID:nativeText(row,"id")) } label: { Text("답글 \((row["replyCount"] as? NSNumber)?.intValue ?? 0) · 안 읽음 \((row["unreadReplyCount"] as? NSNumber)?.intValue ?? 0)").font(.caption) }
            }
            HStack {
                Text(nativeText(row,channel == nil ? "created_at" : "createdAt")).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if !deleted { Menu("더 보기") {
                    if channel != nil {
                        if !nativeText(row,"body").isEmpty { Button("텍스트만 전달") { forwarding = nativeText(row,"id") } }
                        if own {
                            if nativeText(row,"forwardedFromId").isEmpty { Button("수정") { editBody=nativeText(row,"body"); editing=nativeText(row,"id") } }
                            Button("삭제",role:.destructive) { Task { await model.command("delete",payload:["messageId":nativeText(row,"id")]) } }
                        }
                    }
                    if !own { NavigationLink("신고·차단") { NativeChatSafetyLink(targetType:channel == nil ? "message" : "channel_message",targetID:nativeText(row,"id"),userID:sender,onBlocked:{ model.suspend(); Task { await model.refresh() } }) } }
                }.disabled(model.sending || model.uncertainAction) }
            }
        }.padding(.vertical,6)
    }
    private var mentionList: some View {
        let members=model.members.filter { nativeText($0,"status") == "active" }
        return List {
            Text("현재 참여자만 선택하며 최대 10명입니다. 전달 시 멘션 알림은 복사되지 않습니다.").font(.footnote)
            ForEach(members.indices,id:\.self) { index in
                let member=members[index]; let id=nativeText(member,"userId")
                Toggle(nativeText(member,"name"),isOn:Binding(get:{ model.mentions.contains(id) },set:{ value in if value && model.mentions.count < 10 { model.mentions.insert(id) } else { model.mentions.remove(id) } }))
            }
        }.navigationTitle("멘션 선택").toolbar { Button("완료") { mentionPicker=false } }
    }
    private var forwardList: some View {
        let targets=model.channels.filter { nativeText($0,"status") == "active" && $0["archived"] as? Bool != true && nativeText($0,"id") != model.channelID }
        return List {
            Text("본문과 원 작성자 표시만 전달합니다. 첨부 파일·멘션·알림 대상은 복사되지 않습니다.").font(.footnote)
            ForEach(targets.indices,id:\.self) { index in
                let target=targets[index]
                Button(nativeText(target,"name")) { guard let forwarding else { return }; let operationID=UUID().uuidString; Task { await model.command("forward",payload:["messageId":forwarding,"targetChannelId":nativeText(target,"id"),"operationId":operationID]); self.forwarding=nil } }.disabled(model.sending || model.uncertainAction)
            }
        }.navigationTitle("텍스트 전달")
    }
}

private struct NativeChatRealtimeStatus: View {
    @ObservedObject var realtime: NativeChatRealtime
    var body: some View { Text(realtime.status).font(.caption).foregroundStyle(.secondary).padding(4) }
}
