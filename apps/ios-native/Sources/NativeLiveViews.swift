import SwiftUI
import WebKit

struct NativeChurchLiveView: View {
    @EnvironmentObject private var session: NativeSession
    private var identity: String { nativeMeetingIdentity(session) }
    var body: some View {
        Group {
            if identity.isEmpty { Text("교회 가입 승인과 현재 동의 후 라이브를 이용하세요.") }
            else { NativeLiveWorkspace().id(identity) }
        }.navigationTitle("교회 라이브")
    }
}

private struct NativeLiveWorkspace: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.nativeTabActive) private var tabActive
    @State private var snapshot: [String: Any] = [:]
    @State private var error: String?
    @State private var busy = false
    @State private var playing = false
    @State private var url = ""
    @State private var title = ""
    @State private var bulletin = ""
    @State private var rights = false
    @State private var message = ""
    @State private var messageID = UUID().uuidString
    @State private var boundIdentity = ""
    private var identity: String { nativeMeetingIdentity(session) }
    private var actor: String { nativeText(session.context["profile"] as? [String: Any] ?? [:], "id") }
    private var organization: String { nativeText(session.context["membership"] as? [String: Any] ?? [:], "organization_id") }
    private var stream: [String: Any] { snapshot["stream"] as? [String: Any] ?? [:] }
    private var live: Bool {
        nativeText(stream, "state") == "live" && (nativeLiveDate(nativeText(stream, "expires_at")) ?? .distantPast) > Date()
    }
    var body: some View {
        List {
            Section("외부 서비스·공개 영상 안내") {
                Text("앱의 회원 권한은 YouTube 영상 자체를 비공개로 만들지 않습니다. 공개·일부공개 영상은 외부인도 볼 수 있습니다. 재생하면 YouTube(Google)에 IP·장치 정보가 전송되며 해당 서비스 약관이 적용됩니다.")
            }
            if let error { Text(error).foregroundStyle(.red) }
            Section(nativeText(stream, "title", fallback: "등록된 방송이 없습니다")) {
                Text(live ? "LIVE" : nativeText(stream, "state") == "paused" ? "방송 일시중지" : "방송 종료 / 대기")
                if live {
                    if playing {
                        NativeYouTubePlayer(videoID: nativeText(stream, "video_id")).id(nativeText(stream, "video_id")).frame(height: 235)
                        Button("내 재생 중지 · YouTube 연결 해제") { playing = false }
                    } else { Button("외부 서비스 안내 확인 · 재생") { playing = true } }
                }
            }
            Section("오늘의 주보") { Text(nativeText(stream, "bulletin", fallback: "등록된 주보가 없습니다.")) }
            Section("라이브 아멘 채널") {
                let messages = snapshot["messages"] as? [[String: Any]] ?? []
                ForEach(messages.indices, id: \.self) { i in
                    let row = messages[i]
                    HStack {
                        VStack(alignment: .leading) { Text(nativeText(row, "senderName")).font(.caption.bold()); Text(nativeText(row, "body")) }
                        if snapshot["canBroadcast"] as? Bool == true {
                            Button("숨기기") { Task { await command("hide", payload: ["id": nativeText(row, "id")]) } }.disabled(busy)
                        }
                    }
                }
                TextField("아멘·메시지 (500자)", text: $message).onChange(of: message) { _ in messageID = UUID().uuidString }
                Button("전송") { Task { await command("amen", payload: ["id": messageID, "body": message]) } }.disabled(!live || busy || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.count > 500)
                Button("아멘") { Task { await command("amen", payload: ["id": UUID().uuidString, "body": "아멘"]) } }.disabled(!live || busy)
            }
            if snapshot["canBroadcast"] as? Bool == true {
                Section("교회 방송 관리") {
                    Text("현재 교회 회장·총무만 제어합니다. Google 재인증이 필요합니다. 앱 방송 노출은 8시간 후 자동 종료됩니다. 실제 YouTube 송출 중단은 YouTube Studio에서 직접 실행해야 합니다.")
                    TextField("YouTube URL", text: $url).textInputAutocapitalization(.never).keyboardType(.URL)
                    TextField("방송 제목", text: $title)
                    TextEditor(text: $bulletin).frame(minHeight: 100).accessibilityLabel("주보")
                    Toggle("영상·음악 권리와 촬영 대상 동의 확인", isOn: $rights)
                    Button("방송 시작 / 변경") { Task { await command("start", payload: ["url": url, "title": title, "bulletin": bulletin, "rightsConfirmed": rights]) } }.disabled(busy || !rights || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("앱 방송 일시중지") { Task { await command("pause") } }.disabled(busy || !live)
                    Button("다시 노출") { Task { await command("resume") } }.disabled(busy || nativeText(stream, "state") != "paused")
                    Button("앱 방송 중단", role: .destructive) { Task { await command("stop") } }.disabled(busy || stream.isEmpty || nativeText(stream, "state") == "stopped")
                }
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
        }.refreshable { await load() }.onDisappear { playing = false; boundIdentity = "" }
            .onChange(of: scenePhase) { phase in if phase != .active { playing = false } }
    }
    @MainActor private func load() async {
        let expected = identity
        do {
            guard !expected.isEmpty, let result = try await session.api.rpc("church_live_snapshot", body: ["p_organization_id": organization]) as? [String: Any], nativeText(result, "actorId").lowercased() == actor.lowercased() else { throw NativeAPIError.invalidData }
            guard identity == expected, boundIdentity == expected else { return }
            snapshot = result
            if !live { playing = false }
        } catch { if identity == expected { snapshot = [:]; playing = false; self.error = error.localizedDescription } }
    }
    @MainActor private func command(_ action: String, payload: [String: Any] = [:]) async {
        guard !busy else { return }; busy = true; error = nil
        let expected = identity
        var value = payload; value["expectedActorId"] = actor; value["revision"] = stream["revision"] as? Int ?? 0
        do {
            _ = try await session.api.rpc("church_live_command", body: ["p_organization_id": organization, "p_action": action, "p_payload": value])
            if identity == expected { if action == "amen" { message = ""; messageID = UUID().uuidString }; await load() }
        } catch { if identity == expected { self.error = "\(error.localizedDescription) 방송 제어는 Google 재인증이 필요할 수 있습니다."; await load() } }
        if identity == expected { busy = false }
    }
}

private func nativeLiveDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

/// YouTube officially supports IFrame API in WKWebView, not AVPlayer extraction.
/// Nonpersistent data store and no page load before the user's explicit consent.
private struct NativeYouTubePlayer: UIViewRepresentable {
    let videoID: String
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: config)
        view.scrollView.isScrollEnabled = false
        guard videoID.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else { return view }
        view.loadHTMLString("""
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
        <body style="margin:0;background:black"><iframe title="교회 YouTube 라이브" style="position:absolute;width:100%;height:100%;border:0" src="https://www.youtube-nocookie.com/embed/\(videoID)?playsinline=1&autoplay=1" allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe></body></html>
        """, baseURL: NativeConfig.url)
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {
        uiView.stopLoading()
        uiView.loadHTMLString("<html></html>", baseURL: nil)
    }
}

struct NativeLiveHomeBanner: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.nativeTabActive) private var tabActive
    @Environment(\.scenePhase) private var scenePhase
    @State private var stream: [String: Any] = [:]
    @State private var loadedIdentity = ""
    private var identity: String { nativeMeetingIdentity(session) }
    var body: some View {
        Group {
            if !identity.isEmpty, loadedIdentity == identity, nativeText(stream, "state") == "live",
               (nativeLiveDate(nativeText(stream, "expires_at")) ?? .distantPast) > Date() {
                NavigationLink { NativeChurchLiveView() } label: {
                    Label("LIVE · \(nativeText(stream, "title"))", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.red)
                }
            }
        }.task(id: "\(identity):\(tabActive):\(scenePhase == .active)") {
            stream = [:]; loadedIdentity = ""
            let expected = identity
            guard tabActive, scenePhase == .active, !expected.isEmpty else { return }
            while !Task.isCancelled && tabActive && scenePhase == .active && identity == expected {
                let org = nativeText(session.context["membership"] as? [String: Any] ?? [:], "organization_id")
                do {
                    let result = try await session.api.rpc("church_live_snapshot", body: ["p_organization_id": org]) as? [String: Any] ?? [:]
                    guard identity == expected else { return }
                    stream = result["stream"] as? [String: Any] ?? [:]; loadedIdentity = expected
                } catch { if identity == expected { stream = [:] } }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }
}
