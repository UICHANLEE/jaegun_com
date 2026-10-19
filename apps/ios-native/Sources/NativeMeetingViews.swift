import SwiftUI
import AVFoundation
#if canImport(JitsiMeetSDK)
import JitsiMeetSDK
#endif

@MainActor func nativeMeetingIdentity(_ session: NativeSession) -> String {
    let member = session.context["membership"] as? [String: Any] ?? [:]
    guard session.signedIn, !session.consentRequired, nativeText(member, "status") == "active" else { return "" }
    return "\(session.sessionGeneration):\(nativeText(session.context["profile"] as? [String: Any] ?? [:], "id")):\(nativeText(member, "organization_id"))"
}

struct NativeMeetingsView: View {
    @EnvironmentObject private var session: NativeSession
    var channelID: String? = nil
    private var identity: String { nativeMeetingIdentity(session) }
    var body: some View {
        Group {
            if identity.isEmpty { Text("현재 동의를 완료한 승인 회원만 회의를 이용할 수 있습니다.") }
            else { NativeMeetingWorkspace(channelID: channelID).id("\(identity):\(channelID ?? "")") }
        }.navigationTitle("인앱 회의")
    }
}

private struct NativeMeetingEntry: Identifiable {
    let id: String
    let host: String
    let room: String
    let jwt: String
}

private struct NativeMeetingWorkspace: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.nativeTabActive) private var tabActive
    let channelID: String?
    @State private var snapshot: [String: Any] = [:]
    @State private var title = ""
    @State private var channel = ""
    @State private var approved = false
    @State private var error: String?
    @State private var busy = false
    @State private var entry: NativeMeetingEntry?
    @State private var createID = UUID().uuidString
    @State private var boundIdentity = ""
    private var identity: String { nativeMeetingIdentity(session) }
    private var organization: String { nativeText(session.context["membership"] as? [String: Any] ?? [:], "organization_id") }
    private var actor: String { nativeText(session.context["profile"] as? [String: Any] ?? [:], "id") }
    private var meetings: [[String: Any]] {
        (snapshot["meetings"] as? [[String: Any]] ?? []).filter { channelID == nil || nativeText($0, "channelId") == channelID }
    }
    init(channelID: String?) {
        self.channelID = channelID
        _channel = State(initialValue: channelID ?? "")
    }
    var body: some View {
        List {
            Section("회의 생성") {
                TextField("회의 제목", text: $title).onChange(of: title) { _ in createID = UUID().uuidString }
                Picker("정확한 참석 범위", selection: $channel) {
                    Text("범위 선택").tag("")
                    let scopes = snapshot["scopes"] as? [[String: Any]] ?? []
                    ForEach(scopes.indices, id: \.self) { index in
                        Text("\(nativeText(scopes[index], "name")) · 임원").tag("scope:\(nativeText(scopes[index], "id"))")
                    }
                    ForEach((snapshot["channels"] as? [[String: Any]] ?? []).indices, id: \.self) { index in
                        let c = (snapshot["channels"] as? [[String: Any]] ?? [])[index]
                        Text(nativeText(c, "name")).tag(nativeText(c, "id"))
                    }
                }.disabled(channelID != nil).onChange(of: channel) { _ in createID = UUID().uuidString }
                Button("회의 만들기") {
                    Task {
                        await command("create", id: createID, payload: [
                            "organizationId": organization, "channelId": channel.hasPrefix("scope:") ? NSNull() : channel as Any,
                            "scopeId": channel.hasPrefix("scope:") ? String(channel.dropFirst(6)) as Any : NSNull(), "title": title])
                    }
                }.disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || channel.isEmpty)
            }
            Section("장치·외부 전송 안내") {
                Text("전용 Jitsi 호스트에 이름·음성·영상이 전송됩니다. 카메라·마이크는 입장할 때 요청합니다. 녹화·외부 송출은 제공하지 않습니다. 회의는 4시간 후 만료됩니다.")
                Toggle("회의 참여·장치 사용 허용", isOn: $approved)
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            ForEach(meetings.indices, id: \.self) { index in
                let meeting = meetings[index]
                Section(nativeText(meeting, "title")) {
                    Text(meeting["channelId"] is String ? "채널 회원 전용" : "정확한 조직 임원 전용")
                    Text("만료: \(nativeText(meeting, "expiresAt"))").font(.caption)
                    let admission = nativeText(meeting, "admission")
                    if admission == "admitted" {
                        Button("입장 / 다시 연결") { Task { await join(meeting) } }.disabled(busy || !approved)
                    } else if admission == "revoked" { Text("입장 권한이 회수되었습니다.") }
                    else {
                        Button(admission == "waiting" ? "대기실 · 승인 대기" : "입장 요청") { Task { await command("request", id: nativeText(meeting, "id")) } }.disabled(busy || admission == "waiting")
                    }
                    if meeting["canManage"] as? Bool == true {
                        Button("전체 회의 종료", role: .destructive) { Task { await command("end", id: nativeText(meeting, "id")) } }.disabled(busy)
                        let admissions = meeting["waiting"] as? [[String: Any]] ?? []
                        ForEach(admissions.indices, id: \.self) { i in
                            let admission = admissions[i]
                            if nativeText(admission, "userId").lowercased() != actor.lowercased() {
                                HStack {
                                    Text("\(nativeText(admission, "name")) · \(nativeText(admission, "status"))")
                                    Button(nativeText(admission, "status") == "admitted" ? "회수" : "승인") {
                                        Task { await command(nativeText(admission, "status") == "admitted" ? "revoke" : "admit", id: nativeText(meeting, "id"), payload: ["userId": nativeText(admission, "userId")]) }
                                    }.disabled(busy)
                                }
                            }
                        }
                    }
                }
            }
        }.sheet(item: $entry) { item in
            NavigationStack {
                VStack {
                    NativeJitsiConference(entry: item).frame(minHeight: 300)
                    if let scopeID = meetings.first(where: { nativeText($0, "id") == item.id })?["scopeId"] as? String {
                        NativeExecutiveRecordsView(kind: .minutes, scopeID: scopeID)
                    }
                }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("나가기 · 장치 끄기") { entry = nil } } }
            }
        }.task(id: "\(identity):\(tabActive):\(scenePhase == .active)") {
            boundIdentity = identity
            guard tabActive, scenePhase == .active, !identity.isEmpty else { return }
            await load()
            while !Task.isCancelled && identity == boundIdentity && tabActive && scenePhase == .active {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                guard !Task.isCancelled, identity == boundIdentity, tabActive, scenePhase == .active else { return }
                await load()
            }
        }.onDisappear { entry = nil; boundIdentity = "" }.refreshable { await load() }
    }
    @MainActor private func load() async {
        let expected = identity
        do {
            guard !expected.isEmpty, let result = try await session.api.rpc("meeting_snapshot", body: ["p_organization_id": organization]) as? [String: Any], nativeText(result, "actorId").lowercased() == actor.lowercased() else { throw NativeAPIError.invalidData }
            guard identity == expected, boundIdentity == expected else { return }
            snapshot = result
            if let active = entry, !(result["meetings"] as? [[String: Any]] ?? []).contains(where: { nativeText($0, "id") == active.id && nativeText($0, "admission") == "admitted" }) { entry = nil }
        } catch { if identity == expected { snapshot = [:]; entry = nil; self.error = error.localizedDescription } }
    }
    @MainActor private func command(_ action: String, id: String, payload: [String: Any] = [:]) async {
        guard !busy else { return }; busy = true; error = nil
        let expected = identity
        var body = payload; body["expectedActorId"] = actor
        do {
            body["revision"] = meetings.first(where: { nativeText($0, "id") == id })?["revision"]
            _ = try await session.api.rpc("meeting_command", body: ["p_action": action, "p_meeting_id": id, "p_payload": body])
            if identity == expected {
                await load()
                if action == "create", meetings.contains(where: { nativeText($0, "id") == id }) { createID = UUID().uuidString }
            }
        } catch { if identity == expected { self.error = error.localizedDescription } }
        if identity == expected { busy = false }
    }
    @MainActor private func join(_ meeting: [String: Any]) async {
        guard !busy, approved else { return }; busy = true; error = nil
        let expected = identity
        defer { if identity == expected { busy = false } }
        do {
            let audio = await AVCaptureDevice.requestAccess(for: .audio)
            let video = await AVCaptureDevice.requestAccess(for: .video)
            guard audio && video else { throw NativeAPIError.security("설정에서 카메라·마이크 권한을 허용한 뒤 다시 입장하세요.") }
            guard identity == expected else { return }
            guard let result = try await session.api.invokeFunction("meeting-access", body: ["meetingId": nativeText(meeting, "id"), "expectedActorId": actor]) as? [String: Any],
                  let host = result["host"] as? String, let room = result["room"] as? String, let jwt = result["jwt"] as? String, !jwt.isEmpty,
                  host != "meet.jit.si", host.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil else {
                throw NativeAPIError.security("전용 인증 회의 서버가 연결되지 않았습니다. 공개 회의로 대신 연결하지 않습니다.")
            }
            guard identity == expected else { return }
            entry = NativeMeetingEntry(id: nativeText(meeting, "id"), host: host, room: room, jwt: jwt)
        } catch { if identity == expected { self.error = error.localizedDescription } }
    }
}

#if canImport(JitsiMeetSDK)
private struct NativeJitsiConference: UIViewRepresentable {
    let entry: NativeMeetingEntry
    func makeUIView(context: Context) -> JitsiMeetView {
        let view = JitsiMeetView()
        let options = JitsiMeetConferenceOptions.fromBuilder { builder in
            builder.serverURL = URL(string: "https://\(entry.host)")
            builder.room = entry.room
            builder.token = entry.jwt
            builder.setAudioMuted(true)
            builder.setVideoMuted(true)
            builder.setFeatureFlag("recording.enabled", withBoolean: false)
            builder.setFeatureFlag("live-streaming.enabled", withBoolean: false)
            builder.setFeatureFlag("invite.enabled", withBoolean: false)
            builder.setFeatureFlag("call-integration.enabled", withBoolean: false)
            builder.setConfigOverride("prejoinConfig", with: ["enabled": true])
            builder.setConfigOverride("toolbarButtons", with: ["microphone", "camera", "tileview", "settings", "hangup"])
        }
        view.join(options)
        return view
    }
    func updateUIView(_ uiView: JitsiMeetView, context: Context) {}
    static func dismantleUIView(_ uiView: JitsiMeetView, coordinator: ()) { uiView.leave() }
}
#else
private struct NativeJitsiConference: View {
    let entry: NativeMeetingEntry
    var body: some View { Text("이 빌드에 공식 JitsiMeetSDK가 연결되지 않았습니다. 브라우저 회의로 대신 연결하지 않습니다.") }
}
#endif
