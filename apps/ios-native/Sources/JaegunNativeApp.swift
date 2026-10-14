import SwiftUI

@main
struct JaegunNativeApp: App {
    @StateObject private var session = NativeSession()
    var body: some Scene {
        WindowGroup {
            NativeRootView()
                .environmentObject(session)
                .tint(Color(UIColor { traits in
                    traits.userInterfaceStyle == .dark
                        ? UIColor(red: 0.58, green: 0.84, blue: 0.40, alpha: 1)
                        : UIColor(red: 0.13, green: 0.36, blue: 0.24, alpha: 1)
                }))
                .task { await session.restore() }
        }
    }
}
