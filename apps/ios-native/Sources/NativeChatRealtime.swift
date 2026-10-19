import Foundation
import SwiftUI

struct NativeRealtimeChange: Equatable {
    let table: String
    let filter: String?
    var payload: [String: Any] {
        var value: [String: Any] = ["event":"*", "schema":"public", "table":table]
        if let filter { value["filter"] = filter }
        return value
    }
}

enum NativeRealtimePolicy {
    static func retryDelay(_ attempt: Int) -> Double { min(30, pow(2, Double(max(0, attempt)))) }
    static func validReply(_ message: [String: Any], reference: String) -> Bool {
        message["event"] as? String == "phx_reply" && message["ref"] as? String == reference && (message["payload"] as? [String: Any])?["status"] as? String == "ok"
    }
}

/// Supabase Phoenix Postgres Changes subscription. Payloads are invalidation only:
/// the actor-bound snapshot is always fetched before protected rows are rendered.
@MainActor final class NativeChatRealtime: ObservableObject {
    @Published private(set) var status = "연결 중"
    private var socket: URLSessionWebSocketTask?
    private var worker: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var reconciliation: Task<Void, Never>?
    private var dirty = false
    private var epoch = UUID()
    private var heartbeatReference = ""
    private var heartbeatAck = Date()
    private let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral; configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func stop() {
        epoch = UUID(); worker?.cancel(); worker = nil; heartbeat?.cancel(); heartbeat = nil
        reconciliation?.cancel(); reconciliation = nil; dirty = false; socket?.cancel(with: .goingAway, reason: nil); socket = nil
        status = "연결 종료"
    }
    func start(session: NativeSession, changes: [NativeRealtimeChange], channelID: String? = nil, conversationID: String? = nil, validate: @escaping @MainActor () -> Bool,
               reconcile: @escaping @MainActor () async -> Void, revoked: @escaping @MainActor (String) -> Void) {
        stop()
        let ticket = epoch
        worker = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            var attempt = 0
            while !Task.isCancelled, self.epoch == ticket, validate() {
                var connectedAt:Date?
                do {
                    self.status = attempt == 0 ? "실시간 연결 중" : "실시간 재연결 중"
                    try await self.revalidate(session: session, validate: validate)
                    try await self.validateScope(session:session,channelID:channelID,conversationID:conversationID,validate:validate)
                    guard self.epoch == ticket, validate(), let token = session.api.tokens?.accessToken else { return }
                    var components = URLComponents(url: NativeConfig.url, resolvingAgainstBaseURL: false)!
                    components.scheme = "wss"; components.path = "/realtime/v1/websocket"
                    components.queryItems = [URLQueryItem(name: "apikey", value: NativeConfig.key), URLQueryItem(name: "vsn", value: "1.0.0")]
                    guard let url = components.url else { throw NativeAPIError.invalidData }
                    let socket = self.transport.webSocketTask(with: url); self.socket = socket; socket.resume()
                    let topic = "realtime:native-\(UUID().uuidString)"; let reference = UUID().uuidString
                    try await self.send(socket, topic: topic, event: "phx_join", reference: reference, payload: ["config":["broadcast":["ack":false,"self":false],"presence":["key":""],"postgres_changes":changes.map(\.payload)],"access_token":token])
                    // URLSession's receive is cancelled by stop/heartbeat on stalled joins.
                    self.heartbeat = Task { @MainActor [weak self] in
                        do { try await Task.sleep(for: .seconds(15)); guard let self, self.epoch == ticket, self.status != "실시간 연결됨" else { return }; socket.cancel(with: .goingAway, reason: nil) } catch { }
                    }
                    let join = try await self.receive(socket)
                    guard NativeRealtimePolicy.validReply(join, reference: reference) else { throw NativeAPIError.security("실시간 구독을 허용하지 않았습니다. 현재 동의·참여 상태를 확인해 주세요.") }
                    self.heartbeat?.cancel(); self.status = "실시간 연결됨"; connectedAt=Date(); self.heartbeatAck=Date()
                    await reconcile() // A bounded snapshot closes the join/reconnect gap.
                    self.heartbeat = Task { @MainActor [weak self, weak session] in
                        guard let self, let session else { return }
                        do {
                            while !Task.isCancelled, self.epoch == ticket, validate() {
                                try await Task.sleep(for: .seconds(25))
                                guard Date().timeIntervalSince(self.heartbeatAck) < 60 else { throw URLError(.timedOut) }
                                try await self.revalidate(session: session, validate: validate)
                                try await self.validateScope(session:session,channelID:channelID,conversationID:conversationID,validate:validate)
                                guard self.epoch == ticket, validate(), let token = session.api.tokens?.accessToken else { throw NativeAPIError.sessionExpired }
                                try await self.send(socket, topic: topic, event: "access_token", payload: ["access_token":token])
                                self.heartbeatReference=UUID().uuidString
                                try await self.send(socket, topic:"phoenix", event:"heartbeat", reference:self.heartbeatReference, payload:[:])
                            }
                        } catch {
                            if self.epoch == ticket, !Task.isCancelled {
                                if NativeChatFailurePolicy.requiresClearingProtectedContent(error) { revoked(error.localizedDescription) }
                                socket.cancel(with: .goingAway, reason: nil)
                            }
                        }
                    }
                    while !Task.isCancelled, self.epoch == ticket, validate() {
                        let event = try await self.receive(socket)
                        guard self.epoch == ticket, validate() else { break }
                        switch event["event"] as? String {
                        case "postgres_changes":
                            // Coalesce bursts and never append unvalidated WebSocket payloads.
                            self.dirty = true
                            if self.reconciliation == nil {
                                self.reconciliation = Task { @MainActor [weak self] in
                                    do {
                                        guard let self else { return }
                                        repeat {
                                            self.dirty = false
                                            try await Task.sleep(for: .milliseconds(150))
                                            guard self.epoch == ticket, validate() else { return }
                                            await reconcile()
                                        } while self.dirty && self.epoch == ticket && validate() && !Task.isCancelled
                                        if self.epoch == ticket { self.reconciliation = nil }
                                    } catch { if let self, self.epoch == ticket { self.reconciliation = nil } }
                                }
                            }
                        case "phx_reply":
                            if NativeRealtimePolicy.validReply(event,reference:self.heartbeatReference) { self.heartbeatAck=Date() }
                        case "phx_error", "phx_close": throw URLError(.networkConnectionLost)
                        case "system":
                            if let payload = event["payload"] as? [String: Any], payload["status"] as? String == "error" { throw NativeAPIError.security("실시간 공급자 구독에 실패했습니다. 새로고침으로 상태를 확인하거나 다시 연결해 주세요.") }
                        default: break
                        }
                    }
                } catch {
                    guard self.epoch == ticket, !Task.isCancelled else { return }
                    self.heartbeat?.cancel(); self.socket?.cancel(with: .goingAway, reason: nil); self.socket = nil
                    if NativeChatFailurePolicy.requiresClearingProtectedContent(error) { self.status = error.localizedDescription; revoked(error.localizedDescription); return }
                    if let connectedAt, Date().timeIntervalSince(connectedAt) >= 60 { attempt=0 }
                    attempt += 1
                    guard attempt <= 6, validate() else { self.status = "실시간 연결 실패 · 아래로 당겨 확인하고 다시 연결하세요"; return }
                    self.status = "연결 끊김 · 재연결 예정"
                    do { try await Task.sleep(for: .seconds(NativeRealtimePolicy.retryDelay(attempt - 1))) } catch { return }
                }
            }
        }
    }
    private func validateScope(session:NativeSession,channelID:String?,conversationID:String?,validate:@escaping @MainActor () -> Bool) async throws {
        guard channelID != nil || conversationID != nil else { return }
        var body:[String:Any]=[:]
        if let channelID { body["p_channel_id"]=channelID }
        if let conversationID { body["p_conversation_id"]=conversationID }
        let result=try await session.api.rpc("validate_chat_access",body:body)
        guard validate(), let value=result as? [String:Any],
              nativeText(value,"actorId").lowercased() == nativeText(session.context["profile"] as? [String:Any] ?? [:],"id").lowercased() else { throw NativeAPIError.sessionExpired }
    }
    private func revalidate(session: NativeSession, validate: @escaping @MainActor () -> Bool) async throws {
        guard validate() else { throw NativeAPIError.sessionExpired }
        let generation = session.sessionGeneration
        if session.api.tokens?.expiresAt.timeIntervalSinceNow ?? 0 < 90 { try await session.api.refresh() }
        let state = try await session.api.rpc("get_my_safety_privacy_state")
        guard generation == session.sessionGeneration, validate() else { throw NativeAPIError.sessionExpired }
        guard (state as? [String: Any])?["consent_gate_open"] as? Bool == true else { session.consentRequired = true; session.context = [:]; throw NativeAPIError.security("필수 동의를 다시 확인해 주세요.") }
        let value = try await session.api.rpc("get_my_native_context")
        guard generation == session.sessionGeneration, validate() else { throw NativeAPIError.sessionExpired }
        guard let context = value as? [String: Any] ?? (value as? [[String: Any]])?.first,
              nativeText(context["profile"] as? [String: Any] ?? [:], "id").lowercased() == nativeText(session.context["profile"] as? [String: Any] ?? [:], "id").lowercased(),
              nativeText(context["membership"] as? [String: Any] ?? [:], "organization_id").lowercased() == nativeText(session.context["membership"] as? [String: Any] ?? [:], "organization_id").lowercased(),
              nativeText(context["membership"] as? [String: Any] ?? [:], "status") == "active" else { session.context = [:]; throw NativeAPIError.security("현재 교회 참여 자격을 다시 확인해 주세요.") }
    }
    private func send(_ socket: URLSessionWebSocketTask, topic: String, event: String, reference: String = UUID().uuidString, payload: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["topic":topic,"event":event,"payload":payload,"ref":reference])
        guard let text = String(data: data, encoding: .utf8) else { throw NativeAPIError.invalidData }
        try await socket.send(.string(text))
    }
    private func receive(_ socket: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await socket.receive(); let data: Data
        switch message { case .data(let bytes): data = bytes; case .string(let text): data = Data(text.utf8); @unknown default: throw NativeAPIError.invalidData }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NativeAPIError.invalidData }
        return value
    }
}
