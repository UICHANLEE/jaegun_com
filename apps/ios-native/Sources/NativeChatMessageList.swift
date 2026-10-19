import SwiftUI

/// Initial reads and confirmed sends request a jump; manual refresh does not
/// steal the reader's position. The latest button remains an explicit escape.
struct NativeChatMessageList<Content: View>: View {
    let scrollRequest: UUID
    let refresh: () async -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            List {
                content()
                Color.clear.frame(height: 44).listRowSeparator(.hidden).id("native-chat-latest")
            }.listStyle(.plain).refreshable { await refresh() }
                .onChange(of: scrollRequest) { _, _ in proxy.scrollTo("native-chat-latest", anchor: .bottom) }
                .overlay(alignment: .bottomTrailing) {
                    Button { withAnimation { proxy.scrollTo("native-chat-latest", anchor: .bottom) } } label: {
                        Label("최근 메시지", systemImage: "arrow.down").font(.caption.bold()).padding(10).background(.regularMaterial, in: Capsule())
                    }.padding(8)
                }
        }
    }
}
