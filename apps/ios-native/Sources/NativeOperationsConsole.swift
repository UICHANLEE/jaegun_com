import SwiftUI
import UniformTypeIdentifiers

private struct OperationsArchiveDocument: FileDocument {
 static var readableContentTypes: [UTType] { [.json] }
 var data: Data
 init(data: Data) { self.data = data }
 init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
 func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct NativeOperationsConsoleView: View {
 @EnvironmentObject private var session: NativeSession
 @State private var section = "overview"
 @State private var generation = UUID()
 @State private var query = ""
 @State private var status = ""
 @State private var reason = ""
 @State private var selectedID = ""
 @State private var output = ""
 @State private var cases: [[String: Any]] = []
 @State private var appeals: [[String: Any]] = []
 @State private var start = Date().addingTimeInterval(-86400)
 @State private var end = Date()
 @State private var offset = 0
 @State private var busy = false
 @State private var error: String?
 @State private var archive = OperationsArchiveDocument(data: Data())
 @State private var exporting = false
 @State private var importing = false
 private var actor: String {
  let id = nativeText(session.context["profile"] as? [String: Any] ?? [:], "id")
  return id.isEmpty ? "" : session.sessionGeneration.uuidString + id
 }
 private var allowed: Bool { session.signedIn && !session.consentRequired && !actor.isEmpty }
 var body: some View {
  Form {
   Section("운영 콘솔") {
    Text("실제 집계만 표시합니다. 개별 회원 추적·임의 대화·비공개 신앙 기록은 조회하지 않습니다.")
    Picker("영역", selection: $section) { Text("사용량").tag("overview"); Text("신고·항소").tag("cases"); Text("감사").tag("audit") }.disabled(busy)
    TextField("사건 ID / 감사 작업 검색", text: $query)
    if section == "cases" { Picker("상태", selection: $status) { ForEach(["", "open", "reviewing", "resolved", "dismissed", "escalated"], id: \.self) { Text($0.isEmpty ? "전체" : $0).tag($0) } } }
    if section == "audit" { DatePicker("시작", selection: $start); DatePicker("종료", selection: $end) }
    Stepper("시작 위치 \(offset)", value: $offset, in: 0...100000, step: 100)
    Button("조회 / 새로고침") { Task { await load() } }.disabled(busy || !allowed)
    TextField("조사·조치 사유 (10–2000자)", text: $reason, axis: .vertical).lineLimit(3...8)
    Text("증거 조회·조치·내보내기는 최근 Google 인증이 필요합니다. 인증 요구 시 설정에서 Google 재인증 후 다시 요청하세요.").font(.caption)
    Button("Google 본인 확인") { Task { _ = await session.reauthenticateGoogle() } }.disabled(busy || !allowed)
   }
   if let error { Section { Text(error).foregroundStyle(.red) } }
   if busy { ProgressView() }
   if section == "cases" {
    Section("신고") {
     ForEach(Array(cases.enumerated()), id: \.offset) { _, row in
      Button("\(nativeText(row, "id")) · \(nativeText(row, "reason_code")) · \(nativeText(row, "status"))") {
       let id = nativeText(row, "id"); let request = generation; let owner = actor
       selectedID = ""; output = ""
       Task { await execute {
        let value = try await session.api.rpc("admin_operations_case", body: ["p_report_id": id, "p_reason": reason])
        if generation == request, actor == owner, allowed { selectedID = id }
        return value
       } }
      }.disabled(busy || reason.trimmingCharacters(in: .whitespacesAndNewlines).count < 10)
     }
    }
    if !selectedID.isEmpty {
     Section("선택 사건 조치") {
      ForEach(["warning_recorded", "content_hidden", "member_suspended", "no_action", "escalated_to_platform", "hold", "release_hold"], id: \.self) { action in
       Button(action) { Task { await execute { try await session.api.rpc("admin_operations_action", body: ["p_report_id": selectedID, "p_action": action, "p_reason": reason]) } } }.disabled(busy || reason.count < 10)
      }
     }
    }
    Section("대기 이의신청") {
     Text("인용은 재검토 결정 기록이며 기존 제재나 숨김을 자동 해제하지 않습니다. 필요한 정정 조치는 별도로 확인하세요.").font(.footnote)
     ForEach(Array(appeals.enumerated()), id: \.offset) { _, row in
      Text(nativeText(row, "reason"))
      ForEach(["accept_appeal", "reject_appeal"], id: \.self) { action in
       Button(action == "accept_appeal" ? "항소 인용" : "항소 기각") { Task { await execute { try await session.api.rpc("admin_operations_action", body: ["p_report_id": nativeText(row, "report_id"), "p_appeal_id": nativeText(row, "id"), "p_action": action, "p_reason": reason]) } } }.disabled(busy || reason.count < 10)
      }
     }
    }
   }
   Section("조회 결과") { Text(output.isEmpty ? "조회하면 결과와 수집 시간이 표시됩니다." : output).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
   if section == "audit" {
    Section("감사 아카이브") {
     Text("검색란에 정확한 감사 ID를 입력하면 사유·최근 Google 인증 확인 뒤 검증된 접속 출처만 조사합니다. 검증되지 않은 IP는 표시하지 않습니다.")
     Button("감사 건 접속 출처 조사") { Task { await execute { try await session.api.rpc("admin_operations_audit_provenance", body: ["p_audit_id": query, "p_reason": reason]) } } }.disabled(busy || reason.count < 10 || UUID(uuidString: query) == nil)
     Text("최대 31일·10,000건. 전체 데이터베이스 백업이 아닙니다. 무결성 검증은 보존 삭제를 허가하지 않습니다. 자동 로그 삭제는 하지 않습니다.")
     Button("체크섬 포함 JSON 저장") { Task { await execute {
      let owner = actor; let request = generation
      let result = try await session.api.rpc("admin_operations_export", body: ["p_from": start.ISO8601Format(), "p_to": end.ISO8601Format(), "p_reason": reason])
      guard owner == actor, allowed, generation == request else { throw CancellationError() }
      archive = OperationsArchiveDocument(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])); exporting = true; return result
     } } }.disabled(busy || reason.count < 10)
     Button("저장 파일 무결성 검증") { importing = true }.disabled(busy)
    }
   }
  }.navigationTitle("운영·사건·감사").nativePageStyle()
   .onChange(of: actor) { _, _ in clear() }
   .onChange(of: session.consentRequired) { _, _ in clear() }
   .onChange(of: section) { _, _ in clear() }
   .fileExporter(isPresented: $exporting, document: archive, contentType: .json, defaultFilename: "jaegun-audit") { result in if case .failure(let failure) = result { error = failure.localizedDescription } }
   .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
    Task { await execute {
     let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
     let data = try Data(contentsOf: url); guard data.count <= 10000000, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = value["id"] as? String, let records = value["records"] as? [[String: Any]] else { throw NSError(domain: "Invalid archive", code: 1) }
     return try await session.api.rpc("admin_operations_verify_export", body: ["p_export_id": id, "p_records": records])
    } }
   }
 }
 @MainActor private func clear() { generation = UUID(); output = ""; cases = []; appeals = []; selectedID = ""; reason = ""; error = nil; archive = OperationsArchiveDocument(data: Data()); exporting = false; importing = false }
 @MainActor private func execute(_ operation: () async throws -> Any) async {
  guard allowed, !busy else { return }; let owner = actor; let request = generation; busy = true; error = nil
  defer { busy = false }
  do { let result = try await operation(); guard owner == actor, allowed, generation == request else { return }; let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]); output = String(decoding: data, as: UTF8.self) }
  catch { guard owner == actor, allowed, generation == request else { return }; self.error = error.localizedDescription }
 }
 @MainActor private func load() async {
  let owner = actor; let request = generation
  await execute {
   switch section {
   case "cases":
    let value = try await session.api.rpc("admin_operations_cases", body: ["p_query": query, "p_status": status, "p_offset": offset])
    if let value = value as? [String: Any], allowed, owner == actor, generation == request { cases = value["cases"] as? [[String: Any]] ?? []; appeals = value["appeals"] as? [[String: Any]] ?? [] }; return value
   case "audit": return try await session.api.rpc("admin_operations_audit", body: ["p_query": query, "p_from": start.ISO8601Format(), "p_to": end.ISO8601Format(), "p_offset": offset])
   default: return try await session.api.rpc("admin_operations_snapshot")
   }
  }
 }
}

struct NativeOperationsAppealView: View {
 @EnvironmentObject private var session: NativeSession
 let reportID: String
 @State private var reason = ""
 @State private var message = ""
 @State private var busy = false
 @State private var submitted = false
 var body: some View {
  Form {
   Text("신고자 또는 해당 제재 당사자만 항소할 수 있습니다.")
   TextField("항소 사유 (10–2000자)", text: $reason, axis: .vertical)
   Button("항소 제출") { Task {
    guard !busy, !submitted, session.signedIn else { return }; let owner = session.sessionGeneration; busy = true; defer { busy = false }
    do {
     _ = try await session.api.rpc("operations_submit_appeal", body: ["p_report_id": reportID, "p_reason": reason.trimmingCharacters(in: .whitespacesAndNewlines)])
     guard owner == session.sessionGeneration, session.signedIn else { return }
     message = "이의신청을 제출했습니다. 내 신고·제재에서 처리 상태를 확인하세요."; reason = ""; submitted = true
    } catch { guard owner == session.sessionGeneration, session.signedIn else { return }; message = error.localizedDescription }
   } }.disabled(busy || submitted || !session.signedIn || reason.trimmingCharacters(in: .whitespacesAndNewlines).count < 10 || reason.count > 2000)
   Text(message)
  }.navigationTitle("신고·제재 이의신청")
   .onChange(of: session.sessionGeneration) { _, _ in reason = ""; message = ""; submitted = false }
 }
}

struct NativeMyReportsView: View {
 @EnvironmentObject private var session: NativeSession
 @State private var rows: [[String: Any]] = []
 @State private var error: String?
 @State private var offset = 0
 private var actor: String { nativeText(session.context["profile"] as? [String: Any] ?? [:], "id") }
 var body: some View {
  List {
   Text("본인이 신고했거나 제재 당사자인 사건만 표시합니다. 동의 갱신 전에도 권리 행사를 위한 최소 조회·항소가 가능합니다.")
   if let error { Text(error).foregroundStyle(.red) }
   ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
    VStack(alignment: .leading) {
     Text("\(nativeText(row, "reason_code")) · \(nativeText(row, "status"))")
     Text(nativeText(row, "resolution_note"))
     if let appeal = row["appeal"] as? [String: Any] {
      Text("항소: \(nativeText(appeal, "status")) · \(nativeText(appeal, "decision"))")
      if nativeText(appeal, "status") != "pending" { NavigationLink("항소 제출") { NativeOperationsAppealView(reportID: nativeText(row, "id")) } }
     } else { NavigationLink("항소 제출") { NativeOperationsAppealView(reportID: nativeText(row, "id")) } }
    }
   }
   HStack {
    Button("이전") { offset = max(0, offset - 100) }.disabled(offset == 0)
    Button("다음") { offset += 100 }.disabled(rows.count < 100)
   }
  }.navigationTitle("내 신고·제재")
   .task(id: "\(actor)-\(offset)") { await load() }
   .refreshable { await load() }
   .onChange(of: actor) { _, _ in rows = []; error = nil }
 }
 @MainActor private func load() async {
  let owner = actor; rows = []; error = nil
  guard session.signedIn, !owner.isEmpty else { return }
  do {
   let result = try await session.api.rpc("operations_my_reports", body: ["p_offset": offset]) as? [[String: Any]] ?? []
   guard owner == actor, session.signedIn else { return }; rows = result
  } catch { guard owner == actor else { return }; self.error = error.localizedDescription }
 }
}
