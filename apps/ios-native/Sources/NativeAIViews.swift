import SwiftUI

/// Reserved landing only: no prompt, provider or authenticated network requests.
struct NativeAIDraftView: View {
    var body: some View {
        List {
            Section("AI · 성경 도구") {
                Text("성경을 더 깊이 살펴볼 수 있는 도구를 이곳에 모을 예정입니다.")
            }
            Section("성경 지도 보기") {
                Text("성경 속 장소와 이동 경로를 살펴보는 도구")
                Text("링크 연결 예정").font(.footnote).foregroundStyle(NativePalette.muted)
            }
            Section("본문에 나온 이름 분석") {
                Text("본문에 등장하는 인물과 이름을 살펴보는 도구")
                Text("링크 연결 예정").font(.footnote).foregroundStyle(NativePalette.muted)
            }
            Section {
                Text("아직 연결된 도구가 없습니다. 현재 AI 생성 기능은 제공하지 않으며, 입력이나 개인정보를 외부로 전송하지 않습니다.").font(.footnote)
            }
        }.navigationTitle("성경 도구").nativePageStyle()
    }
}
