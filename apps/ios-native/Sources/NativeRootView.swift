import SwiftUI

enum NativeRootRoute: Equatable {
    case login, consent, community, onboarding
    static func resolve(loading _: Bool, signedIn: Bool, consentRequired: Bool, administrator: Bool, activeMember: Bool) -> Self {
        // Busy state must never remove forms or their in-memory consent choices.
        guard signedIn else { return .login }
        guard !consentRequired else { return .consent }
        return administrator || activeMember ? .community : .onboarding
    }
}

struct NativeRootView: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            switch NativeRootRoute.resolve(
                loading: session.loading,
                signedIn: session.signedIn,
                consentRequired: session.consentRequired,
                administrator: session.context["is_platform_admin"] as? Bool == true,
                activeMember: (session.context["membership"] as? [String: Any])?["status"] as? String == "active"
            ) {
            case .login: NativeLoginView()
            case .consent: NativeConsentView()
            case .community: NativeCommunityTabs()
            case .onboarding: NativeOnboardingView()
            }
        }
        .disabled(session.loading)
        .overlay(alignment: .top) {
            if session.loading {
                ProgressView("처리 중입니다")
                    .padding().background(.regularMaterial, in: Capsule())
                    .padding(.top, 12).accessibilityAddTraits(.updatesFrequently)
            }
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

struct NativeLoginView: View {
    @EnvironmentObject private var session: NativeSession
    @State private var email = ""
    @State private var password = ""
    @State private var submitting = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    NativeBrandHeader()
                    VStack(alignment: .leading, spacing: 9) {
                        Text("로그인").font(.largeTitle.weight(.bold)).tracking(-1)
                            .foregroundStyle(NativePalette.ink)
                        Text("가입한 계정으로 공동체 소식을 확인하세요.")
                            .font(.subheadline).foregroundStyle(NativePalette.muted).lineSpacing(4)
                    }
                    Button { run { await session.googleSignIn() } } label: {
                        Label("Google로 계속하기", systemImage: "person.crop.circle")
                    }.buttonStyle(NativeGoogleButtonStyle()).disabled(submitting)
                    Text("처음 이용하는 Google 계정은 인증 후 회원가입 동의 화면으로 이어집니다.")
                        .font(.caption).foregroundStyle(NativePalette.muted)
                    HStack { Rectangle().frame(height: 1); Text("또는 이메일로 로그인").font(.caption).fixedSize(); Rectangle().frame(height: 1) }
                        .foregroundStyle(NativePalette.muted)
                    VStack(alignment: .leading, spacing: 14) {
                                Text("이메일").font(.caption.weight(.semibold)).foregroundStyle(NativePalette.muted)
                                TextField("이메일 주소", text: $email, prompt: Text("이메일 주소").foregroundColor(NativePalette.muted))
                                    .textContentType(.username).keyboardType(.emailAddress)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled().nativeAuthFieldStyle()
                                Text("비밀번호").font(.caption.weight(.semibold)).foregroundStyle(NativePalette.muted)
                                SecureField("비밀번호", text: $password, prompt: Text("비밀번호").foregroundColor(NativePalette.muted))
                                    .textContentType(.password).nativeAuthFieldStyle()
                                Button("로그인") {
                                    run { await session.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password) }
                                }.buttonStyle(NativePrimaryButtonStyle())
                                    .disabled(submitting || email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                    }
                    NavigationLink { NativeSignupEntryView() } label: {
                        HStack { Text("아직 계정이 없으신가요?").foregroundStyle(NativePalette.muted); Text("회원가입").fontWeight(.semibold) }
                            .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                    }.disabled(submitting)
                    if submitting { ProgressView("로그인 중") }
                    if let error = session.error, !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                    }
                    HStack {
                        Text("Google 계정의 비밀번호는 Google에서 복구하세요.").font(.caption).foregroundStyle(NativePalette.muted)
                        Spacer()
                        Button("연결 확인") { Task { await session.restore() } }.font(.caption).frame(minHeight: 44).disabled(submitting)
                    }
                }.frame(maxWidth: 470).padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 44).frame(maxWidth: .infinity)
            }.background(NativePalette.surface).foregroundStyle(NativePalette.ink).scrollDismissesKeyboard(.interactively)
                .toolbar(.hidden, for: .navigationBar)
                .alert("로그인 안내", isPresented: Binding(
                    get: { session.error != nil },
                    set: { if !$0 { session.error = nil } }
                )) {
                    Button("확인") { session.error = nil }
                } message: { Text(session.error ?? "") }
        }
    }
    private func run(_ operation: @escaping @MainActor () async -> Void) {
        guard !submitting else { return }
        submitting = true
        Task { await operation(); password = ""; submitting = false }
    }
}

/// Auth establishes identity only. The root's server consent gate owns service signup.
private struct NativeSignupEntryView: View {
    @EnvironmentObject private var session: NativeSession
    @State private var submitting = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                NativeBrandHeader()
                Text("회원가입").font(.largeTitle.bold()).foregroundStyle(NativePalette.ink)
                Text("Google 계정으로 본인을 확인한 뒤 가입을 진행합니다.").font(.subheadline).foregroundStyle(NativePalette.muted)
                Button {
                    guard !submitting else { return }
                    submitting = true
                    Task { await session.googleSignIn(); submitting = false }
                } label: { Label("Google 계정으로 가입 시작", systemImage: "person.crop.circle") }
                    .buttonStyle(NativeGoogleButtonStyle()).disabled(submitting)
                Text("신규 계정은 인증 후 필수 동의와 만 14세 이상 여부를 확인하고, 소속 노회·교회와 역할을 선택합니다. 승인 전에는 공동체 정보에 접근할 수 없습니다.")
                    .font(.footnote).foregroundStyle(NativePalette.muted).lineSpacing(4)
                Text("이미 가입한 Google 계정이면 기존 계정으로 로그인합니다.").font(.caption).foregroundStyle(NativePalette.muted)
                if submitting { ProgressView("Google 계정을 확인하고 있습니다") }
                if let error = session.error { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red) }
            }.frame(maxWidth: 470).padding(20).frame(maxWidth: .infinity)
        }.navigationTitle("회원가입").navigationBarTitleDisplayMode(.inline).nativePageStyle()
            .toolbar(.visible, for: .navigationBar)
            .interactiveDismissDisabled(submitting)
    }
}

private struct NativeConsentView: View {
    @EnvironmentObject private var session: NativeSession
    @State private var accepted: Set<String> = []
    @State private var read: Set<String> = []
    @State private var selected: NativeLegalDocument?
    @State private var ageConfirmed = false
    @State private var submitting = false
    private var documents: [NativeLegalDocument] { session.requiredDocuments.compactMap(NativeLegalDocument.init).sorted { $0.displayOrder < $1.displayOrder } }
    private var validContract: Bool {
        documents.count == 5 && Set(documents.map(\.type)) == Set(["privacy_policy", "sensitive_information", "overseas_transfer", "terms_of_service", "community_guidelines"])
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NativeBrandHeader().padding(.vertical, 8)
                    Text("가입·이용을 위한 필수 동의").font(.title2.bold())
                    Text("새로 이용하는 계정은 가입 동의가 필요합니다. 기존 회원은 필수 문서가 갱신된 경우에만 다시 확인합니다. 동의 전에는 공동체 정보에 접근하지 않습니다.")
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
                    Button("동의 저장하고 계속하기") {
                        submitting = true
                        Task { await session.acceptConsents(acceptedDocumentIDs: accepted, ageConfirmed: ageConfirmed); submitting = false }
                    }.buttonStyle(NativePrimaryButtonStyle())
                        .disabled(!validContract || accepted != Set(documents.map(\.id)) || !ageConfirmed || submitting)
                    if submitting { ProgressView("동의를 저장하고 있습니다") }
                    if let error = session.error { Text(error).foregroundStyle(.red) }
                    if !validContract { Text("필수 문서 구성이 올바르지 않습니다. 다시 불러와 주세요.").foregroundStyle(.red) }
                    Button("다시 불러오기") { Task { await session.restore() } }.disabled(submitting)
                    Button("로그아웃", role: .destructive) { Task { await session.signOut() } }.disabled(submitting)
                    NavigationLink("개인 통독·QT 동의 철회·삭제") { NativeFaithWithdrawalView() }
                }
            }.navigationTitle("필수 동의").nativePageStyle()
                .onChange(of: documents.map(\.id).sorted()) { _, _ in
                    accepted = []; read = []; ageConfirmed = false; selected = nil
                }
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
    // Display only. The validated legal contract and stored acceptance stay unchanged.
    var displayOrder: Int {
        ["privacy_policy", "sensitive_information", "overseas_transfer", "terms_of_service", "community_guidelines"].firstIndex(of: type) ?? 5
    }
    var consentLabel: String {
        ["privacy_policy": "개인정보 수집·이용 동의", "sensitive_information": "종교 관련 민감정보 처리 동의", "overseas_transfer": "개인정보 국외 이전 동의", "terms_of_service": "이용약관 동의", "community_guidelines": "공동체 운영정책 동의"][type] ?? title
    }
    var summary: String {
        switch type {
        case "privacy_policy": return "계정 생성과 공동체 기능 제공에 필요한 개인정보 항목·목적·보유기간을 확인합니다."
        case "sensitive_information": return "노회·교회·직분·역할 등 종교 관련 정보의 처리 목적과 거부 영향을 확인합니다."
        case "overseas_transfer": return "국외 처리 제공자, 이전 항목·목적·보유기간을 확인합니다."
        case "terms_of_service": return "서비스 이용 조건과 회원의 권리·의무를 확인합니다."
        default: return "신고, 차단, 콘텐츠 조치와 공동체 안의 존중·안전 기준을 확인합니다."
        }
    }
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
