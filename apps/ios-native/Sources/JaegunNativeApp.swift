import SwiftUI

@main
struct JaegunNativeApp: App {
    @StateObject private var session = NativeSession()
    @AppStorage("jaegun.appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup {
            NativeRootView()
                .environmentObject(session)
                .preferredColorScheme(NativeAppearance(rawValue: appearance)?.colorScheme)
                .tint(NativePalette.forest)
                .task { await session.restore() }
        }
    }
}
