import Foundation

struct NativeBoardIdentity: Equatable {
    let generation: UUID
    let actorID: String
    let organizationID: String
    let role: String
    let platformAdmin: Bool

    @MainActor static func capture(_ session: NativeSession) -> Self? {
        let member = session.context["membership"] as? [String: Any] ?? [:]
        let actor = nativeText(session.context["profile"] as? [String: Any] ?? [:], "id").lowercased()
        let church = nativeText(member, "organization_id").lowercased()
        guard session.signedIn, !session.consentRequired, nativeText(member, "status") == "active",
              UUID(uuidString: actor) != nil, UUID(uuidString: church) != nil else { return nil }
        return Self(generation: session.sessionGeneration, actorID: actor, organizationID: church,
                    role: nativeText(member, "role"), platformAdmin: session.context["is_platform_admin"] as? Bool == true)
    }

    var key: String { "\(generation):\(actorID):\(organizationID):\(role):\(platformAdmin)" }
    var scopeQuery: String { "or=(organization_id.eq.\(organizationID),organization_id.is.null)" }
}

enum NativeBoardPolicy {
    static func postInput(title: String, body: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...200).contains(title.unicodeScalars.count) && (1...50000).contains(body.unicodeScalars.count)
    }

    static func commentInput(_ body: String) -> Bool {
        (1...5000).contains(body.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count)
    }

    // This controls discovery only. RLS and actor-bound RPCs decide whether a write is allowed.
    static func canWrite(_ board: [String: Any], identity: NativeBoardIdentity) -> Bool {
        UUID(uuidString: nativeText(board, "id")) != nil
            && nativeText(board, "organization_id").lowercased() == identity.organizationID
            && board["is_global"] as? Bool == false
            && board["is_read_only"] as? Bool == false
            && (board["staff_only_posting"] as? Bool == false
                || (board["staff_only_posting"] as? Bool == true
                    && (identity.platformAdmin || ["minister", "executive"].contains(identity.role))))
    }

    static func canComment(_ post: [String: Any], identity: NativeBoardIdentity) -> Bool {
        UUID(uuidString: nativeText(post, "id")) != nil
            && nativeText(post, "organization_id").lowercased() == identity.organizationID
            && nativeText(post, "status") == "published" && post["allow_comments"] as? Bool == true
    }

    static func definitiveCommentRejection(_ error: Error) -> Bool {
        guard case NativeAPIError.response(let code) = error else { return false }
        return [400, 401, 403, 404, 405, 406, 415, 422, 429].contains(code)
    }

    static func mayRetainProtectedRows(after error: Error) -> Bool {
        guard let failure = error as? URLError else { return false }
        return [.timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed].contains(failure.code)
    }

    static func status(_ value: Any) throws -> String? {
        if value is NSNull { return nil }
        guard let row = value as? [String: Any], ["draft", "published", "hidden", "deleted"].contains(nativeText(row, "status")) else {
            throw NativeAPIError.invalidData
        }
        return nativeText(row, "status")
    }

    static func ownedDraft(_ value: Any, id: String, boardID: String, identity: NativeBoardIdentity) throws -> String {
        guard let row = value as? [String: Any], nativeText(row, "id").lowercased() == id.lowercased(),
              nativeText(row, "organization_id").lowercased() == identity.organizationID,
              nativeText(row, "board_id").lowercased() == boardID.lowercased(),
              ["draft", "published"].contains(nativeText(row, "status")) else { throw NativeAPIError.invalidData }
        return nativeText(row, "status")
    }
}
