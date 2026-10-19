import SwiftUI

enum NativeLoginAssurance {
    static func verifiedFactors(_ user: [String: Any]) -> [[String: Any]] {
        (user["factors"] as? [[String: Any]] ?? []).filter { nativeText($0, "status") == "verified" && UUID(uuidString: nativeText($0, "id")) != nil }
    }
    /// Routing hint only. Auth verifies the token; RLS and sensitive RPCs remain authoritative.
    static func hasAAL2(_ accessToken: String) -> Bool {
        let parts = accessToken.split(separator: ".")
        guard parts.count == 3 else { return false }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return claims["aal"] as? String == "aal2"
    }
    static func validCode(_ value: String) -> Bool { value.utf8.count == 6 && value.allSatisfy { $0 >= "0" && $0 <= "9" } }
}

struct NativeLoginMFAView: View {
    @EnvironmentObject private var session: NativeSession
    @State private var factorID = ""
    @State private var code = ""
    private var factors: [[String: Any]] { session.enrolledLoginFactors.filter { nativeText($0, "factor_type") == "totp" } }
    var body: some View {
        NavigationStack {
            Form {
                Section("기존에 등록한 인증 앱 확인") {
                    Text("이 계정에 이미 등록된 MFA를 확인합니다. 새 인증 앱 등록을 요구하는 화면이 아닙니다.")
                    if factors.isEmpty {
                        Text("현재 등록한 인증 수단은 이 화면에서 확인할 수 없습니다. 기존 계정 복구 절차를 이용해 주세요. MFA를 건너뛰어 공동체에 입장하지 않습니다.").foregroundStyle(.secondary)
                    } else {
                        Picker("등록한 인증 수단", selection: $factorID) {
                            ForEach(factors.indices, id: \.self) { index in
                                Text(nativeText(factors[index], "friendly_name", fallback: "인증 앱")).tag(nativeText(factors[index], "id"))
                            }
                        }
                        TextField("6자리 인증번호", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                        Button("로그인 인증 확인") { Task { await session.verifyLoginFactor(id: factorID, code: code); code = "" } }
                            .frame(minHeight: 44).disabled(!NativeLoginAssurance.validCode(code) || factorID.isEmpty)
                    }
                    if let error = session.error { Text(error).foregroundStyle(.red) }
                }
                Section {
                    NavigationLink("계정 삭제·예약 취소") { NativeAccountDeletionView() }
                    NavigationLink("성경 본문 · 오프라인 읽기") { NativeBibleReaderView() }
                    Button("다른 계정으로 로그인", role: .destructive) { Task { await session.signOut() } }.frame(minHeight: 44)
                }
            }.navigationTitle("로그인 보안 확인").nativePageStyle().disabled(session.loading)
                .task { factorID = factors.first.map { nativeText($0, "id") } ?? "" }
                .onDisappear { code = "" }
        }
    }
}
