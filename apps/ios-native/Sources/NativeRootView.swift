import SwiftUI

struct NativeRootView: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            if session.loading { ProgressView("계정을 확인하고 있습니다") }
            else if !session.signedIn { NativeLoginView() }
            else if session.consentRequired { NativeConsentView() }
            else if session.context["is_platform_admin"] as? Bool == true ||
                        (session.context["membership"] as? [String: Any])?["status"] as? String == "active" {
                NativeCommunityTabs()
            } else { NativeOnboardingView() }
        }
        .privacySensitive()
        .overlay {
            if scenePhase != .active {
                Color(.systemBackground).ignoresSafeArea()
                    .overlay { Text("재건 공동체").font(.headline) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await session.restore() } }
        }
    }
}

private struct NativeMembershipStatusView: View {
    @EnvironmentObject private var session: NativeSession
    private var application: [String: Any] {
        (session.context["latest_application"] ?? session.context["pending_application"]) as? [String: Any] ?? [:]
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("교회 가입 상태") {
                    if nativeText(application, "status") == "pending" {
                        Label("가입 승인을 기다리고 있습니다", systemImage: "clock")
                        Text("승인된 교회 구성원만 공동체 소식과 채널에 접근할 수 있습니다.")
                    } else {
                        Label("승인된 교회 소속이 없습니다", systemImage: "person.badge.clock")
                        Text("네이티브 교회 선택·가입 신청 화면은 전환 작업 중입니다. 승인 없이 공동체 데이터에 접근하지 않습니다.")
                    }
                }
                Section {
                    Button("가입 상태 다시 확인") { Task { await session.restore() } }.frame(minHeight: 44)
                    Button("로그아웃", role: .destructive) { Task { await session.signOut() } }.frame(minHeight: 44)
                    if let error = session.error { Text(error).foregroundStyle(.red) }
                }
            }.navigationTitle("교회 가입")
        }
    }
}

private struct NativeLoginView: View {
    @EnvironmentObject private var session: NativeSession
    @State private var email = ""
    @State private var password = ""
    @State private var submitting = false
    @State private var ageConfirmed = false
    @State private var acceptedDocuments: Set<String> = []
    @State private var readDocuments: Set<String> = []
    @State private var selectedDocument: NativeLegalDocument?
    private var documents: [NativeLegalDocument] { session.requiredDocuments.compactMap(NativeLegalDocument.init) }
    private var canUseGoogle: Bool {
        ageConfirmed && documents.count == 5 && documents.allSatisfy { acceptedDocuments.contains($0.id) }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("재건 공동체").font(.largeTitle.bold())
                    Text("계정으로 로그인하세요.").foregroundStyle(.secondary)
                }
                Section("간편 로그인") {
                    Toggle("만 14세 이상입니다", isOn: $ageConfirmed)
                    Text("Google로 처음 가입하기 전 문서와 연령을 확인합니다. 계정 생성 후에도 본인이 동의를 저장해야 공동체 기능을 이용할 수 있습니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(documents) { document in
                        Button(document.title + " 전문 읽기") { selectedDocument = document }.frame(minHeight: 44)
                        Toggle(document.title + "에 동의합니다", isOn: Binding(
                            get: { acceptedDocuments.contains(document.id) },
                            set: { if $0 { acceptedDocuments.insert(document.id) } else { acceptedDocuments.remove(document.id) } }
                        )).disabled(!readDocuments.contains(document.id))
                    }
                    Button { run { await session.googleSignIn() } } label: {
                        Label("Google로 계속하기", systemImage: "person.crop.circle")
                            .frame(minHeight: 44)
                    }.disabled(submitting || !canUseGoogle)
                }
                Section("이메일 로그인") {
                    TextField("이메일", text: $email)
                        .textContentType(.username).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("비밀번호", text: $password).textContentType(.password)
                    Button("로그인") {
                        run { await session.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password) }
                    }.frame(minHeight: 44).disabled(submitting || email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                }
                if submitting { ProgressView("로그인 중") }
                if let error = session.error, !error.isEmpty {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                Section {
                    Text("이 iPhone 앱은 SwiftUI로 구현되었습니다. 로그인은 안전한 시스템 인증 창에서 완료하고 앱으로 돌아옵니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("연결 다시 확인") { Task { await session.restore() } }.disabled(submitting)
                }
            }.navigationTitle("로그인").navigationBarTitleDisplayMode(.inline)
                .sheet(item: $selectedDocument) { document in
                    NativeLegalView(document: document) { readDocuments.insert(document.id); selectedDocument = nil }
                }
        }
    }
    private func run(_ operation: @escaping @MainActor () async -> Void) {
        submitting = true
        Task { await operation(); password = ""; submitting = false }
    }
}

private struct NativeConsentView: View {
    @EnvironmentObject private var session: NativeSession
    @State private var accepted: Set<String> = []
    @State private var read: Set<String> = []
    @State private var selected: NativeLegalDocument?
    @State private var ageConfirmed = false
    @State private var submitting = false
    private var documents: [NativeLegalDocument] { session.requiredDocuments.compactMap(NativeLegalDocument.init) }
    private var validContract: Bool {
        documents.count == 5 && Set(documents.map(\.type)) == Set(["privacy_policy", "sensitive_information", "overseas_transfer", "terms_of_service", "community_guidelines"])
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("처음 이용하기 전 필수 확인").font(.title2.bold())
                    Text("각 문서를 읽은 뒤 본인이 동의 여부를 선택해 주세요. 동의 전에는 공동체 정보에 접근하지 않습니다.")
                        .foregroundStyle(.secondary)
                }
                ForEach(documents) { document in
                    Section(document.title) {
                        Text("문서 버전: \(document.version)").font(.footnote).foregroundStyle(.secondary)
                        Button("전문 읽기") { selected = document }.frame(minHeight: 44)
                        Toggle("[필수] 동의합니다", isOn: Binding(
                            get: { accepted.contains(document.id) },
                            set: { value in if value { accepted.insert(document.id) } else { accepted.remove(document.id) } }
                        )).disabled(!read.contains(document.id) || submitting)
                    }
                }
                Section {
                    Toggle("만 14세 이상입니다", isOn: $ageConfirmed).disabled(submitting)
                    Button("동의 저장") {
                        submitting = true
                        Task { await session.acceptConsents(); submitting = false }
                    }.frame(minHeight: 44)
                        .disabled(!validContract || accepted.count != documents.count || !ageConfirmed || submitting)
                    if submitting { ProgressView("동의를 저장하고 있습니다") }
                    if let error = session.error { Text(error).foregroundStyle(.red) }
                    if !validContract { Text("필수 문서 구성이 올바르지 않습니다. 다시 불러와 주세요.").foregroundStyle(.red) }
                    Button("다시 불러오기") { Task { await session.restore() } }.disabled(submitting)
                    Button("로그아웃", role: .destructive) { Task { await session.signOut() } }.disabled(submitting)
                }
            }.navigationTitle("필수 동의")
                .sheet(item: $selected) { document in
                    NativeLegalView(document: document) { read.insert(document.id); selected = nil }
                }
        }
    }
}

struct NativeLegalDocument: Identifiable {
    let type: String
    let version: String
    let title: String
    var id: String { "\(type)-\(version)" }
    init?(_ row: [String: Any]) {
        guard let type = (row["document_key"] ?? row["document_type"] ?? row["documentType"] ?? row["key"]) as? String,
              let version = row["version"] as? String else { return nil }
        self.type = type; self.version = version
        self.title = ["privacy_policy": "개인정보 수집·이용 동의", "sensitive_information": "종교 관련 민감정보 처리 동의", "overseas_transfer": "국외 이전 동의", "terms_of_service": "이용약관", "community_guidelines": "커뮤니티 이용규칙"][type] ?? type
    }
    var text: String? {
        guard let url = Bundle.main.url(forResource: "LegalDocuments", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let documents = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let document = documents.first(where: { $0["key"] as? String == type && $0["version"] as? String == version }),
              let sections = document["sections"] as? [[String: Any]], !sections.isEmpty else { return nil }
        let summary = document["summary"] as? String ?? ""
        return ([title, "문서 버전: \(version)", summary] + sections.map {
            "\($0["heading"] as? String ?? "")\n\($0["body"] as? String ?? "")"
        }).joined(separator: "\n\n")
    }
}

struct NativeLegalView: View {
    let document: NativeLegalDocument
    let onRead: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reachedEnd = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let text = document.text {
                        Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Text("문서 끝").foregroundStyle(.secondary).onAppear { reachedEnd = true }
                    } else {
                        ContentUnavailableView("문서를 불러올 수 없습니다", systemImage: "doc.badge.exclamationmark", description: Text("이 버전의 문서가 앱에 포함되지 않았습니다. 동의는 저장되지 않습니다."))
                    }
                }.padding()
            }.navigationTitle(document.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("확인") { onRead() }.disabled(!reachedEnd || document.text == nil)
                    }
                }
        }
    }
}
