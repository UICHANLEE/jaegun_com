import Foundation

enum NativeConfig {
    // Invalid configuration is rejected by NativeAPI's exact HTTPS host guard,
    // never an initialization crash or a fallback to a live unconfigured server.
    static let url = URL(string: Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? "") ?? URL(string: "https://invalid.example")!
    static let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_PUBLIC_KEY") as? String ?? ""
}
