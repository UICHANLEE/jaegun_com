import SwiftUI

struct NativeBoardPostActions: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.dismiss) private var dismiss
    let post: [String: Any]
    let media: [[String: Any]]
    let onChanged: () async -> Void
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var confirmBlock = false
    @State private var busy = false
    @State private var error: String?
    private var id: String { nativeText(post, "id") }
    var body: some View {
        Section("반응") {
            Button("아멘 \((post["amen_count"] as? NSNumber)?.intValue ?? 0)\(post["reacted_amen"] as? Bool == true ? " · 참여함" : "")") {
                Task { await reaction("amen", active: post["reacted_amen"] as? Bool != true) }
            }.disabled(busy)
            if nativeText(post, "board_slug") == "prayer" {
                Button("함께 기도 \((post["prayer_count"] as? NSNumber)?.intValue ?? 0)\(post["reacted_prayer"] as? Bool == true ? " · 참여함" : "")") {
                    Task { await reaction("prayer", active: post["reacted_prayer"] as? Bool != true) }
                }.disabled(busy)
            }
            if nativeText(post, "board_slug") == "official-document" {
                Button("\(post["acknowledged"] as? Bool == true ? "수신 확인 완료" : "공문 수신 확인") · \((post["receipt_count"] as? NSNumber)?.intValue ?? 0)명") {
                    Task { await reaction("receipt", active: true) }
                }.disabled(busy || post["acknowledged"] as? Bool == true)
            }
        }
        Section("게시글 관리") {
            if post["is_owner"] as? Bool == true {
                Button("게시글 수정") { editing = true }.disabled(busy)
                Button("게시글 삭제", role: .destructive) { confirmDelete = true }.disabled(busy)
            } else {
                NavigationLink("게시글 신고") { NativeSafetyReportView(targetType: "post", targetID: id, targetLabel: nativeText(post, "title")) }
                if post["is_system"] as? Bool != true {
                    Button("작성자 차단", role: .destructive) { confirmBlock = true }.disabled(busy)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .confirmationDialog("게시글을 삭제할까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { Task { await mutate("update_owned_community_post", parameters: ["p_post_id": id, "p_expected_revision": post["revision"] ?? 1, "p_title": "", "p_body": "", "p_delete": true], leave: true) } }
        }
        .confirmationDialog("작성자의 글과 메시지를 차단할까요? 익명 신원은 공개되지 않습니다.", isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("차단", role: .destructive) { Task { await mutate("block_community_post_author", parameters: ["p_post_id": id], leave: true) } }
        }
        .sheet(isPresented: $editing) {
            NavigationStack { NativeBoardPostEditor(post: post, media: media, onSaved: onChanged) }.environmentObject(session)
        }
    }
    private func reaction(_ kind: String, active: Bool) async {
        await mutate("set_post_reaction", parameters: ["p_post_id": id, "p_kind": kind, "p_active": active])
    }
    private func mutate(_ name: String, parameters: [String: Any], leave: Bool = false) async {
        guard !busy, let actor = NativeBoardIdentity.capture(session) else { return }
        busy = true; error = nil
        do {
            var bound = parameters
            if name == "set_post_reaction" || name == "block_community_post_author" { bound["p_expected_actor_id"] = actor.actorID }
            if name == "set_post_reaction" { bound["p_expected_revision"] = post["revision"] ?? 1 }
            _ = try await session.api.rpc(name, body: bound)
            guard NativeBoardIdentity.capture(session) == actor else { return }
            busy = false
            if leave { dismiss() } else { await onChanged() }
        } catch { guard NativeBoardIdentity.capture(session) == actor else { return }; busy = false; self.error = "\(error.localizedDescription) 최신 게시글을 다시 불러온 뒤 확인해 주세요." }
    }
}

private struct NativeBoardPostEditor: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.dismiss) private var dismiss
    let post: [String: Any]
    let media: [[String: Any]]
    let onSaved: () async -> Void
    @State private var title = ""
    @State private var bodyText = ""
    @State private var removed: Set<String> = []
    @State private var files: [URL] = []
    @State private var uploads: [URL: NativeMediaAttachment] = [:]
    @State private var mediaService: NativeMediaService?
    @State private var stagedPaths: Set<String> = []
    @State private var busy = false
    @State private var error: String?
    @State private var identity: NativeBoardIdentity?
    @State private var ticket = UUID()
    var body: some View {
        Form {
            Section("작성 내용") {
                TextField("제목", text: $title)
                TextField("내용", text: $bodyText, axis: .vertical).lineLimit(8...20)
            }
            Section("기존 첨부") {
                ForEach(media.indices, id: \.self) { index in
                    let item = media[index], id = nativeText(item, "id")
                    Toggle("\(nativeText(item, "alt_text", fallback: "첨부")) 삭제", isOn: Binding(get: { removed.contains(id) }, set: { if $0 { removed.insert(id) } else { removed.remove(id) } }))
                }
            }
            Section("사진·영상 추가") {
                let available = max(0, 6 - media.count + removed.count)
                if available > 0 { NativeMediaPicker(files: $files, maximum: available) }
                else { Text("최대 6개입니다. 기존 첨부를 삭제 선택하면 새 파일을 추가할 수 있습니다.").font(.footnote).foregroundStyle(.secondary) }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Text("다른 기기에서 수정한 경우 저장하지 않고 충돌을 알립니다. 새로 불러온 뒤 다시 작성해 주세요.").font(.footnote).foregroundStyle(.secondary)
                Button(busy ? "저장 중" : "수정 저장") { Task { await save() } }.disabled(!NativeBoardPolicy.postInput(title: title, body: bodyText))
            }
        }.disabled(busy).navigationTitle("게시글 수정").nativePageStyle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { Task { await cancel() } }.disabled(busy) } }
            .interactiveDismissDisabled(busy || !stagedPaths.isEmpty)
            .task { identity = NativeBoardIdentity.capture(session); title = nativeText(post, "title"); bodyText = nativeText(post, "body") }
            .onChange(of: session.sessionGeneration) { _, _ in clear(); dismiss() }
            .onChange(of: session.consentRequired) { _, required in if required { clear(); dismiss() } }
            .onDisappear { clear() }
    }
    private func clear() {
        ticket = UUID(); title = ""; bodyText = ""
        mediaService?.clear(); mediaService = nil
        files.forEach { try? FileManager.default.removeItem(at: $0) }
        files = []; uploads = [:]; stagedPaths = []; removed = []; identity = nil; busy = false
    }
    private func cleanupStaged(keeping paths: Set<String> = []) async throws {
        guard let identity, NativeBoardIdentity.capture(session) == identity, let service = mediaService else { return }
        let request = ticket
        let currentMedia = try await session.api.rows("post_media", query: "select=storage_path&post_id=eq.\(nativeText(post, "id"))")
        guard request == ticket, NativeBoardIdentity.capture(session) == identity else { throw CancellationError() }
        let protected = Set(currentMedia.map { nativeText($0, "storage_path") }).union(paths)
        let orphaned = Array(stagedPaths.subtracting(protected))
        for start in stride(from: 0, to: orphaned.count, by: 8) {
            let batch = Array(orphaned[start..<min(start + 8, orphaned.count)])
            try await service.remove(paths: batch)
            guard request == ticket, NativeBoardIdentity.capture(session) == identity else { throw CancellationError() }
            stagedPaths.subtract(batch)
        }
    }
    private func cancel() async {
        guard !busy, let identity, NativeBoardIdentity.capture(session) == identity else { return }
        let request = ticket; busy = true; error = nil
        defer { if request == ticket && NativeBoardIdentity.capture(session) == identity { busy = false } }
        do {
            try await cleanupStaged()
            guard request == ticket, NativeBoardIdentity.capture(session) == identity else { return }
            await onSaved(); dismiss()
        } catch { if request == ticket && NativeBoardIdentity.capture(session) == identity { self.error = error.localizedDescription } }
    }
    private func save() async {
        guard !busy, let identity, NativeBoardIdentity.capture(session) == identity else { return }
        let request = ticket, postID = nativeText(post, "id")
        func current() -> Bool { request == ticket && NativeBoardIdentity.capture(session) == identity && !Task.isCancelled }
        busy = true; error = nil
        defer { if current() { busy = false } }
        do {
            if mediaService == nil { mediaService = NativeMediaService(session: session) }
            guard let service = mediaService else { throw NativeAPIError.invalidData }
            var added: [[String: Any]] = []
            for file in files {
                let uploaded: NativeMediaAttachment
                if let existing = uploads[file] { uploaded = existing }
                else {
                    uploaded = try await service.upload(fileURL: file, purpose: "post", targetID: postID, organizationID: identity.organizationID,
                        onObjectPathCreated: { path in if current() { stagedPaths.insert(path) } })
                    guard current() else { return }; uploads[file] = uploaded
                }
                added.append(["storage_path": uploaded.path, "kind": uploaded.kind, "mime_type": uploaded.mimeType, "byte_size": uploaded.byteSize, "file_name": uploaded.fileName])
            }
            guard current() else { return }
            try await cleanupStaged(keeping: Set(added.compactMap { $0["storage_path"] as? String }))
            guard current() else { return }
            _ = try await session.api.rpc("update_owned_community_post", body: ["p_post_id": postID, "p_expected_revision": post["revision"] ?? 1, "p_title": title, "p_body": bodyText, "p_remove_media_ids": Array(removed), "p_add_media": added])
            guard current() else { return }; await onSaved(); dismiss()
        } catch { if current() { self.error = error.localizedDescription } }
    }
}
