import SwiftUI
import PhotosUI
import AVFoundation
import SDWebImageWebPCoder
import SDWebImage

struct NativeExecutiveRecordsView: View {
    enum Kind: String { case minutes, finance }
    let kind: Kind
    var scopeID: String? = nil
    var eventID: String? = nil
    @EnvironmentObject private var session: NativeSession
    @State private var scopes: [[String: Any]] = []
    @State private var selection = ""
    @State private var year = ""
    @State private var records: [[String: Any]] = []
    @State private var includeDeleted = false
    @State private var rolloverDelay: Double = 60_000
    @State private var canWrite = false
    @State private var busy = false
    @State private var error: String?
    @State private var draft: [String: Any]?
    @State private var history: [[String: Any]] = []
    @State private var operationID = UUID().uuidString
    @State private var reason = ""
    @State private var periodStart = ""
    @State private var periodEnd = ""
    @State private var share: NativeFinanceShare?
    @State private var exportURL: URL?
    @State private var receiptRecord: [String: Any]?
    @State private var receiptData: Data?
    @State private var receiptImage: UIImage?
    @State private var receiptID = UUID().uuidString
    @State private var readable = false
    @State private var receiptProvider = "supabase"
    @State private var receiptNotice: [String: Any] = [:]
    @State private var receiptApproved = false
    @State private var receiptAttempted = false
    @State private var photo: PhotosPickerItem?
    @State private var camera = false
    @State private var photoPicker = false
    @State private var preview: UIImage?
    private var allowed: Bool { session.signedIn && !session.consentRequired }
    private var actorID: String { nativeText(session.context["profile"] as? [String: Any] ?? [:], "id") }
    private var scope: [String: Any]? { scopes.first { key($0) == selection } }

    var body: some View {
        List {
            Section {
                Text(kind == .minutes ? "회의록" : "회계 장부").font(.title2.bold())
                Text("조직·행사·연도별 독립 기록. 일반 성도·사역자에게 공개되지 않습니다.").font(.footnote)
                Picker("기록 범위", selection: $selection) {
                    ForEach(scopes.indices, id: \.self) { i in Text(nativeText(scopes[i], "label")).tag(key(scopes[i])) }
                }.disabled(busy)
                TextField("연도", text: $year).keyboardType(.numberPad).disabled(busy)
                Button("조회·처리 결과 확인") { Task { await load() } }.disabled(busy || !allowed)
                if canWrite {
                    Button("새 기록") { open(nil) }.disabled(busy)
                    Button("Google 본인 확인") { Task { _ = await session.reauthenticateGoogle() } }.disabled(busy)
                    Text("최근 5분 이내 본인 확인 후 저장을 직접 눌러 주세요.").font(.footnote)
                } else { Text("읽기 전용: 현재 연도의 해당 임원 직책만 작성할 수 있습니다.").font(.footnote) }
            }
            if let error { Text(error).foregroundStyle(.red) }
            if busy { ProgressView() }
            if !scopes.isEmpty {
                Section("전체 기록 내려받기") {
                    Button(kind == .minutes ? "전체 회의록 다운로드" : "전체 회계 장부 다운로드") { Task { await exportAll() } }.disabled(busy)
                    Text("본인에게 허용된 모든 조직·모임의 전체 연도와 변경 이력입니다. 영수증 사진 원본은 제외합니다. 최근 Google 본인 확인이 필요합니다.").font(.footnote)
                    if !canWrite { Button("Google 본인 확인") { Task { _ = await session.reauthenticateGoogle() } }.disabled(busy) }
                    Text("회의·모임마다 기록 범위를 선택하고 해당 날짜로 새 기록을 남기세요.").font(.footnote)
                }
            }
            if draft != nil { editor }
            if kind == .minutes { Toggle("삭제된 회의록·보존 이력 포함", isOn: $includeDeleted) }
            ForEach(records.indices.filter { includeDeleted || nativeText(records[$0], "deleted_at").isEmpty }, id: \.self) { i in recordRow(records[i]) }
            if canWrite { Section("취소·첨부 삭제 사유") { TextField("사유 2~500자", text: $reason).onChange(of: reason) { _, _ in operationID = UUID().uuidString } } }
            if !history.isEmpty {
                Section("변경 이력") {
                    Button("이력 닫기") { history = [] }
                    ForEach(history.indices, id: \.self) { i in
                        let h = history[i]
                        let snapshot = h["snapshot"] as? [String: Any] ?? [:]
                        DisclosureGroup("버전 \(h["revision"] ?? 0) · \(nativeText(h, "action"))") {
                            Text(nativeText(h, "occurred_at")); Text(nativeText(h, "reason"))
                            Text(nativeText(snapshot, "title")); Text(nativeText(snapshot, "body")).textSelection(.enabled)
                            Text("처리자: \(nativeText(h, "actor_id"))")
                            if !nativeText(snapshot, "receipt_id").isEmpty { Text("영수증 ID: \(nativeText(snapshot, "receipt_id"))") }
                            Text("\(snapshot["amount"] ?? "") KRW")
                        }
                    }
                }
            }
            if let image = receiptImage, let data = receiptData {
                Section("영수증 판독 확인") {
                    Image(uiImage: image).resizable().scaledToFit()
                    Text("WebP \((data.count + 1023) / 1024)KB · 100KB 목표. 판독을 위해 원 해상도를 유지하며 목표를 넘을 수 있습니다.").font(.footnote)
                    Picker("비공개 보관 공급자", selection: $receiptProvider) {
                        Text("Supabase 비공개 Storage").tag("supabase")
                        Text("Cloudflare R2 \(receiptNotice["enabled"] as? Bool == true ? "" : "(승인된 설정 없음)")").tag("r2").disabled(receiptNotice["enabled"] as? Bool != true)
                    }.disabled(busy || receiptAttempted)
                    if receiptProvider == "r2" {
                        Text("처리자: \(nativeText(receiptNotice, "recipient")) · 국가·지역: \(nativeText(receiptNotice, "countries"))")
                        Text("목적: \(nativeText(receiptNotice, "purpose"))")
                        Text("항목: \(nativeText(receiptNotice, "items"))")
                        Text("보유·이용: \(nativeText(receiptNotice, "retention"))")
                        Text("\(nativeText(receiptNotice, "refusal")) 문의: \(nativeText(receiptNotice, "contact")) · 안내 버전 \(nativeText(receiptNotice, "version"))")
                        Toggle("이 영수증의 R2 전송 안내를 확인하고 전송에 동의합니다", isOn: $receiptApproved).disabled(busy)
                    }
                    Toggle("날짜·상호·금액이 읽히는지 직접 확인했습니다", isOn: $readable)
                    Button("선택한 공급자에 비공개 첨부 저장") { Task { await uploadReceipt() } }.disabled(busy || !readable || (receiptProvider == "r2" && (!receiptApproved || receiptNotice["enabled"] as? Bool != true)))
                    Button("취소") { clearReceipt() }.disabled(busy)
                }
            }
            if let preview { Section("비공개 영수증") { Image(uiImage: preview).resizable().scaledToFit(); Button("닫기") { self.preview = nil } } }
            if kind == .finance && scope != nil {
                Section("기간 결산·대사·감사 보고서") {
                    TextField("시작 YYYY-MM-DD", text: $periodStart)
                    TextField("종료 YYYY-MM-DD", text: $periodEnd)
                    Button("XLSX 내려받기·공유") { Task { await export(close: false) } }.disabled(busy)
                    if canWrite { Button("기간 마감 및 XLSX 공유") { closeConfirmation = true }.disabled(busy) }
                    Text("마감 후 해당 기간 전표 수정 불가. 승인된 업무에만 사용하고 파일을 안전하게 보관하세요.").font(.footnote)
                }
            }
        }.listStyle(.plain).navigationTitle(kind == .minutes ? "회의록" : "회계 장부").nativePageStyle()
            .task(id: session.sessionGeneration.uuidString + String(allowed)) {
                while !Task.isCancelled && allowed {
                    await initialLoad()
                    do { try await Task.sleep(for: .milliseconds(rolloverDelay)) } catch { break }
                    if !Task.isCancelled { resetEditor() }
                }
            }.refreshable { await load() }
            .onChange(of: selection) { _, _ in resetEditor(); Task { await load() } }
            .onChange(of: session.sessionGeneration) { _, _ in clear() }
            .onChange(of: session.consentRequired) { _, required in if required { clear() } }
            .onChange(of: session.signedIn) { _, signed in if !signed { clear() } }
            .onChange(of: photo) { _, value in Task { await choosePhoto(value) } }
            .photosPicker(isPresented: $photoPicker, selection: $photo, matching: .images)
            .sheet(isPresented: $camera) { NativeFinanceCamera { image in camera = false; if let image { encode(image) } } }
            .sheet(item: $share, onDismiss: clearExport) { NativeFinanceShareSheet(url: $0.url) }
            .confirmationDialog("선택 기간을 마감하면 수정할 수 없습니다.", isPresented: $closeConfirmation) { Button("기간 마감", role: .destructive) { Task { await export(close: true) } } }
    }
    @State private var closeConfirmation = false
    private var editor: some View {
        Section("기록 검토·저장") {
            TextField("날짜 YYYY-MM-DD", text: binding("record_date"))
            TextField("제목", text: binding("title"))
            TextEditor(text: binding("body")).frame(minHeight: 170)
            if kind == .minutes {
                Picker("상태", selection: binding("status")) { Text("검토 중 초안").tag("draft"); Text("검토 완료·확정").tag("published") }
                Text("외부로 전송할 메모는 직접 입력하고 전송 안내를 승인하세요. 검토한 초안만 가져오며 자동 저장하지 않습니다.").font(.footnote)
            } else {
                Picker("수입·지출", selection: binding("entry_type")) { Text("수입").tag("income"); Text("지출").tag("expense") }
                TextField("분류", text: binding("category"))
                TextField("금액 KRW", text: binding("amount")).keyboardType(.decimalPad)
            }
            Button("검토한 내용 저장") { Task { await save() } }.disabled(busy || !canWrite)
            Button("취소") { draft = nil }.disabled(busy)
        }
    }
    @ViewBuilder private func recordRow(_ row: [String: Any]) -> some View {
        Section {
            Text(nativeText(row, "title")).font(.headline)
            Text("\(nativeText(row, "record_date")) · 버전 \(row["revision"] ?? 1)").font(.caption)
            if kind == .finance { Text("\(nativeText(row, "entry_type") == "income" ? "수입" : "지출") · \(row["amount"] ?? 0) KRW") }
            else { Text(nativeText(row, "status") == "published" ? "확정" : "초안") }
            Text(nativeText(row, "body")).textSelection(.enabled)
            if !nativeText(row, "deleted_at").isEmpty { Text("삭제·보존 기록").font(.footnote) }
            if records.contains(where: { nativeText($0, "reversal_of") == nativeText(row, "id") }) { Text("취소 역분개 완료 · 원 전표 보존").font(.footnote) }
            if !nativeText(row, "reversal_of").isEmpty { Text("역분개 원본: \(nativeText(row, "reversal_of"))").font(.footnote) }
            Button("변경 이력") { Task { let generation = session.sessionGeneration; await perform { let value = try await session.api.rpc("get_scoped_record_history", body: ["p_id": nativeText(row, "id")]); guard allowed, generation == session.sessionGeneration else { return }; history = value as? [[String: Any]] ?? [] } } }.disabled(busy)
            if canWrite && nativeText(row, "deleted_at").isEmpty && nativeText(row, "source_operation_id").isEmpty && nativeText(row, "reversal_of").isEmpty && !records.contains(where: { nativeText($0, "reversal_of") == nativeText(row, "id") }) {
                Button("수정") { open(row) }.disabled(busy)
                Button(kind == .minutes ? "회의록 삭제" : "취소 역분개", role: .destructive) { Task { await cancel(row) } }.disabled(busy || reason.count < 2)
            }
            if kind == .finance {
                Text("영수증: 선택한 공급자의 비공개 보관").font(.footnote)
                let receipts = row["receipts"] as? [[String: Any]] ?? []
                ForEach(receipts.indices, id: \.self) { i in
                    Button("\(nativeText(receipts[i], "provider") == "r2" ? "R2" : "Supabase") 영수증 보기 (최대 60초)") { Task { await viewReceipt(receipts[i]) } }.disabled(busy)
                    if canWrite { Button("첨부 삭제", role: .destructive) { Task { await removeReceipt(receipts[i]) } }.disabled(busy || reason.count < 2) }
                }
                if canWrite {
                    Button("영수증 사진 선택") { receiptRecord = row; photoPicker = true }.disabled(busy)
                    if UIImagePickerController.isSourceTypeAvailable(.camera) { Button("영수증 촬영") { receiptRecord = row; Task { await openCamera() } }.disabled(busy) }
                }
            }
        }
    }
    private func key(_ row: [String: Any]) -> String { nativeText(row, "scope_id") + ":" + nativeText(row, "event_id") }
    private func binding(_ field: String) -> Binding<String> {
        Binding(get: { if let value = draft?[field] { return value is NSNull ? "" : String(describing: value) }; return "" }, set: { draft?[field] = $0; operationID = UUID().uuidString })
    }
    private func open(_ row: [String: Any]?) {
        guard canWrite, let scope else { return }
        var fresh: [String: Any] = ["id": UUID().uuidString, "scope_id": nativeText(scope, "scope_id"), "event_id": scope["event_id"] ?? NSNull(), "revision": 0, "record_date": NativeCalendarDates.label(Date(), format: "yyyy-MM-dd"), "title": "", "body": "", "status": "draft"]
        fresh["entry_type"] = kind == .finance ? "expense" as Any : NSNull()
        fresh["category"] = kind == .finance ? "일반" as Any : NSNull()
        fresh["amount"] = kind == .finance ? "0" as Any : NSNull()
        draft = row ?? fresh
        operationID = UUID().uuidString
    }
    private func initialLoad() async {
        guard allowed else { return }; let generation = session.sessionGeneration
        do {
            let clock = try await session.api.rpc("get_service_clock") as? [String: Any] ?? [:]
            let items = try await session.api.rpc("list_scoped_record_scopes") as? [[String: Any]] ?? []
            guard allowed, generation == session.sessionGeneration else { return }
            rolloverDelay = max(1, (clock["milliseconds_until_rollover"] as? NSNumber)?.doubleValue ?? 60_000)
            year = String(describing: clock["service_year"] ?? "")
            periodStart = year + "-01-01"; periodEnd = year + "-12-31"
            scopes = items.filter { (scopeID == nil || nativeText($0, "scope_id") == scopeID) && (eventID == nil || nativeText($0, "event_id") == eventID) }
            selection = scopes.first.map(key) ?? ""; await load()
            if kind == .finance {
                let notice = try? await session.api.invokeFunction("finance-receipt", body: ["action": "notice", "expectedActorId": actorID])
                if allowed, generation == session.sessionGeneration { receiptNotice = notice as? [String: Any] ?? [:] }
            }
        } catch { if generation == session.sessionGeneration { self.error = error.localizedDescription } }
    }
    private func load() async {
        guard allowed, let scope, let value = Int(year) else { return }; let generation = session.sessionGeneration; let selected = selection
        do {
            let result = try await session.api.rpc("get_scoped_records", body: ["p_scope_id": nativeText(scope, "scope_id"), "p_event_id": scope["event_id"] ?? NSNull(), "p_year": value, "p_kind": kind.rawValue]) as? [String: Any] ?? [:]
            guard allowed, generation == session.sessionGeneration, selected == selection else { return }
            records = result["rows"] as? [[String: Any]] ?? []; canWrite = result["can_write"] as? Bool ?? false; self.error = nil
        } catch { if generation == session.sessionGeneration { records = []; canWrite = false; self.error = error.localizedDescription } }
    }
    private func perform(_ work: () async throws -> Void) async {
        guard allowed, !busy else { return }; let generation = session.sessionGeneration; busy = true; error = nil
        defer { busy = false }
        do { try await work() } catch { if allowed && generation == session.sessionGeneration { self.error = error.localizedDescription + " 응답이 불명확하면 처리 결과를 확인한 뒤 직접 다시 시도하세요." } }
    }
    private func save() async {
        guard let d = draft, canWrite else { return }; let generation = session.sessionGeneration; let actor = actorID
        await perform {
            let status = try await session.api.rpc("get_sensitive_action_auth_status")
            guard NativeSensitiveAuthStatus.isVerified(status) else { throw NativeAPIError.security("최근 Google 본인 확인 후 저장을 직접 다시 눌러 주세요.") }
            var amount: Any = NSNull()
            if kind == .finance, let decimal = Decimal(string: String(describing: d["amount"] ?? "")) { amount = NSDecimalNumber(decimal: decimal) }
            _ = try await session.api.rpc("save_scoped_record", body: ["p_id": d["id"] ?? "", "p_scope_id": d["scope_id"] ?? "", "p_event_id": d["event_id"] ?? NSNull(), "p_kind": kind.rawValue, "p_expected_revision": d["revision"] ?? 0, "p_record_date": d["record_date"] ?? "", "p_title": d["title"] ?? "", "p_body": d["body"] ?? "", "p_status": d["status"] ?? "draft", "p_entry_type": d["entry_type"] ?? NSNull(), "p_category": d["category"] ?? NSNull(), "p_amount": amount, "p_currency": "KRW", "p_operation_id": operationID, "p_expected_actor_id": actor])
            guard allowed, generation == session.sessionGeneration else { return }; draft = nil; await load()
        }
    }
    private func cancel(_ row: [String: Any]) async {
        let generation = session.sessionGeneration; let actor = actorID
        await perform { _ = try await session.api.rpc("delete_scoped_record", body: ["p_id": nativeText(row, "id"), "p_expected_revision": row["revision"] ?? 0, "p_operation_id": operationID, "p_reason": reason, "p_expected_actor_id": actor]); guard allowed, generation == session.sessionGeneration else { return }; operationID = UUID().uuidString; reason = ""; await load() }
    }
    private func openCamera() async {
        guard allowed, canWrite else { return }; let generation = session.sessionGeneration
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        var granted = status == .authorized
        if status == .notDetermined { granted = await AVCaptureDevice.requestAccess(for: .video) }
        guard allowed, generation == session.sessionGeneration else { return }
        if granted { camera = true }
        else { error = "영수증 촬영을 사용하려면 iPhone 설정에서 카메라 권한을 허용하세요. 사진 선택은 계속 사용할 수 있습니다." }
    }
    private func choosePhoto(_ item: PhotosPickerItem?) async {
        guard let item, receiptRecord != nil, allowed else { return }; let generation = session.sessionGeneration
        do { if let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data), generation == session.sessionGeneration, allowed { encode(image) } } catch { self.error = error.localizedDescription }
        photo = nil
    }
    private func encode(_ image: UIImage) {
        guard image.size.width * image.size.height * image.scale * image.scale <= 40_000_000 else { error = "영수증 해상도가 너무 큽니다."; return }
        var encoded: Data?
        for quality in [0.92, 0.85, 0.78] {
            encoded = SDImageWebPCoder.shared.encodedData(with: image, format: .webP, options: [.encodeCompressionQuality: quality])
            if let encoded, encoded.count <= 100 * 1024 { break }
        }
        guard let encoded, encoded.count <= 10 * 1024 * 1024 else { error = "판독 가능한 WebP로 변환하지 못했습니다."; return }
        receiptData = encoded; receiptImage = UIImage(data: encoded); readable = false; receiptID = UUID().uuidString; receiptProvider = "supabase"; receiptApproved = false; receiptAttempted = false
    }
    private func uploadReceipt() async {
        guard let row = receiptRecord, let data = receiptData, readable, receiptProvider != "r2" || receiptApproved else { return }; let generation = session.sessionGeneration; let actor = actorID
        await perform {
            receiptAttempted = true
            let prepared = try await session.api.invokeFunction("finance-receipt", body: ["action": "prepare", "expectedActorId": actor, "recordId": nativeText(row, "id"), "receiptId": receiptID, "provider": receiptProvider, "noticeVersion": nativeText(receiptNotice, "version"), "byteLength": data.count]) as? [String: Any] ?? [:]
            guard allowed, generation == session.sessionGeneration else { return }
            if prepared["attached"] as? Bool != true {
                if receiptProvider == "r2" {
                    try await NativeFinanceStorage.putR2(url: nativeText(prepared, "url"), headers: prepared["headers"] as? [String: String] ?? [:], data: data)
                } else {
                    _ = try await NativeFinanceStorage.request(api: session.api, path: "/object/finance-receipts/" + nativeText(prepared, "path"), method: "POST", data: data, contentType: "image/webp", duplicateOK: true)
                }
                guard allowed, generation == session.sessionGeneration else { return }
                _ = try await session.api.invokeFunction("finance-receipt", body: ["action": "commit", "expectedActorId": actor, "receiptId": receiptID, "expectedRevision": row["revision"] ?? 0, "noticeVersion": nativeText(receiptNotice, "version")])
            }
            guard allowed, generation == session.sessionGeneration else { return }; clearReceipt(); await load()
        }
    }
    private func viewReceipt(_ receipt: [String: Any]) async {
        let generation = session.sessionGeneration
        await perform {
            let result = try await session.api.invokeFunction("finance-receipt", body: ["action": "sign", "receiptId": nativeText(receipt, "id"), "expectedActorId": actorID]) as? [String: Any] ?? [:]
            guard let url = URL(string: nativeText(result, "url")), url.scheme == "https",
                  url.host == NativeConfig.url.host || (url.host?.hasSuffix(".r2.cloudflarestorage.com") == true) else { throw NativeAPIError.invalidData }
            guard allowed, generation == session.sessionGeneration else { return }
            let config = URLSessionConfiguration.ephemeral; config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let transport = URLSession(configuration: config)
            defer { transport.invalidateAndCancel() }
            let (image, response) = try await transport.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, allowed, generation == session.sessionGeneration else { return }
            preview = UIImage(data: image)
            Task { try? await Task.sleep(for: .seconds(45)); if generation == session.sessionGeneration { preview = nil } }
        }
    }
    private func removeReceipt(_ receipt: [String: Any]) async {
        let generation = session.sessionGeneration
        await perform {
            _ = try await session.api.invokeFunction("finance-receipt", body: ["action": "delete", "receiptId": nativeText(receipt, "id"), "expectedActorId": actorID, "reason": reason])
            guard allowed, generation == session.sessionGeneration else { return }
            await load()
        }
    }
    private func export(close: Bool) async {
        guard let scope else { return }; let generation = session.sessionGeneration; let actor = actorID
        await perform {
            let report = try await session.api.rpc("export_finance_report", body: ["p_scope_id": nativeText(scope, "scope_id"), "p_event_id": scope["event_id"] ?? NSNull(), "p_starts_on": periodStart, "p_ends_on": periodEnd, "p_close": close, "p_expected_actor_id": actor]) as? [String: Any] ?? [:]
            guard allowed, generation == session.sessionGeneration else { return }
            let rows = report["entries"] as? [[String: Any]] ?? []
            let histories = report["history"] as? [[String: Any]] ?? []
            let income = (report["income"] as? NSNumber)?.doubleValue ?? 0; let expense = (report["expense"] as? NSNumber)?.doubleValue ?? 0
            let entries = [["날짜", "구분", "분류", "내용", "금액", "통화", "기록ID", "역분개원본", "회비참가자ID", "행사회차ID", "원자작업ID"]] + rows.map { [nativeText($0, "record_date"), nativeText($0, "entry_type"), nativeText($0, "category"), nativeText($0, "title"), String(describing: $0["amount"] ?? 0), "KRW", nativeText($0, "id"), nativeText($0, "reversal_of"), nativeText($0, "fee_user_id"), nativeText($0, "fee_occurrence_id"), nativeText($0, "source_operation_id")] }
            let totals = [["시작", "종료", "수입", "지출", "잔액", "통화", "마감"], [periodStart, periodEnd, String(income), String(expense), String(income - expense), "KRW", close ? "마감" : "미마감"]]
            let audit = [["기록ID", "버전", "행위", "처리자ID", "사유", "시각", "영수증ID", "회비참가자ID"]] + histories.map { h in
                let snapshot = h["snapshot"] as? [String: Any] ?? [:]
                return [nativeText(h, "record_id"), String(describing: h["revision"] ?? 0), nativeText(h, "action"), nativeText(h, "actor_id"), nativeText(h, "reason"), nativeText(h, "occurred_at"), nativeText(snapshot, "receipt_id"), nativeText(snapshot, "fee_user_id")]
            }
            let data = try NativeXLSX.write(sheets: [(name: "장부", rows: entries), (name: "결산대사", rows: totals), (name: "감사이력", rows: audit)])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("회계_\(UUID().uuidString).xlsx")
            try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            clearExport(); exportURL = url; share = NativeFinanceShare(url: url)
        }
    }
    private func exportAll() async {
        let generation = session.sessionGeneration; let actor = actorID
        await perform {
            guard let report = try await session.api.rpc("export_executive_records", body: ["p_kind": kind.rawValue, "p_expected_actor_id": actor]) as? [String: Any] else { throw NativeAPIError.invalidData }
            guard allowed, generation == session.sessionGeneration else { return }
            let input = try JSONSerialization.data(withJSONObject: report)
            let data = try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                guard let snapshot = try JSONSerialization.jsonObject(with: input) as? [String: Any] else { throw NativeAPIError.invalidData }
                return try NativeRecordArchiveWorkbook.data(snapshot)
            }.value
            guard allowed, generation == session.sessionGeneration else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(kind == .minutes ? "전체회의록" : "전체회계장부")_\(UUID().uuidString).xlsx")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            clearExport(); exportURL = url; share = NativeFinanceShare(url: url)
        }
    }
    private func clearExport() { if let exportURL { try? FileManager.default.removeItem(at: exportURL) }; exportURL = nil; share = nil }
    private func clearReceipt() { receiptRecord = nil; receiptImage = nil; receiptData = nil; readable = false; photo = nil; receiptApproved = false; receiptAttempted = false }
    private func resetEditor() { records = []; canWrite = false; draft = nil; history = []; preview = nil; clearReceipt() }
    private func clear() { resetEditor(); clearExport(); scopes = []; selection = ""; reason = ""; error = nil; operationID = UUID().uuidString; camera = false; photoPicker = false; closeConfirmation = false }
}

enum NativeRecordArchiveWorkbook {
    static func parts(_ text: String) -> [String] {
        var result: [String] = []; var chunk = ""; var count = 0
        for scalar in text.unicodeScalars {
            let length = scalar.value > 0xffff ? 2 : 1
            if count + length > 30000 { result.append(chunk); chunk = ""; count = 0 }
            chunk.unicodeScalars.append(scalar); count += length
        }
        if !chunk.isEmpty || result.isEmpty { result.append(chunk) }; return result
    }
    static func data(_ report: [String: Any]) throws -> Data {
        guard nativeText(report,"format") == "jaegun-records-v1", ["minutes","finance"].contains(nativeText(report,"kind")),
              let entries = report["entries"] as? [[String: Any]], let histories = report["history"] as? [[String: Any]],
              (report["record_count"] as? NSNumber)?.intValue == entries.count,
              (report["history_count"] as? NSNumber)?.intValue == histories.count else { throw NativeAPIError.invalidData }
        let title = nativeText(report,"kind") == "minutes" ? "전체회의록" : "전체회계장부"
        let rows = [["기록ID","조직","모임","연도","날짜","제목","상태","구분","분류","금액","역분개원본"]] + entries.map { r in
            [nativeText(r,"id"),nativeText(r,"scope_label"),nativeText(r,"event_title"),String(describing:r["service_year"] ?? ""),nativeText(r,"record_date"),nativeText(r,"title"),nativeText(r,"deleted_at").isEmpty ? nativeText(r,"status") : "삭제·보존",nativeText(r,"entry_type"),nativeText(r,"category"),String(describing:r["amount"] ?? ""),nativeText(r,"reversal_of")]
        }
        let bodies = [["기록ID","분할번호","본문"]] + entries.flatMap { r in parts(nativeText(r,"body")).enumerated().map { i,text in [nativeText(r,"id"),String(i+1),text] } }
        let history = [["기록ID","버전","행위","시각","사유","제목","금액"]] + histories.map { h in
            let s = h["snapshot"] as? [String: Any] ?? [:]
            return [nativeText(s,"id"),String(describing:h["revision"] ?? ""),nativeText(h,"action"),nativeText(h,"occurred_at"),nativeText(h,"reason"),nativeText(s,"title"),String(describing:s["amount"] ?? "")]
        }
        let historyBodies = [["기록ID","버전","분할번호","본문"]] + histories.flatMap { h in
            let s = h["snapshot"] as? [String: Any] ?? [:]
            return parts(nativeText(s,"body")).enumerated().map { i,text in [nativeText(s,"id"),String(describing:h["revision"] ?? ""),String(i+1),text] }
        }
        let info = [["범위","기록수","이력수","생성시각","주의"],["권한이 있는 모든 조직·모임 / 전체 연도",String(entries.count),String(histories.count),nativeText(report,"generated_at"),"삭제 보존·역분개 포함. 영수증 사진 제외. 본문 분할번호 순으로 연결."]]
        return try NativeXLSX.write(sheets:[(name:title,rows:rows),(name:"본문",rows:bodies),(name:"변경이력",rows:history),(name:"변경본문",rows:historyBodies),(name:"내보내기안내",rows:info)])
    }
}

@MainActor enum NativeFinanceStorage {
    static func putR2(url: String, headers: [String: String], data: Data) async throws {
        guard let target = URL(string: url), target.scheme == "https", target.host?.hasSuffix(".r2.cloudflarestorage.com") == true,
              data.count > 0, data.count <= 10485760, headers["content-length"] == String(data.count), headers["content-type"] == "image/webp", headers["if-none-match"] == "*" else { throw NativeAPIError.invalidData }
        var request = URLRequest(url: target); request.httpMethod = "PUT"; request.httpBody = data
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (_, raw) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard let response = raw as? HTTPURLResponse, (200..<300).contains(response.statusCode) || response.statusCode == 412 else { throw NativeAPIError.security("R2 업로드가 실패했습니다. 동일 영수증 ID로 직접 다시 시도하세요.") }
    }
    static func request(api: NativeAPI, path: String, method: String, data: Data, contentType: String, duplicateOK: Bool = false) async throws -> Data {
        guard let token = api.tokens, let url = URL(string: NativeConfig.url.absoluteString + "/storage/v1" + path), url.host == NativeConfig.url.host else { throw NativeAPIError.sessionExpired }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = data
        request.setValue(NativeConfig.key, forHTTPHeaderField: "apikey"); request.setValue("Bearer " + token.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type"); request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (result, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NativeAPIError.invalidData }
        if duplicateOK && [400, 409].contains(http.statusCode), let failure = try? JSONSerialization.jsonObject(with: result) as? [String: Any], ["Duplicate", "409"].contains(String(describing: failure["error"] ?? failure["statusCode"] ?? "")) { return result }
        guard (200..<300).contains(http.statusCode) else { throw NativeAPIError.response(http.statusCode) }; return result
    }
}
private struct NativeFinanceShare: Identifiable { let id = UUID(); let url: URL }
private struct NativeFinanceShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil); controller.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: url) }; return controller }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
private struct NativeFinanceCamera: UIViewControllerRepresentable {
    let completion: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController { let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator; return picker }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let completion: (UIImage?) -> Void
        init(_ completion: @escaping (UIImage?) -> Void) { self.completion = completion }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { completion(info[.originalImage] as? UIImage) }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
    }
}
