import SwiftUI

struct NativeChannelManagementView: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: NativeRichChatModel
    let organizationID: String
    @State private var name = ""
    @State private var description = ""
    @State private var expectedName = ""
    @State private var expectedDescription = ""
    @State private var directory = NativeChatMemberDirectory()
    @State private var loadingMembers = false
    @State private var query = ""
    @State private var error: String?
    @State private var confirmation: String?
    var body: some View {
        let candidates=directory.matching(query).filter { candidate in !model.members.contains { nativeText($0,"userId").lowercased() == nativeText(candidate,"id").lowercased() } }
        Form {
            Section("채널 정보") {
                TextField("채널 이름",text:$name)
                TextField("설명",text:$description,axis:.vertical)
                Text(nativeText(model.currentChannel,"visibility") == "private" ? "초대를 받고 직접 수락한 회원만 참여합니다." : "같은 교회 회원에게 공개된 채널입니다.").font(.footnote).foregroundStyle(.secondary)
                if model.manager { Button("이름·설명 저장") { Task { await model.updateChannel(name:name,description:description,expectedName:expectedName,expectedDescription:expectedDescription); if model.error == nil && !model.uncertainAction { expectedName=name; expectedDescription=description } } }.disabled(model.sending || model.uncertainAction || model.archived || !NativeCollaborationPolicy.channelInput(name:name,description:description,visibility:nativeText(model.currentChannel,"visibility"))) }
            }.disabled(!model.manager || model.archived || model.sending || model.uncertainAction)
            Section("알림") {
                ForEach([("all","모든 메시지"),("mentions","멘션·답글"),("none","받지 않음")],id:\.0) { mode in
                    Button { Task { await model.command("preference",payload:["mode":mode.0]) } } label: { HStack { Text(mode.1); Spacer(); if nativeText(model.currentChannel,"notificationMode") == mode.0 { Image(systemName:"checkmark") } } }
                }
            }.disabled(model.sending || model.uncertainAction)
            Section("참여자·초대") {
                ForEach(model.members.indices,id:\.self) { index in
                    let member = model.members[index]; let userID=nativeText(member,"userId")
                    VStack(alignment:.leading,spacing:8) {
                        HStack { Text(nativeText(member,"name")); Spacer(); Text(nativeText(member,"status") == "invited" ? "초대 수락 대기" : (nativeText(model.currentChannel,"ownerId") == userID ? "소유자" : nativeText(member,"role") == "manager" ? "채널 관리자" : "참여자")).font(.caption).foregroundStyle(.secondary) }
                        if model.manager && userID.lowercased() != model.actorID.lowercased() && userID != nativeText(model.currentChannel,"ownerId") {
                            Button(nativeText(member,"status") == "invited" ? "초대 취소" : "참여 해제",role:.destructive) { Task { await model.command("remove",rich:false,payload:["userId":userID]) } }
                            if model.owner && nativeText(member,"status") == "active" {
                                Button(nativeText(member,"role") == "manager" ? "채널 관리자 해제" : "채널 관리자 지정") { Task { await model.command("manager",rich:false,payload:["userId":userID,"role":nativeText(member,"role") == "manager" ? "member" : "manager"]) } }
                                Button("소유권 넘기기") { confirmation=userID }
                            }
                        }
                    }.padding(.vertical,4)
                }
                Text("채널 소유자·관리자 자격은 교회 임원이나 조직 관리 권한을 부여하지 않습니다. 교회 회원 자격이 끝나면 비공개 참여·초대는 영구 해제되며 새 초대가 필요합니다.").font(.footnote).foregroundStyle(.secondary)
            }.disabled(model.sending || model.uncertainAction || model.archived)
            if model.manager && !model.archived {
                Section("교회 회원 초대") {
                    TextField("불러온 회원 이름 검색",text:$query)
                    ForEach(candidates.indices,id:\.self) { index in
                        let candidate=candidates[index]
                        Button("\(nativeText(candidate,"display_name",fallback:"교회 회원")) 초대") { Task { await model.command("invite",rich:false,payload:["userId":nativeText(candidate,"id")]) } }
                    }
                    if directory.hasMore { Button(loadingMembers ? "회원 확인 중" : "초대할 회원 더 불러오기") { Task { await loadMembers() } }.disabled(loadingMembers || model.sending) }
                    Text("검색은 현재 불러온 \(directory.members.count)명에 한합니다. 초대만으로 대화 접근 권한이 생기지 않습니다.").font(.footnote).foregroundStyle(.secondary)
                }.disabled(model.sending || model.uncertainAction)
            }
            Section {
                if model.owner && !model.archived { Button("채널 보관",role:.destructive) { confirmation="archive" } }
                Button("채널 나가기",role:.destructive) { confirmation="leave" }.disabled(model.owner && !model.archived)
                if model.owner && !model.archived { Text("소유권을 넘기거나 채널을 보관한 뒤 나갈 수 있습니다.").font(.footnote).foregroundStyle(.secondary) }
            }.disabled(model.sending || model.uncertainAction)
            if let error { Text(error).foregroundStyle(.red) }
            if let error=model.error { Text(error).foregroundStyle(.red) }
            if model.uncertainAction { Button("같은 작업 결과 확인") { Task { await model.retryAction() } }.disabled(model.sending) }
        }.navigationTitle("채널 관리").toolbar { Button("닫기") { dismiss() } }
            .onAppear { name=nativeText(model.currentChannel,"name"); description=nativeText(model.currentChannel,"description"); expectedName=name; expectedDescription=description }
            .onChange(of:collaborationIdentity(session)) { _, _ in directory=NativeChatMemberDirectory(); dismiss() }
            .onChange(of:model.exited) { _, value in if value { dismiss() } }
            .confirmationDialog("이 작업을 진행할까요?",isPresented:Binding(get:{ confirmation != nil },set:{ if !$0 { confirmation=nil } }),titleVisibility:.visible) {
                Button("확인",role:.destructive) {
                    guard let action=confirmation else { return }; confirmation=nil
                    Task {
                        if action == "leave" { await model.command("leave",rich:false,payload:["operationId":UUID().uuidString]) }
                        else if action == "archive" { await model.command("archive",rich:false) }
                        else { await model.command("transfer",rich:false,payload:["userId":action]) }
                    }
                }
            }
    }
    private func loadMembers() async {
        guard !loadingMembers, directory.hasMore, model.active else { return }
        let actor=collaborationIdentity(session); loadingMembers=true
        defer { if collaborationIdentity(session) == actor { loadingMembers=false } }
        do {
            let value=try await session.api.rpc("list_visible_organization_memberships",body:["p_organization_id":organizationID,"p_limit":NativeChatMemberDirectory.pageSize,"p_offset":directory.offset])
            guard collaborationIdentity(session) == actor, model.active, let rows=value as? [[String:Any]] else { return }
            let ids=NativeChatMemberDirectory.profileIDs(in:rows,organization:organizationID,ownID:model.actorID)
            var profiles: [[String:Any]]=[]
            if !ids.isEmpty { profiles=try await session.api.rpc("list_visible_profiles",body:["p_profile_ids":ids]) as? [[String:Any]] ?? [] }
            guard collaborationIdentity(session) == actor, model.active else { return }
            directory.append(memberships:rows,profiles:profiles,organization:organizationID,ownID:model.actorID); error=nil
        } catch { guard collaborationIdentity(session) == actor else { return }; self.error=error.localizedDescription }
    }
}

struct NativeChatSafetyLink: View {
    @Environment(\.dismiss) private var dismiss
    let targetType: String
    let targetID: String
    let userID: String
    let onBlocked: () -> Void
    var body: some View {
        List {
            NavigationLink("이 메시지 신고") { NativeSafetyReportView(targetType:targetType,targetID:targetID,targetLabel:"대화 메시지") }
            NativeSafetyBlockButton(userID:userID,onBlocked:{ onBlocked(); dismiss() })
            Text("신고는 선택한 메시지의 최소 증거만 제출합니다. 관리자에게 전체 개인 대화 열람권을 부여하지 않습니다.").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("신고·차단")
    }
}
