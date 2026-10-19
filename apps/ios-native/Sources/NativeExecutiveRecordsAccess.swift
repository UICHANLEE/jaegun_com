import SwiftUI

/// Safe to place outside a primary church-role branch. Only server-authorized scopes expose links.
struct NativeExecutiveRecordLinks: View {
    var eventID: String? = nil
    var scopeID: String? = nil
    @EnvironmentObject private var session: NativeSession
    @State private var scopes: [[String: Any]] = []
    @State private var loadedIdentity = ""
    private var allowed: Bool { session.signedIn && !session.consentRequired }
    private var identity: String { session.sessionGeneration.uuidString + String(allowed) + (eventID ?? "") + ":" + (scopeID ?? "") }
    var body: some View {
        Group {
            if allowed, loadedIdentity == identity, !scopes.isEmpty {
                Section("권한 범위의 임원 기록") {
                    Text("총회·노회·교회·명시적 행사별 독립 기록 · 서버가 확인한 \(scopes.count)개 범위").font(.footnote)
                    NavigationLink("회의록·변경 이력") { NativeExecutiveRecordsView(kind: .minutes, scopeID: scopeID, eventID: eventID) }
                    NavigationLink("독립 장부·영수증·결산") { NativeExecutiveRecordsView(kind: .finance, scopeID: scopeID, eventID: eventID) }
                }
            }
        }.task(id: identity) {
            scopes = []; guard allowed else { return }; let generation = session.sessionGeneration
            do {
                let rows = try await session.api.rpc("list_scoped_record_scopes") as? [[String: Any]] ?? []
                guard allowed, generation == session.sessionGeneration, !Task.isCancelled else { return }
                scopes = rows.filter { (eventID == nil || nativeText($0,"event_id") == eventID) && (scopeID == nil || nativeText($0,"scope_id") == scopeID) }; loadedIdentity = identity
            } catch { if generation == session.sessionGeneration { scopes = [] } }
        }.onChange(of: session.sessionGeneration) { _, _ in scopes = [] }
            .onChange(of: session.consentRequired) { _, required in if required { scopes = [] } }
            .onChange(of: session.signedIn) { _, signed in if !signed { scopes = [] } }
    }
}
