import SwiftUI

enum NativeChatFailurePolicy {
    static func requiresClearingProtectedContent(_ error: Error) -> Bool {
        guard let error = error as? NativeAPIError else { return false }
        switch error {
        case .response(401), .response(403), .sessionExpired, .security: return true
        default: return false
        }
    }
    static func isDefinitiveRefusal(_ error: Error) -> Bool {
        guard let error=error as? NativeAPIError else { return false }
        switch error {
        // PostgREST statement errors roll back atomically. Network/5xx/timeout
        // outcomes remain uncertain and must keep their exact request.
        case .response(400), .response(409), .response(413), .response(422): return true
        default: return false
        }
    }
}

/// Coalesces reads for one protected identity and rejects completions after invalidation.
struct NativeChatReadGate {
    private(set) var identity = ""
    private(set) var request: UUID?

    mutating func begin(identity: String) -> UUID? {
        guard !identity.isEmpty, self.identity != identity || request == nil else { return nil }
        let request = UUID()
        self.identity = identity
        self.request = request
        return request
    }

    func accepts(_ request: UUID, identity: String) -> Bool {
        !identity.isEmpty && self.identity == identity && self.request == request
    }

    mutating func finish(_ request: UUID) {
        if self.request == request { self.request = nil }
    }

    mutating func invalidate() { identity = ""; request = nil }
}

/// Offsets count server membership rows, not visible profiles. A page commits only
/// after its profile projection succeeds, so an explicit retry cannot skip anyone.
struct NativeChatMemberDirectory {
    static let pageSize = 50
    static let maximumOffset = 10_000
    private(set) var members: [[String: Any]] = []
    private(set) var offset = 0
    private(set) var hasMore = true
    private(set) var reachedLimit = false

    static func profileIDs(in rows: [[String: Any]], organization: String, ownID: String) -> [String] {
        var seen = Set<String>()
        return rows.compactMap { row in
            let id = nativeText(row, "user_id").lowercased()
            guard nativeText(row, "status") == "active",
                  nativeText(row, "organization_id").lowercased() == organization.lowercased(),
                  UUID(uuidString: id) != nil, id != ownID.lowercased(), seen.insert(id).inserted else { return nil }
            return id
        }
    }

    mutating func append(memberships: [[String: Any]], profiles: [[String: Any]], organization: String, ownID: String) {
        let allowed = Set(Self.profileIDs(in: memberships, organization: organization, ownID: ownID))
        var seen = Set(members.map { nativeText($0, "id").lowercased() })
        members += profiles.filter {
            let id = nativeText($0, "id").lowercased()
            return allowed.contains(id) && seen.insert(id).inserted
        }
        offset += memberships.count
        reachedLimit = memberships.count == Self.pageSize && offset > Self.maximumOffset
        hasMore = memberships.count == Self.pageSize && !reachedLimit
    }

    func matching(_ query: String) -> [[String: Any]] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? members : members.filter { nativeText($0, "display_name").localizedCaseInsensitiveContains(query) }
    }
}

/// Kept by the hub even when the sheet is cancelled: an uncertain create must
/// retain its UUID and exact payload until confirmed, never silently create anew.
@MainActor final class NativeChatChannelDraft: ObservableObject {
    @Published var name = ""
    @Published var description = ""
    @Published var visibility = "public"
    @Published var channelID = UUID().uuidString
    @Published var frozenPayload: [String: Any]?

    func reset() {
        name = ""; description = ""; visibility = "public"
        channelID = UUID().uuidString; frozenPayload = nil
    }
}
