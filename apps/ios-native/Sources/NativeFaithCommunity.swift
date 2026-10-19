import SwiftUI
import Combine

enum NativeFaithChallengeDepartment: String, CaseIterable, Identifiable {
    case adult, young_adult, teen, elementary
    var id: String { rawValue }
    var label: String {
        switch self { case .adult: "장년부"; case .young_adult: "청년부"; case .teen: "청소년부"; case .elementary: "초등부" }
    }
}

struct NativeFaithRanking: Decodable, Identifiable {
    let kind: String
    let id: String
    let name: String
    let participants: Int
    let chapters: Int
    let average_chapters: Double
    let rank: Int
}
struct NativeFaithCommunity: Decodable {
    let server_today: String
    let service_year: Int
    let opted_in: Bool
    let challenge_department_code: String?
    let revision: Int
    let notice_version: String
    let notice: String
    let minimum_group: Int
    let rankings: [NativeFaithRanking]
    static func parse(_ value: Any) throws -> Self {
        let item = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
        guard item.server_today.hasPrefix("\(item.service_year)-"), item.minimum_group == 5,
              item.revision >= 0, item.notice_version == "2026-10-15",
              (item.challenge_department_code == nil || NativeFaithChallengeDepartment(rawValue: item.challenge_department_code!) != nil),
              (item.opted_in || item.challenge_department_code == nil),
              item.rankings.allSatisfy({ ["church", "presbytery", "department"].contains($0.kind) && UUID(uuidString: $0.id) != nil && $0.participants >= 5 && $0.chapters >= 0 && $0.average_chapters.isFinite && $0.average_chapters >= 0 && $0.rank > 0 }) else { throw NativeAPIError.invalidData }
        return item
    }
}
struct NativeSharedQT: Decodable, Identifiable {
    let id: String
    let title: String
    let body: String
    let created_at: String
    var amen_count: Int
    var reacted_amen: Bool
}
struct NativeSharedQTFeed: Decodable {
    let server_today: String
    let day: String
    var items: [NativeSharedQT]
    static func parse(_ value: Any) throws -> Self {
        let item = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
        guard item.day.count == 10, item.server_today.count == 10, item.day <= item.server_today,
              item.items.count <= 50, item.items.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.amen_count >= 0 }) else { throw NativeAPIError.invalidData }
        return item
    }
}
@MainActor private final class NativeFaithCommunityModel: ObservableObject {
    @Published var community: NativeFaithCommunity?
    @Published var feed: NativeSharedQTFeed?
    @Published var busy = false
    @Published var error: String?
    @Published var hasMore = false
    private var generation = UUID()
    func clear() { generation = UUID(); community = nil; feed = nil; busy = false; error = nil; hasMore = false }
    private func scope(_ session: NativeSession) -> String? {
        let membership = session.context["membership"] as? [String: Any] ?? [:]
        let church = nativeText(membership, "organization_id")
        return session.signedIn && !session.consentRequired && nativeText(membership, "status") == "active" && UUID(uuidString: church) != nil ? church : nil
    }
    private func current(_ session: NativeSession, _ church: String, _ epoch: UUID, _ ticket: UUID) -> Bool {
        !Task.isCancelled && generation == ticket && session.sessionGeneration == epoch && scope(session) == church
    }
    func load(_ session: NativeSession, day: String = "") async {
        guard !busy, let church = scope(session) else { return }
        let epoch = session.sessionGeneration, ticket = generation
        busy = true; error = nil; community = nil; feed = nil
        defer { if generation == ticket { busy = false } }
        do {
            let ranking = try await session.api.rpc("get_faith_community", body: ["p_organization_id": church])
            guard current(session, church, epoch, ticket) else { return }
            var body: [String: Any] = ["p_organization_id": church, "p_limit": 25, "p_offset": 0]
            if !day.isEmpty { body["p_day"] = day }
            let daily = try await session.api.rpc("list_shared_qt", body: body)
            guard current(session, church, epoch, ticket) else { return }
            community = try NativeFaithCommunity.parse(ranking); feed = try NativeSharedQTFeed.parse(daily); hasMore = feed?.items.count == 25
        } catch { if current(session, church, epoch, ticket) { community = nil; feed = nil; self.error = "조직 집계·공유 묵상을 불러오지 못했습니다. 날짜·연결·가입 상태를 확인해 주세요." } }
    }
    func participate(_ session: NativeSession, optedIn: Bool, department: String) async {
        guard !busy, let community, let church = scope(session) else { return }
        let epoch = session.sessionGeneration, ticket = generation
        busy = true; error = nil
        defer { if generation == ticket { busy = false } }
        do {
            _ = try await session.api.rpc("set_faith_ranking_participation", body: ["p_organization_id": church, "p_service_year": community.service_year, "p_opted_in": optedIn, "p_notice_version": community.notice_version, "p_expected_revision": community.revision, "p_expected_actor_id": nativeText(session.context["profile"] as? [String: Any] ?? [:], "id"), "p_challenge_department_code": optedIn && !department.isEmpty ? department as Any : NSNull()])
            guard current(session, church, epoch, ticket) else { return }
            busy = false; await load(session, day: feed?.day ?? "")
        } catch { if current(session, church, epoch, ticket) { self.error = "참여 변경 결과를 확인하지 못했습니다. 다시 불러와 서버 상태를 확인해 주세요." } }
    }
    func amen(_ item: NativeSharedQT, session: NativeSession) async {
        guard !busy, let church = scope(session) else { return }
        let epoch = session.sessionGeneration, ticket = generation
        busy = true; error = nil
        defer { if generation == ticket { busy = false } }
        do {
            let result = try await session.api.rpc("set_post_reaction", body: ["p_post_id": item.id, "p_kind": "amen", "p_active": !item.reacted_amen, "p_expected_actor_id": nativeText(session.context["profile"] as? [String: Any] ?? [:], "id")])
            guard let row = result as? [String: Any], let count = row["amen_count"] as? Int, count >= 0, let reacted = row["reacted_amen"] as? Bool else { throw NativeAPIError.invalidData }
            guard current(session, church, epoch, ticket), let index = feed?.items.firstIndex(where: { $0.id == item.id }) else { return }
            feed?.items[index].amen_count = count; feed?.items[index].reacted_amen = reacted
        } catch { if current(session, church, epoch, ticket) { self.error = "아멘 결과를 확인하지 못했습니다. 다시 불러와 확인해 주세요. 자동 재전송하지 않습니다." } }
    }
    func more(_ session: NativeSession) async {
        guard !busy, let church = scope(session), let feed else { return }
        let epoch = session.sessionGeneration, ticket = generation
        busy = true; error = nil
        defer { if generation == ticket { busy = false } }
        do {
            let value = try await session.api.rpc("list_shared_qt", body: ["p_organization_id": church, "p_day": feed.day, "p_limit": 25, "p_offset": feed.items.count])
            let next = try NativeSharedQTFeed.parse(value)
            guard current(session, church, epoch, ticket) else { return }
            let ids = Set(feed.items.map(\.id)); self.feed?.items.append(contentsOf: next.items.filter { !ids.contains($0.id) }); hasMore = next.items.count == 25
        } catch { if current(session, church, epoch, ticket) { self.error = "다음 공유 묵상을 불러오지 못했습니다." } }
    }
}
struct NativeFaithCommunityView: View {
    @EnvironmentObject private var session: NativeSession
    @StateObject private var model = NativeFaithCommunityModel()
    let optionalAccepted: Bool
    @State private var approved = false
    @State private var day = ""
    @State private var department = ""
    private var identity: String { "\(session.sessionGeneration)|\(session.consentRequired)|\(nativeText(session.context["membership"] as? [String: Any] ?? [:], "organization_id"))|\(nativeText(session.context["membership"] as? [String: Any] ?? [:], "status"))|\(optionalAccepted)" }
    var body: some View {
        Group {
            Section("교회·노회·부서 통독 집계") {
                if model.busy { ProgressView("공동체 확인 중") }
                if let error = model.error { Text(error).foregroundStyle(.red) }
                Button("공동체 다시 확인") { Task { approved = false; await model.load(session, day: day) } }.frame(minHeight: 44).disabled(model.busy)
                if let community = model.community {
                    Text(community.notice).font(.footnote)
                    Text("\(String(community.service_year))년 · 한국 날짜 \(community.server_today) · 1인 평균 읽은 장 수 순").font(.caption).foregroundStyle(NativePalette.muted)
                    Picker("우리 교회 통독 도전 부서 (선택)", selection: $department) {
                        Text("부서 집계 참여 안함").tag("")
                        ForEach(NativeFaithChallengeDepartment.allCases) { Text($0.label + " 통독 모임").tag($0.rawValue) }
                    }.disabled(model.busy || !optionalAccepted)
                    Text("본인이 고르는 올해의 도전 그룹입니다. 실제 소속·나이·직책·권한을 뜻하거나 변경하지 않습니다. 같은 교회의 같은 선택 그룹만 5명 이상일 때 집계합니다.").font(.footnote)
                    if !community.opted_in { Toggle("올해 내 읽은 장 수를 조직 집계에 포함 (선택)", isOn: $approved).disabled(!optionalAccepted || model.busy) }
                    Button(community.opted_in ? "조직 집계 참여 취소" : "올해 조직 집계에 참여") { Task { approved = false; await model.participate(session, optedIn: !community.opted_in, department: department) } }.frame(minHeight: 44).disabled(model.busy || (!community.opted_in && (!approved || !optionalAccepted)))
                    if community.opted_in { Button("통독 도전 부서 선택 저장") { Task { await model.participate(session, optedIn: true, department: department) } }.frame(minHeight: 44).disabled(model.busy || !optionalAccepted || department == (community.challenge_department_code ?? "")) }
                    if !optionalAccepted { Text("참여하려면 개인 기록 선택 동의가 먼저 필요합니다. 공개 묵상 읽기에는 필요하지 않습니다.").font(.footnote) }
                    ForEach(["church", "presbytery", "department"], id: \.self) { kind in
                        Text(kind == "church" ? "교회별" : kind == "presbytery" ? "노회별" : "우리 교회 부서별 통독 모임").font(.headline)
                        let rows = community.rankings.filter { $0.kind == kind }
                        if rows.isEmpty { Text("참여자 5명 이상 조직이 없습니다. 소규모 집계는 공개하지 않습니다.").font(.footnote) }
                        ForEach(rows) { row in
                            Text("\(row.rank)위 · \(row.name) · 평균 \(row.average_chapters.formatted(.number.precision(.fractionLength(1))))장 · 참여 \(row.participants)명").font(.subheadline)
                        }
                    }
                }
            }
            Section("교회에 공유한 오늘의 묵상") {
                Text("별도로 공개한 게시판 사본만 표시합니다. 개인 QT는 이 피드에 나타나지 않습니다.").font(.footnote)
                TextField("한국 날짜 YYYY-MM-DD (빈칸: 오늘)", text: $day).textInputAutocapitalization(.never).autocorrectionDisabled().frame(minHeight: 44).disabled(model.busy)
                Button("날짜로 보기") { Task { await model.load(session, day: day) } }.frame(minHeight: 44).disabled(model.busy)
                if let feed = model.feed {
                    Text("\(feed.day) · 서버 한국 날짜 \(feed.server_today)").font(.caption)
                    if feed.items.isEmpty { Text("이 날 공유한 묵상이 없습니다.") }
                    ForEach(feed.items) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            NavigationLink(item.title) { NativeBoardPostDetailView(postID: item.id) }
                            Text(item.body).textSelection(.enabled)
                            Button("아멘 \(item.amen_count)\(item.reacted_amen ? " · 취소" : "")") { Task { await model.amen(item, session: session) } }.frame(minHeight: 44).disabled(model.busy).accessibilityAddTraits(item.reacted_amen ? .isSelected : [])
                            NavigationLink("댓글·신고·게시글 보기") { NativeBoardPostDetailView(postID: item.id) }.frame(minHeight: 44)
                        }.padding(.vertical, 6)
                    }
                    if model.hasMore { Button("공유 묵상 25개 더 보기") { Task { await model.more(session) } }.frame(minHeight: 44).disabled(model.busy) }
                }
            }
        }.task(id: identity) { model.clear(); approved = false; day = ""; department = ""; await model.load(session) }
            .onChange(of: model.community?.challenge_department_code) { _, value in department = value ?? "" }
    }
}
