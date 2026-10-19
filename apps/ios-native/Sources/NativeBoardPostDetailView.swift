import SwiftUI

private struct NativeBoardPendingComment {
    let id = UUID().uuidString.lowercased()
    let identity: NativeBoardIdentity
    let body: String
}

struct NativeBoardPostDetailView: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.scenePhase) private var scenePhase
    let postID: String
    @State private var post: [String: Any]?
    @State private var comments: [[String: Any]] = []
    @State private var media: [[String: Any]] = []
    @State private var loadedIdentity: NativeBoardIdentity?
    @State private var loading = false
    @State private var hasMore = false
    @State private var error: String?
    @State private var commentError: String?
    @State private var commentBody = ""
    @State private var sending = false
    @State private var pendingComment: NativeBoardPendingComment?
    @State private var lifecycle = UUID()
    @State private var loadTicket = UUID()
    private var identity: NativeBoardIdentity? { NativeBoardIdentity.capture(session) }
    private var visiblePost: [String: Any]? { loadedIdentity == identity && identity != nil ? post : nil }
    private var canComment: Bool {
        guard let identity, let visiblePost else { return false }
        return NativeBoardPolicy.canComment(visiblePost, identity: identity)
    }
    var body: some View {
        List {
            if loading { ProgressView("게시글과 댓글을 불러오고 있습니다") }
            if let error {
                Text(error).foregroundStyle(.red)
                Button("게시글·댓글 다시 불러오기") { Task { await load() } }.frame(minHeight: 44)
            }
            if let post = visiblePost {
                VStack(alignment: .leading, spacing: 16) {
                    Text(nativeText(post, "title")).font(.title2.bold())
                    Text(nativeText(post, "author_label", fallback: "공동체 회원")).font(.subheadline).foregroundStyle(.secondary)
                    if !nativeText(post, "published_at").isEmpty {
                        Text(nativeText(post, "published_at").prefix(10)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(nativeText(post, "body")).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                ForEach(media.indices, id: \.self) { index in
                    NativeMediaView(path: nativeText(media[index], "storage_path"), kind: nativeText(media[index], "kind"))
                }
                NativeBoardPostActions(post: post, media: media) { await load() }
                Section("댓글") {
                    if comments.isEmpty && !loading { Text("아직 댓글이 없습니다.").foregroundStyle(.secondary) }
                    ForEach(comments.indices, id: \.self) { index in
                        let comment = comments[index]
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(nativeText(comment, "author_label", fallback: comment["is_owner"] as? Bool == true ? "내 댓글" : "공동체 회원")).font(.caption.weight(.semibold))
                                Spacer()
                                Text(nativeText(comment, "created_at").prefix(10)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(nativeText(comment, "body")).textSelection(.enabled)
                            if comment["is_owner"] as? Bool != true {
                                NavigationLink("댓글 신고") { NativeSafetyReportView(targetType: "comment", targetID: nativeText(comment, "id"), targetLabel: "댓글") }
                                NativeCommentBlockButton(commentID: nativeText(comment, "id")) { await load() }
                            }
                        }.padding(.vertical, 6)
                    }
                    if hasMore {
                        Button("댓글 더 보기") { Task { await load(append: true) } }.frame(minHeight: 44).disabled(loading)
                    }
                }
                Section("댓글 작성") {
                    if canComment {
                        if post["is_anonymous"] as? Bool == true {
                            Text("질문과 답변 모두 익명입니다. 본문의 개인정보를 확인해 주세요. 신고 사건의 신원 조사에는 권한·최근 본인 확인·사유와 감사 기록이 필요합니다.").font(.footnote).foregroundStyle(.secondary)
                        }
                        TextField("댓글을 입력해 주세요 (5,000자 이내)", text: $commentBody, axis: .vertical)
                            .lineLimit(3...8).disabled(sending || pendingComment != nil)
                        if let commentError { Text(commentError).foregroundStyle(.red) }
                        if sending { ProgressView("댓글 등록 결과를 확인하고 있습니다") }
                        Button(pendingComment == nil ? "댓글 등록" : "같은 댓글 등록 결과 확인·다시 시도") {
                            Task { await sendComment() }
                        }.frame(minHeight: 44).disabled(sending || !NativeBoardPolicy.commentInput(commentBody))
                        if pendingComment != nil {
                            Text("응답을 확인하지 못해도 같은 댓글 ID로만 다시 시도합니다. 확인 전에는 내용을 변경하지 않습니다.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("이 게시글은 댓글을 작성할 수 없습니다. 교회 회원 권한과 댓글 허용 상태를 확인해 주세요.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }.listStyle(.plain).navigationTitle("게시글").navigationBarTitleDisplayMode(.inline)
            .nativePageStyle().tint(NativePalette.blue).refreshable { await load() }
            .task(id: identity?.key) { clear(); await load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    lifecycle = UUID(); loadTicket = UUID(); post = nil; comments = []; media = []; loadedIdentity = nil; loading = false; sending = false
                }
                if phase == .active { Task { await load() } }
            }
            .onDisappear { lifecycle = UUID(); loadTicket = UUID(); sending = false }
    }
    private func clear() {
        lifecycle = UUID(); loadTicket = UUID(); post = nil; comments = []; loadedIdentity = nil
        media = []
        loading = false; hasMore = false; error = nil; commentError = nil; commentBody = ""; pendingComment = nil; sending = false
    }
    private func current(_ actor: NativeBoardIdentity, ticket: UUID) -> Bool {
        !Task.isCancelled && NativeBoardIdentity.capture(session) == actor && lifecycle == ticket && scenePhase != .background
    }
    private func load(append: Bool = false) async {
        guard scenePhase != .background, let identity, UUID(uuidString: postID) != nil else { return }
        if append && loading { return }
        let request = UUID(), life = lifecycle, offset = append ? comments.count : 0
        loadTicket = request; loading = true; error = nil
        func valid() -> Bool { current(identity, ticket: life) && loadTicket == request }
        defer { if valid() { loading = false } }
        do {
            guard let rows = try await session.api.rpc("list_community_posts", body: ["p_post_id": postID, "p_limit": 1]) as? [[String: Any]] else { throw NativeAPIError.invalidData }
            guard valid() else { return }
            guard let row = rows.first else {
                post = nil; comments = []; media = []; loadedIdentity = nil
                throw NativeAPIError.security("게시글이 없거나 현재 접근할 수 없습니다. 삭제 여부와 교회 권한을 확인해 주세요.")
            }
            post = row; loadedIdentity = identity
            // Post access was confirmed above. Media and comments are independent
            // actor-authorized reads, not a sequential dependency chain.
            async let mediaRead = session.api.rows("post_media", query: "select=id,storage_path,kind,alt_text,sort_order&post_id=eq.\(postID)&order=sort_order.asc")
            async let commentsRead = session.api.rpc("list_community_comments", body: ["p_post_ids": [postID], "p_limit": 50, "p_offset": offset])
            let (mediaRows, commentValue) = try await (mediaRead, commentsRead)
            guard valid() else { return }
            guard let commentRows = commentValue as? [[String: Any]] else { throw NativeAPIError.invalidData }
            media = mediaRows
            hasMore = commentRows.count == 50
            if append {
                let existing = Set(comments.map { nativeText($0, "id") })
                comments.append(contentsOf: commentRows.filter { !existing.contains(nativeText($0, "id")) })
            } else { comments = commentRows }
        } catch {
            guard valid() else { return }
            if !NativeBoardPolicy.mayRetainProtectedRows(after: error) {
                post = nil; comments = []; media = []; loadedIdentity = nil; hasMore = false
            }
            self.error = error.localizedDescription
        }
    }
    private func confirmation(_ pending: NativeBoardPendingComment) async throws -> Bool {
        guard let rows = try await session.api.rpc("list_community_comments", body: ["p_post_ids": [postID], "p_comment_id": pending.id, "p_limit": 1]) as? [[String: Any]] else { throw NativeAPIError.invalidData }
        guard let row = rows.first else { return false }
        guard nativeText(row, "id").lowercased() == pending.id,
              nativeText(row, "post_id").lowercased() == postID.lowercased(),
              row["is_owner"] as? Bool == true,
              nativeText(row, "body") == pending.body else { throw NativeAPIError.invalidData }
        // Even an already moderated/deleted row must not be inserted again.
        return true
    }
    private func finishComment() async {
        pendingComment = nil; commentBody = ""; commentError = nil
        await load()
    }
    private func sendComment() async {
        guard !sending, canComment, let identity, NativeBoardPolicy.commentInput(commentBody) else { return }
        let life = lifecycle, retrying = pendingComment != nil
        let pending = pendingComment ?? NativeBoardPendingComment(identity: identity, body: commentBody.trimmingCharacters(in: .whitespacesAndNewlines))
        guard pending.identity == identity else { clear(); return }
        pendingComment = pending; sending = true; commentError = nil
        var attemptedInsert = false
        defer { if current(identity, ticket: life) { sending = false } }
        do {
            if retrying {
                let exists = try await confirmation(pending)
                guard current(identity, ticket: life) else { return }
                if exists { await finishComment(); return }
            }
            // Real table insert uses the web contract, with an explicit primary key for safe manual retries.
            attemptedInsert = true
            _ = try await session.api.request(path: "/rest/v1/comments", method: "POST", body: [
                "id": pending.id, "post_id": postID, "author_id": identity.actorID, "body": pending.body
            ], retry: false)
            guard current(identity, ticket: life) else { return }
            await finishComment()
        } catch {
            guard current(identity, ticket: life) else { return }
            if attemptedInsert && NativeBoardPolicy.definitiveCommentRejection(error) {
                pendingComment = nil
                commentError = "\(error.localizedDescription) 댓글 내용은 보관되어 있습니다. 내용을 수정하거나 권한을 확인한 뒤 직접 다시 시도해 주세요."
            } else {
                commentError = "\(error.localizedDescription) 댓글 내용은 보관되어 있습니다. 같은 댓글의 등록 결과를 확인한 뒤 다시 시도해 주세요."
            }
        }
    }
}
