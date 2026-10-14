import SwiftUI
import Combine
import CryptoKit

enum NativeFaithConsentContract {
    static let version = "2026-10-14"
    static let hash = "4572f759bdcf51050b55f208af2513c63761db5127bc7c754175b4c8a31b8aa4"
    static func text() throws -> String {
        guard let url = Bundle.main.url(forResource: "FaithConsent", withExtension: "md") else { throw NativeAPIError.invalidData }
        let data = try Data(contentsOf: url)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash,
              let text = String(data: data, encoding: .utf8) else { throw NativeAPIError.invalidData }
        return text
    }
    static func accepted(_ value: Any) throws -> Bool {
        guard let row = value as? [String: Any], let accepted = row["accepted"] as? Bool,
              let document = row["document"] as? [String: Any],
              nativeText(document, "document_key") == "faith_private_records",
              nativeText(document, "version") == version, nativeText(document, "content_sha256") == hash,
              nativeText(document, "title") == "개인 통독·QT 기록 이용 동의",
              nativeText(document, "url") == "/legal/faith/2026-10-14" else { throw NativeAPIError.invalidData }
        return accepted
    }
}

struct NativeBibleBook: Decodable {
    let name: String
    let chapters: Int
}

enum NativeBibleCanon {
    // Reference metadata only; no translation or verse text is distributed.
    static let books: [NativeBibleBook] = {
        guard let url = Bundle.main.url(forResource: "BibleCanon", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode([NativeBibleBook].self, from: data),
              value.count == 66, value.allSatisfy({ !$0.name.isEmpty && $0.chapters > 0 }),
              value.reduce(0, { $0 + $1.chapters }) == 1189 else { return [] }
        return value
    }()
    static func chapterID(book: Int, chapter: Int) -> Int? {
        guard books.indices.contains(book), (1...books[book].chapters).contains(chapter) else { return nil }
        return books.prefix(book).reduce(0) { $0 + $1.chapters } + chapter
    }
    static func reference(_ id: Int) -> String {
        guard (1...1189).contains(id) else { return "" }
        var remaining = id
        for book in books {
            if remaining <= book.chapters { return "\(book.name) \(remaining)장" }
            remaining -= book.chapters
        }
        return ""
    }
    static func todayPlan(_ serverToday: String) -> [Int] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parser = DateFormatter(); parser.calendar = calendar; parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = calendar.timeZone; parser.dateFormat = "yyyy-MM-dd"; parser.isLenient = false
        guard let date = parser.date(from: serverToday), parser.string(from: date) == serverToday,
              let ordinal = calendar.ordinality(of: .day, in: .year, for: date),
              let days = calendar.range(of: .day, in: .year, for: date)?.count else { return [] }
        let first = (ordinal - 1) * 1189 / days + 1, last = ordinal * 1189 / days
        return first <= last ? Array(first...last) : []
    }
}

struct NativePrivateQT: Decodable, Identifiable {
    let id: String
    let reference: String
    let body: String
    let created_at: String
}

struct NativeFaithSnapshot: Decodable {
    let server_today: String
    let service_year: Int
    let completed_chapters: [Int]
    let completed_count: Int
    let total_chapters: Int
    let streak_days: Int
    let last_read_date: String?
    let latest_private_qt: [NativePrivateQT]
    static func parse(_ value: Any) throws -> Self {
        guard JSONSerialization.isValidJSONObject(value) else { throw NativeAPIError.invalidData }
        let item = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
        guard item.total_chapters == 1189, (2000...2100).contains(item.service_year),
              item.server_today.hasPrefix("\(item.service_year)-"), !NativeBibleCanon.todayPlan(item.server_today).isEmpty,
              item.completed_count == item.completed_chapters.count,
              Set(item.completed_chapters).count == item.completed_count,
              item.completed_chapters.allSatisfy({ (1...1189).contains($0) }),
              (0...20000).contains(item.streak_days), item.latest_private_qt.count <= 25,
              Set(item.latest_private_qt.map(\.id)).count == item.latest_private_qt.count,
              item.latest_private_qt.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.body.unicodeScalars.count <= 500 && $0.reference.unicodeScalars.count <= 80 })
        else { throw NativeAPIError.invalidData }
        return item
    }
}

private struct NativePendingQT {
    let id = UUID().uuidString
    let reference: String
    let body: String
}

@MainActor private final class NativeFaithModel: ObservableObject {
    @Published var snapshot: NativeFaithSnapshot?
    @Published var accepted: Bool?
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var awaitingQTResult = false
    private var pendingQT: NativePendingQT?
    private var generation = UUID()
    func clear() {
        generation = UUID(); snapshot = nil; accepted = nil; busy = false; error = nil; notice = nil
        pendingQT = nil; awaitingQTResult = false
    }
    private func scope(_ session: NativeSession) -> String? {
        let membership = session.context["membership"] as? [String: Any] ?? [:]
        let church = nativeText(membership, "organization_id")
        return session.signedIn && !session.consentRequired && nativeText(membership, "status") == "active" && UUID(uuidString: church) != nil ? church : nil
    }
    private func current(_ session: NativeSession, church: String, epoch: UUID, ticket: UUID) -> Bool {
        !Task.isCancelled && generation == ticket && session.sessionGeneration == epoch && scope(session) == church
    }
    func load(_ session: NativeSession) async {
        guard !busy, let church = scope(session) else { return }
        let epoch = session.sessionGeneration, ticket = generation
        busy = true; error = nil
        defer { if generation == ticket { busy = false } }
        do {
            _ = try NativeFaithConsentContract.text()
            let status = try await session.api.rpc("get_faith_consent_status", body: ["p_organization_id": church])
            guard current(session, church: church, epoch: epoch, ticket: ticket) else { return }
            accepted = try NativeFaithConsentContract.accepted(status)
            guard accepted == true else { snapshot = nil; return }
            let value = try await session.api.rpc("get_faith_snapshot", body: ["p_organization_id": church])
            guard current(session, church: church, epoch: epoch, ticket: ticket) else { return }
            snapshot = try NativeFaithSnapshot.parse(value)
        } catch {
            guard current(session, church: church, epoch: epoch, ticket: ticket) else { return }
            snapshot = nil; self.error = "통독·묵상 기록을 불러오지 못했습니다. 연결과 가입 상태를 확인해 주세요."
        }
    }
    func accept(_ session: NativeSession) async {
        guard !busy, accepted == false, let church = scope(session) else { return }
        let epoch = session.sessionGeneration, ticket = generation
        busy = true; error = nil
        do {
            _ = try NativeFaithConsentContract.text()
            let result = try await session.api.rpc("accept_faith_consent", body: ["p_organization_id": church, "p_version": NativeFaithConsentContract.version, "p_content_sha256": NativeFaithConsentContract.hash])
            guard current(session, church: church, epoch: epoch, ticket: ticket) else { return }
            guard try NativeFaithConsentContract.accepted(result) else { throw NativeAPIError.invalidData }
            busy = false; await load(session)
        } catch {
            guard current(session, church: church, epoch: epoch, ticket: ticket) else { return }
            busy = false; self.error = "동의 저장 결과를 확인하지 못했습니다. 다시 불러와 상태를 확인해 주세요."
        }
    }
    func setChapter(_ id: Int, completed: Bool, session: NativeSession) async {
        guard !busy, (1...1189).contains(id), let church = scope(session), let original = snapshot else { return }
        let epoch = session.sessionGeneration, ticket = generation
        busy = true; error = nil; notice = nil
        defer { if generation == ticket { busy = false } }
        do {
            let value = try await session.api.rpc("set_my_reading_chapter", body: ["p_organization_id": church, "p_service_year": original.service_year, "p_chapter_id": id, "p_completed": completed])
            guard current(session, church: church, epoch: epoch, ticket: ticket) else { return }
            snapshot = try NativeFaithSnapshot.parse(value)
            notice = completed ? "읽은 장을 저장했습니다." : "읽음 표시를 해제했습니다."
        } catch {
            guard current(session, church: church, epoch: epoch, ticket: ticket) else { return }
            snapshot = nil; self.error = "저장 결과를 확인하지 못했습니다. 다시 불러와 확인해 주세요."
        }
    }
    func saveQT(reference: String, body: String, session: NativeSession) async -> Bool {
        guard !busy, accepted == true, snapshot != nil, let church = scope(session) else { return false }
        let chosen = pendingQT ?? NativePendingQT(reference: reference.trimmingCharacters(in: .whitespacesAndNewlines), body: body.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !chosen.reference.isEmpty, chosen.reference.unicodeScalars.count <= 80,
              !chosen.body.isEmpty, chosen.body.unicodeScalars.count <= 500 else { error = "구절은 1~80자, 묵상은 1~500자로 입력해 주세요."; return false }
        let epoch = session.sessionGeneration, ticket = generation
        busy = true; error = nil; notice = nil
        defer { if generation == ticket { busy = false } }
        var attempted = false
        do {
            attempted = true
            let value = try await session.api.rpc("create_my_qt", body: ["p_organization_id": church, "p_client_request_id": chosen.id, "p_reference": chosen.reference, "p_body": chosen.body])
            guard current(session, church: church, epoch: epoch, ticket: ticket) else { return false }
            guard let id = value as? String, UUID(uuidString: id) != nil else { throw NativeAPIError.invalidData }
            pendingQT = nil; awaitingQTResult = false; notice = "나만 보는 묵상을 저장했습니다."
            busy = false; await load(session)
            return true
        } catch {
            guard current(session, church: church, epoch: epoch, ticket: ticket) else { return false }
            if case NativeAPIError.faithQuota(let message) = error {
                pendingQT = nil; awaitingQTResult = false; self.error = message; return false
            }
            if attempted { pendingQT = chosen; awaitingQTResult = true }
            self.error = "저장 결과가 불확실합니다. 내용을 유지한 채 같은 요청으로 결과를 확인해 주세요."
            return false
        }
    }
    func deleteQT(_ note: NativePrivateQT, session: NativeSession) async {
        guard !busy, !awaitingQTResult, UUID(uuidString: note.id) != nil, let church = scope(session) else { return }
        let epoch = session.sessionGeneration, ticket = generation
        busy = true; error = nil
        defer { if generation == ticket { busy = false } }
        do {
            let deleted = try await session.api.rpc("delete_my_qt", body: ["p_organization_id": church, "p_qt_id": note.id])
            guard deleted is Bool else { throw NativeAPIError.invalidData }
            guard current(session, church: church, epoch: epoch, ticket: ticket) else { return }
            busy = false; await load(session); notice = "개인 묵상을 삭제했습니다."
        } catch {
            guard current(session, church: church, epoch: epoch, ticket: ticket) else { return }
            self.error = "삭제 결과를 확인하지 못했습니다. 기록을 다시 불러와 확인해 주세요."
        }
    }
}

@MainActor private func nativeFaithIdentity(_ session: NativeSession) -> String {
    "\(session.sessionGeneration)|\(nativeText(session.context["membership"] as? [String: Any] ?? [:], "organization_id"))|\(session.consentRequired)"
}

struct NativeFaithHomeSummary: View {
    @EnvironmentObject private var session: NativeSession
    @StateObject private var model = NativeFaithModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("성경 통독 · QT").font(.headline)
                Spacer()
                NavigationLink { NativeFaithView() } label: { Text("기록하기").font(.caption.weight(.semibold)).frame(minHeight: 44) }
            }
            if model.busy { ProgressView("내 기록을 확인하고 있습니다") }
            if model.accepted == false { Text("개인 기록은 별도 선택 동의 후 시작할 수 있습니다.").font(.footnote).foregroundStyle(NativePalette.muted) }
            if let value = model.snapshot {
                Text("\(value.completed_count) / 1,189장 · 연속 \(value.streak_days)일").font(.subheadline)
                ProgressView(value: Double(value.completed_count), total: 1189).tint(NativePalette.forest)
                Text("오늘 계획 · " + NativeBibleCanon.todayPlan(value.server_today).map(NativeBibleCanon.reference).joined(separator: " · "))
                    .font(.caption).foregroundStyle(NativePalette.muted)
            }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red); Button("다시 확인") { Task { await model.load(session) } }.frame(minHeight: 44) }
        }.task(id: nativeFaithIdentity(session)) { model.clear(); await model.load(session) }
    }
}

struct NativeFaithView: View {
    @EnvironmentObject private var session: NativeSession
    @StateObject private var model = NativeFaithModel()
    @State private var book = 0
    @State private var chapter = 1
    @State private var reference = ""
    @State private var note = ""
    @State private var deleting: NativePrivateQT?
    @State private var readConsent = false
    @State private var agreeConsent = false
    private var selectedChapter: Int? { NativeBibleCanon.chapterID(book: book, chapter: chapter) }
    var body: some View {
        List {
            Section {
                Text("성경 통독 · 나의 QT").font(.title2.bold())
                Text("읽은 장과 개인 묵상을 기록합니다. 다른 회원에게 자동으로 공개하지 않습니다.").font(.footnote).foregroundStyle(NativePalette.muted)
                if model.busy { ProgressView("기록을 확인하고 있습니다") }
                if let error = model.error { Text(error).foregroundStyle(.red); Button("기록 다시 불러오기") { Task { await model.load(session) } }.frame(minHeight: 44) }
                if let notice = model.notice { Text(notice).foregroundStyle(NativePalette.forest) }
            }
            if model.accepted == false {
                Section("개인 기록 선택 동의") {
                    Text("통독·QT를 사용하지 않아도 다른 공동체 기능은 이용할 수 있습니다.")
                    DisclosureGroup("개인 기록 안내 전문 읽기", isExpanded: $readConsent) {
                        Text((try? NativeFaithConsentContract.text()) ?? "문서를 확인하지 못했습니다.").font(.footnote).textSelection(.enabled)
                    }
                    Toggle("안내를 읽고 개인 기록 처리에 동의합니다 (선택)", isOn: $agreeConsent).disabled(!readConsent || model.busy)
                    Button("동의하고 개인 기록 시작") { Task { await model.accept(session) } }.frame(minHeight: 44).disabled(!readConsent || !agreeConsent || model.busy)
                }
            }
            Section { NavigationLink("개인 기록 동의 철회·삭제") { NativeFaithWithdrawalView() } }
            if let value = model.snapshot {
                Section("\(String(value.service_year))년 통독") {
                    Text("\(value.completed_count) / 1,189장 · \(Int(Double(value.completed_count) / 1189 * 100))%")
                    ProgressView(value: Double(value.completed_count), total: 1189).tint(NativePalette.forest)
                    Text("연속 \(value.streak_days)일 · 서버 기준 \(value.server_today)").font(.caption).foregroundStyle(NativePalette.muted)
                    Text("성경 본문은 사용하시는 성경에서 읽어 주세요. 앱에는 구절 위치와 진도만 제공하며, 본문 재배포 권리를 확인하기 전에는 말씀 텍스트를 포함하지 않습니다.").font(.footnote).foregroundStyle(NativePalette.muted)
                }
                Section("오늘의 연간 통독 계획") {
                    ForEach(NativeBibleCanon.todayPlan(value.server_today), id: \.self) { id in
                        readingButton(id, value: value)
                    }
                }
                Section("직접 읽은 장 선택") {
                    Picker("성경", selection: $book) { ForEach(NativeBibleCanon.books.indices, id: \.self) { Text(NativeBibleCanon.books[$0].name).tag($0) } }
                        .onChange(of: book) { _, _ in chapter = 1 }
                    if NativeBibleCanon.books.indices.contains(book) {
                        Picker("장", selection: $chapter) { ForEach(1...NativeBibleCanon.books[book].chapters, id: \.self) { Text("\($0)장").tag($0) } }
                    }
                    if let id = selectedChapter { readingButton(id, value: value) }
                }
            }
            Section("나만 보는 묵상") {
                Group {
                    TextField("성경 구절 (예: 창세기 1장)", text: $reference).frame(minHeight: 44)
                    TextField("오늘의 묵상을 적어 주세요", text: $note, axis: .vertical).lineLimit(3...8)
                    Text("\(note.unicodeScalars.count)/500자").font(.caption).foregroundStyle(NativePalette.muted)
                }.disabled(model.busy || model.awaitingQTResult || model.snapshot == nil)
                Button(model.awaitingQTResult ? "같은 묵상 저장 결과 확인" : "개인 묵상 저장") {
                    Task { if await model.saveQT(reference: reference, body: note, session: session) { note = "" } }
                }.frame(minHeight: 44).disabled(model.busy || model.snapshot == nil)
                if model.awaitingQTResult { Text("결과 확인 전에는 원래 내용을 유지합니다. 중복 등록하지 않습니다.").font(.caption).foregroundStyle(NativePalette.muted) }
            }
            Section("최근 개인 묵상 · 최대 25개") {
                if let value = model.snapshot, value.latest_private_qt.isEmpty { Text("저장한 묵상이 없습니다.").foregroundStyle(NativePalette.muted) }
                ForEach(model.snapshot?.latest_private_qt ?? []) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.reference).font(.headline)
                        Text(item.body).textSelection(.enabled)
                        Button("묵상 삭제", role: .destructive) { deleting = item }.frame(minHeight: 44).disabled(model.busy || model.awaitingQTResult)
                    }.padding(.vertical, 6)
                }
            }
        }.navigationTitle("통독·QT").nativePageStyle()
            .task(id: nativeFaithIdentity(session)) { model.clear(); reference = ""; note = ""; deleting = nil; readConsent = false; agreeConsent = false; await model.load(session) }
            .refreshable { await model.load(session) }
            .alert("개인 묵상을 삭제할까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("삭제", role: .destructive) { if let item = deleting { Task { await model.deleteQT(item, session: session) } }; deleting = nil }
                Button("취소", role: .cancel) { deleting = nil }
            } message: { Text("삭제한 개인 묵상은 되돌릴 수 없습니다.") }
    }
    @ViewBuilder private func readingButton(_ id: Int, value: NativeFaithSnapshot) -> some View {
        let completed = value.completed_chapters.contains(id)
        Button {
            Task { await model.setChapter(id, completed: !completed, session: session) }
        } label: {
            HStack { Text(NativeBibleCanon.reference(id)).foregroundStyle(NativePalette.ink); Spacer(); Label(completed ? "읽음 해제" : "읽음 표시", systemImage: completed ? "checkmark.circle.fill" : "circle").foregroundStyle(NativePalette.forest) }
                .frame(minHeight: 44)
        }.buttonStyle(.plain).disabled(model.busy).accessibilityLabel(NativeBibleCanon.reference(id) + (completed ? " 읽음 해제" : " 읽음 표시"))
    }
}
