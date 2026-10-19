import SwiftUI
import CryptoKit

struct NativeBibleVerse: Decodable, Identifiable, Sendable {
    let verse: Int
    let text: String
    var id: Int { verse }
}
struct NativeBibleChapter: Decodable, Sendable {
    let id: Int
    let book: Int
    let chapter: Int
    let reference: String
    let verses: [NativeBibleVerse]
}
struct NativeBibleManifest: Decodable, Sendable {
    struct Chapter: Decodable, Sendable { let id: Int; let verses: Int; let sha256: String }
    let id: String
    let title: String
    let attribution: String
    let license: String
    let source: String
    let archive_sha256: String
    let chapters: [Chapter]
}
enum NativeBibleText {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "BibleKRV") else { throw NativeAPIError.invalidData }
        return try Data(contentsOf: url)
    }
    static func manifest() throws -> NativeBibleManifest {
        let item = try JSONDecoder().decode(NativeBibleManifest.self, from: data("manifest"))
        guard item.id == "korrv-2.0.1", item.chapters.count == 1189,
              item.chapters.enumerated().allSatisfy({ $0.element.id == $0.offset + 1 && $0.element.verses > 0 && $0.element.sha256.count == 64 }) else { throw NativeAPIError.invalidData }
        return item
    }
    static func chapter(_ id: Int, manifest: NativeBibleManifest) throws -> NativeBibleChapter {
        guard (1...1189).contains(id) else { throw NativeAPIError.invalidData }
        let bytes = try data(String(id)), expected = manifest.chapters[id - 1]
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expected.sha256 else { throw NativeAPIError.invalidData }
        let item = try JSONDecoder().decode(NativeBibleChapter.self, from: bytes)
        guard item.id == id, NativeBibleCanon.chapterID(book: item.book, chapter: item.chapter) == id,
              item.reference == NativeBibleCanon.reference(id), item.verses.count == expected.verses,
              item.verses.enumerated().allSatisfy({ $0.element.verse == $0.offset + 1 }) else { throw NativeAPIError.invalidData }
        return item
    }
    static func search(_ query: String, manifest: NativeBibleManifest) throws -> NativeBibleSearchResult {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...100).contains(needle.unicodeScalars.count) else { throw NativeAPIError.invalidData }
        var hits: [NativeBibleSearchHit] = [], total = 0
        for id in 1...1189 {
            try Task.checkCancellation()
            let chapter = try Self.chapter(id, manifest: manifest)
            for verse in chapter.verses where verse.text.localizedCaseInsensitiveContains(needle) {
                total += 1
                if hits.count < 200 { hits.append(NativeBibleSearchHit(chapterID: id, book: chapter.book, chapter: chapter.chapter, reference: chapter.reference, verse: verse.verse, text: verse.text)) }
            }
        }
        return NativeBibleSearchResult(hits: hits, total: total)
    }
}

struct NativeBibleSearchHit: Identifiable, Sendable {
    let chapterID: Int
    let book: Int
    let chapter: Int
    let reference: String
    let verse: Int
    let text: String
    var id: String { "\(chapterID):\(verse)" }
}
struct NativeBibleSearchResult: Sendable { let hits: [NativeBibleSearchHit]; let total: Int }

struct NativeBibleReaderView: View {
    @State private var book = 0
    @State private var chapter = 1
    @State private var query = ""
    @State private var manifest: NativeBibleManifest?
    @State private var text: NativeBibleChapter?
    @State private var selected: Int?
    @State private var error: String?
    @State private var searchResult: NativeBibleSearchResult?
    @State private var searching = false
    @State private var submittedQuery = ""
    @State private var searchRequestID = UUID()
    @State private var pendingSearchChapter: Int?
    @State private var readRequestID = UUID()
    init(initialChapterID: Int = 1) {
        var remaining = (1...1189).contains(initialChapterID) ? initialChapterID : 1
        var index = 0
        while index < NativeBibleCanon.books.count - 1 && remaining > NativeBibleCanon.books[index].chapters {
            remaining -= NativeBibleCanon.books[index].chapters; index += 1
        }
        _book = State(initialValue: index); _chapter = State(initialValue: remaining)
    }
    private var selectedID: Int { NativeBibleCanon.chapterID(book: book, chapter: chapter) ?? 0 }
    private var chosen: NativeBibleVerse? { text?.verses.first(where: { $0.verse == selected }) }
    var body: some View {
        List {
            Section("개역한글 · 오프라인 성경") {
                Text("대한성서공회 번역 · CrossWire KorRV 2.0.1 (1952/1961, Wikisource). 개역개정이 아닙니다.").font(.footnote)
                Text("절 번호는 원본 CrossWire 모듈의 NRSV 좌표입니다. 합절 때문에 인쇄 개역한글과 다를 수 있습니다. 예: 고후 13:14의 축도는 이 모듈의 13:13에 포함됩니다. 빈 절은 인접 절을 함께 확인해 주세요.").font(.footnote)
                Text("전체 66권·1,189장이 앱에 포함되어 인터넷 연결 없이 읽을 수 있습니다. 개인 기록 동의와 무관하게 본문을 읽을 수 있습니다.").font(.footnote).foregroundStyle(NativePalette.muted)
                Picker("성경 책", selection: $book) {
                    ForEach(NativeBibleCanon.books.indices, id: \.self) { index in Text(NativeBibleCanon.books[index].name).tag(index) }
                }.onChange(of: book) { _, _ in chapter = pendingSearchChapter ?? 1; pendingSearchChapter = nil }
                if NativeBibleCanon.books.indices.contains(book) {
                    Picker("장", selection: $chapter) { ForEach(1...NativeBibleCanon.books[book].chapters, id: \.self) { Text("\($0)장").tag($0) } }
                }
                Button("성경 전체 본문 검색") { submittedQuery = query; searchRequestID = UUID() }.frame(minHeight: 44).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count < 2 || searching || manifest == nil)
                if searching { ProgressView("전체 1,189장 검색 중") }
            }
            if !query.isEmpty {
                Section("성경 책 검색") {
                    ForEach(NativeBibleCanon.books.indices.filter { NativeBibleCanon.books[$0].name.localizedCaseInsensitiveContains(query) }, id: \.self) { index in
                        Button(NativeBibleCanon.books[index].name) { book = index; chapter = 1; query = "" }.frame(minHeight: 44)
                    }
                }
            }
            if let result = searchResult {
                Section("전체 \(result.total)절 일치 · 성경 순서 최대 200개") {
                    ForEach(result.hits) { hit in
                        Button {
                            if book == hit.book { chapter = hit.chapter } else { pendingSearchChapter = hit.chapter; book = hit.book }; query = ""; searchResult = nil
                        } label: { VStack(alignment: .leading) { Text("\(hit.reference):\(hit.verse)").font(.headline); Text(hit.text).multilineTextAlignment(.leading) }.frame(minHeight: 44) }
                    }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red); Button("본문 다시 읽기") { readRequestID = UUID() }.frame(minHeight: 44) } }
            if let text {
                Section(text.reference) {
                    ForEach(text.verses.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }) { verse in
                        Button { selected = verse.verse } label: {
                            HStack(alignment: .top) {
                                Text(String(verse.verse)).font(.caption.monospacedDigit()).foregroundStyle(NativePalette.muted)
                                Text(verse.text.isEmpty ? "원본 모듈에 독립 절 본문 없음 (합절·생략·절 좌표 차이). 인접 절을 확인해 주세요." : verse.text).foregroundStyle(NativePalette.ink).multilineTextAlignment(.leading)
                                if selected == verse.verse { Image(systemName: "checkmark.circle.fill").foregroundStyle(NativePalette.forest) }
                            }.frame(minHeight: 44)
                        }.buttonStyle(.plain).accessibilityAddTraits(selected == verse.verse ? .isSelected : [])
                    }
                    if !query.isEmpty && !text.verses.contains(where: { $0.text.localizedCaseInsensitiveContains(query) }) { Text("현재 장에서 일치하는 본문이 없습니다.") }
                }
            }
            Section("판본·저작권·본문 한계") {
                Text(manifest?.attribution ?? "대한성서공회 번역 · CrossWire KorRV 2.0.1")
                Text("Public Domain. 성명표시·동일성 유지. 원본의 합절·생략과 NRSV 절 좌표를 보존합니다. 공식 정본 인증을 뜻하지 않으며 누락 본문을 임의로 보충하지 않습니다. 입력 즉시 검색은 현재 장 대상이며 전체 본문은 전체 검색 버튼으로 찾습니다.").font(.footnote)
                Link("대한성서공회 이용 안내", destination: URL(string: "https://www.bskorea.or.kr/bbs/board.php?bo_table=copyright_faq&wr_id=5")!)
                Link("CrossWire 원본·배포 조건", destination: URL(string: "https://www.crosswire.org/sword/modules/ModInfo.jsp?modName=KorRV")!)
            }
        }.navigationTitle("성경 읽기").nativePageStyle().searchable(text: $query, prompt: "책 이름 또는 현재 장 본문 검색")
            .task(id: "\(selectedID):\(readRequestID)") { await load() }
            .toolbar(.visible, for: .navigationBar)
            .task(id: searchRequestID) { await search() }
    }
    private func load() async {
        let id = selectedID, request = readRequestID, existingManifest = manifest
        selected = nil; text = nil; error = nil
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let source = try existingManifest ?? NativeBibleText.manifest()
            let chapter = try NativeBibleText.chapter(id, manifest: source)
            try Task.checkCancellation()
            return (source, chapter)
        }
        do {
            let (source, chapter) = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, selectedID == id, readRequestID == request else { return }
            manifest = source; text = chapter
        } catch {
            guard !Task.isCancelled, selectedID == id, readRequestID == request else { return }
            self.error = "포함된 성경 자료를 확인하지 못했습니다. 앱 자료 무결성을 확인해 주세요."
        }
    }
    private func search() async {
        guard !submittedQuery.isEmpty, let source = manifest else { return }
        let needle = submittedQuery, ticket = searchRequestID
        searching = true; error = nil; searchResult = nil
        defer { if ticket == searchRequestID { searching = false } }
        let worker = Task.detached(priority: .userInitiated) { try NativeBibleText.search(needle, manifest: source) }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, ticket == searchRequestID else { return }
            searchResult = result
        } catch { if !Task.isCancelled, ticket == searchRequestID { self.error = "전체 검색을 완료하지 못했습니다. 검색어는 2~100자로 입력하고 본문 무결성을 확인해 주세요." } }
    }
}
