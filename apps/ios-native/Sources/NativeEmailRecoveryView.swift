import SwiftUI

enum NativeRecoveryPolicy {
    static func validPassword(_ value: String) -> Bool {
        (12...128).contains(value.utf16.count) && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    static func valid(email: String, code: String, password: String) -> Bool {
        email.contains("@") && email.utf8.count <= 254 && code.utf8.count == 6
            && code.allSatisfy { $0 >= "0" && $0 <= "9" } && validPassword(password)
    }
}

struct NativeEmailRecoveryView: View {
    @EnvironmentObject private var session: NativeSession
    @State private var email = ""
    @State private var code = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var busy = false
    @State private var sent = false
    @State private var notice: String?
    @State private var error: String?
    @State private var ticket = UUID()
    var body: some View {
        Form {
            Section("가입한 이메일") {
                TextField("이메일", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.emailAddress)
                Button(sent ? "인증 메일 다시 요청" : "비밀번호 재설정 메일 요청") { Task { await request() } }.frame(minHeight: 44).disabled(!email.contains("@") || email.utf8.count > 254)
                Text("등록 여부와 관계없이 같은 안내를 표시합니다. Google 계정 비밀번호는 Google에서 복구해 주세요.").font(.footnote).foregroundStyle(.secondary)
            }
            if sent {
                Section("이메일 인증번호로 재설정") {
                    TextField("6자리 인증번호", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    SecureField("새 비밀번호 (12~128자)", text: $password).textContentType(.newPassword)
                    SecureField("새 비밀번호 확인", text: $confirmation).textContentType(.newPassword)
                    Button("새 비밀번호 저장") { Task { await reset() } }.frame(minHeight: 44)
                        .disabled(password != confirmation || !NativeRecoveryPolicy.valid(email: email.trimmingCharacters(in: .whitespacesAndNewlines), code: code, password: password))
                }
            }
            if let notice { Section { Text(notice) } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }.navigationTitle("비밀번호 재설정").navigationBarTitleDisplayMode(.inline).nativePageStyle()
            .toolbar(.visible, for: .navigationBar)
            .disabled(busy || session.loading).overlay { if busy { ProgressView("처리 중입니다") } }
            .onDisappear { ticket = UUID(); code = ""; password = ""; confirmation = "" }
    }
    private func request() async {
        guard !busy else { return }
        let request = ticket; busy = true; error = nil
        defer { if ticket == request { busy = false } }
        do {
            try await session.api.requestPasswordRecovery(email: email.trimmingCharacters(in: .whitespacesAndNewlines))
            guard ticket == request, !Task.isCancelled else { return }
            sent = true; notice = "해당 이메일로 가입한 계정이 있다면 인증 메일이 발송됩니다. 받은 편지함과 스팸함을 확인해 주세요."
        } catch { guard ticket == request else { return }; self.error = "메일 요청을 처리하지 못했습니다. 연결과 요청 한도를 확인해 주세요." }
    }
    private func reset() async {
        guard !busy, password == confirmation else { return }
        let request = ticket; busy = true; error = nil
        defer { if ticket == request { busy = false } }
        do {
            try await session.api.resetRecoveredPassword(email: email.trimmingCharacters(in: .whitespacesAndNewlines), code: code, password: password)
            guard ticket == request, !Task.isCancelled else { return }
            password = ""; confirmation = ""; code = ""; sent = false
            notice = "비밀번호를 변경했습니다. 로그인 화면으로 돌아가 새 비밀번호로 로그인해 주세요."
        } catch { guard ticket == request else { return }; self.error = "인증번호가 만료되었거나 변경 결과를 확인하지 못했습니다. 새 메일을 요청하거나 로그인 화면에서 확인해 주세요. 자동 재시도하지 않습니다." }
    }
}
