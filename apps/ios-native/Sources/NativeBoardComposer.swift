import SwiftUI
import Combine

private struct NativeBoardPendingPost {
    let identity: NativeBoardIdentity
    let boardID: String
    let title: String
    let body: String
    let files: [URL]
    let anonymous: Bool
}

@MainActor final class NativeBoardComposerModel: ObservableObject {
    @Published var title = ""
    @Published var body = ""
    @Published var boardID = ""
    @Published var files: [URL] = []
    @Published private(set) var attachments: [NativeMediaAttachment] = []
    @Published var busy = false
    @Published var error: String?
    @Published private(set) var pending = false
    @Published private(set) var publishedID: String?
    private var operationID = UUID().uuidString.lowercased()
    private var payload: NativeBoardPendingPost?
    private var ticket = UUID()
    private var mediaService: NativeMediaService?

    func clear() {
        ticket = UUID(); title = ""; body = ""; boardID = ""; busy = false; error = nil
        mediaService?.clear(); mediaService = nil
        files.forEach { try? FileManager.default.removeItem(at: $0) }
        files = []; attachments = []
        pending = false; publishedID = nil; payload = nil; operationID = UUID().uuidString.lowercased()
    }

    func suspend() {
        ticket = UUID(); busy = false
        if pending { error = "게시 결과를 아직 확인하지 못했습니다. 같은 글의 게시 결과를 확인하고 다시 시도해 주세요." }
    }

    private func current(_ session: NativeSession, _ identity: NativeBoardIdentity, _ request: UUID) -> Bool {
        !Task.isCancelled && ticket == request && NativeBoardIdentity.capture(session) == identity
    }

    func publish(_ session: NativeSession, boards: [[String: Any]]) async {
        guard !busy, let identity = NativeBoardIdentity.capture(session),
              let board = boards.first(where: { nativeText($0, "id") == boardID }),
              NativeBoardPolicy.canWrite(board, identity: identity), NativeBoardPolicy.postInput(title: title, body: body) else { return }
        let request = ticket
        if payload == nil {
            payload = NativeBoardPendingPost(identity: identity, boardID: boardID,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines), body: body.trimmingCharacters(in: .whitespacesAndNewlines),
                files: files, anonymous: nativeText(board, "slug") == "anonymous-qa")
        }
        guard let payload, payload.identity == identity else { clear(); return }
        busy = true; error = nil
        let wasPending = pending
        pending = true
        defer { if current(session, identity, request) { busy = false } }
        do {
            // Explicit retries first reconcile the same UUID. A successful publication is never recreated.
            if wasPending {
                let result = try await session.api.rpc("reconcile_post_operation", body: ["p_post_id": operationID, "p_expected_author_id": identity.actorID])
                guard current(session, identity, request) else { return }
                let status = try NativeBoardPolicy.status(result)
                if status == "published" { publishedID = operationID; return }
                guard status == nil || status == "draft" else { throw NativeAPIError.security("이 글은 더 이상 게시할 수 없는 상태입니다.") }
            }
            let saved = try await session.api.rpc("save_community_post_draft", body: [
                "p_post_id": operationID, "p_expected_author_id": identity.actorID,
                "p_organization_id": identity.organizationID, "p_board_id": payload.boardID,
                "p_title": payload.title, "p_body": payload.body, "p_is_anonymous": payload.anonymous
            ])
            guard current(session, identity, request) else { return }
            let status = try NativeBoardPolicy.ownedDraft(saved, id: operationID, boardID: payload.boardID, identity: identity)
            if status == "published" { publishedID = operationID; return }
            if mediaService == nil { mediaService = NativeMediaService(session: session) }
            guard let mediaService else { throw NativeAPIError.invalidData }
            for index in payload.files.indices {
                if attachments.count <= index {
                    let uploaded = try await mediaService.upload(fileURL: payload.files[index], purpose: "post", targetID: operationID, organizationID: identity.organizationID)
                    guard current(session, identity, request) else { return }
                    attachments.append(uploaded)
                }
                let attachment = attachments[index]
                let existing = try await session.api.rows("post_media", query: "select=id,storage_path&post_id=eq.\(operationID)&id=eq.\(attachment.id)&limit=1")
                guard current(session, identity, request) else { return }
                if existing.isEmpty {
                    _ = try await session.api.request(path: "/rest/v1/post_media", method: "POST", body: [
                        "id": attachment.id, "post_id": operationID, "uploader_id": identity.actorID,
                        "storage_path": attachment.path, "kind": attachment.kind, "mime_type": attachment.mimeType,
                        "byte_size": attachment.byteSize, "alt_text": attachment.fileName, "sort_order": index
                    ], retry: false)
                    guard current(session, identity, request) else { return }
                }
            }
            let result = try await session.api.rpc("publish_owned_post", body: [
                "p_post_id": operationID, "p_expected_author_id": identity.actorID, "p_expected_media_paths": attachments.map(\.path)
            ])
            guard current(session, identity, request) else { return }
            guard try NativeBoardPolicy.status(result) == "published" else { throw NativeAPIError.invalidData }
            publishedID = operationID
        } catch {
            guard current(session, identity, request) else { return }
            self.error = "\(error.localizedDescription) 작성 내용은 보관되어 있습니다. 아래 버튼으로 같은 글의 게시 결과를 확인하고 다시 시도하세요."
        }
    }

    func unlockDraft(_ session: NativeSession) async {
        guard !busy, let payload, NativeBoardIdentity.capture(session) == payload.identity else { return }
        let identity = payload.identity, request = ticket
        busy = true; error = nil
        defer { if current(session, identity, request) { busy = false } }
        do {
            let result = try await session.api.rpc("reconcile_post_operation", body: ["p_post_id": operationID, "p_expected_author_id": identity.actorID])
            guard current(session, identity, request) else { return }
            let status = try NativeBoardPolicy.status(result)
            if status == "published" { publishedID = operationID; return }
            guard status == nil || status == "draft" else { throw NativeAPIError.security("이 글은 더 이상 수정할 수 없는 상태입니다.") }
            self.payload = nil; pending = false
        } catch {
            guard current(session, identity, request) else { return }
            self.error = "게시 상태를 확인하기 전에는 내용을 변경할 수 없습니다. \(error.localizedDescription)"
        }
    }
}

struct NativeBoardComposerView: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: NativeBoardComposerModel
    let boards: [[String: Any]]
    let onPublished: (String) -> Void
    @State private var discardConfirmation = false
    private var identity: NativeBoardIdentity? { NativeBoardIdentity.capture(session) }
    private var writableBoards: [[String: Any]] {
        guard let identity else { return [] }
        return boards.filter { NativeBoardPolicy.canWrite($0, identity: identity) }
    }
    var body: some View {
        Form {
            Section("게시판 선택") {
                if writableBoards.isEmpty {
                    Text("현재 작성할 수 있는 게시판이 없습니다. 교회 가입 승인과 게시판 권한을 확인해 주세요.").foregroundStyle(.secondary)
                } else {
                    Picker("게시판", selection: $model.boardID) {
                        Text("게시판을 선택해 주세요").tag("")
                        ForEach(writableBoards.indices, id: \.self) { index in
                            Text(nativeText(writableBoards[index], "name")).tag(nativeText(writableBoards[index], "id"))
                        }
                    }
                }
            }.disabled(model.busy || model.pending || !model.attachments.isEmpty)
            Section("작성 내용") {
                TextField("제목 (200자 이내)", text: $model.title)
                TextField("내용을 입력해 주세요", text: $model.body, axis: .vertical).lineLimit(8...20)
                Text("제목 \(model.title.unicodeScalars.count)/200 · 내용 \(model.body.unicodeScalars.count)/50,000자")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy || model.pending)
            Section("사진·영상") {
                NativeMediaPicker(files: $model.files, maximum: 6)
                if !model.attachments.isEmpty { Text("첨부 업로드가 시작된 뒤에는 같은 파일과 게시판으로 결과를 확인합니다.").font(.footnote).foregroundStyle(.secondary) }
            }.disabled(model.busy || model.pending || !model.attachments.isEmpty)
            Section {
                Text("선택한 교회 게시판에 공개됩니다. 익명 질문 게시판에서는 작성자 신원이 서버 응답에서 제외되며, 신고 사건 조사에는 열람 사유와 감사 기록이 필요합니다. 본문과 첨부의 개인정보를 확인해 주세요.").font(.footnote).foregroundStyle(.secondary)
                if let error = model.error { Text(error).foregroundStyle(.red) }
                if model.busy { ProgressView("게시 상태를 확인하고 있습니다") }
                Button(model.pending ? "게시 결과 확인·다시 시도" : "글 게시하기") {
                    Task { await model.publish(session, boards: boards) }
                }.frame(minHeight: 44).disabled(model.busy || identity == nil || model.boardID.isEmpty || !NativeBoardPolicy.postInput(title: model.title, body: model.body))
                if model.pending {
                    Button("게시 상태 확인 후 작성 내용 수정") { Task { await model.unlockDraft(session) } }
                        .frame(minHeight: 44).disabled(model.busy)
                }
            }
        }.navigationTitle("글쓰기").tint(NativePalette.blue)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() }.disabled(model.busy) }
                ToolbarItem(placement: .topBarTrailing) {
                    if !model.pending { Button("내용 비우기", role: .destructive) { discardConfirmation = true }.disabled(model.busy) }
                }
            }
            .interactiveDismissDisabled(model.busy)
            .confirmationDialog("작성 내용을 비울까요?", isPresented: $discardConfirmation, titleVisibility: .visible) {
                Button("작성 내용 비우기", role: .destructive) { model.clear() }
            }
            .onChange(of: identity?.key) { _, _ in model.clear(); dismiss() }
            .onChange(of: model.publishedID) { _, id in
                if let id { onPublished(id); model.clear(); dismiss() }
            }
    }
}
