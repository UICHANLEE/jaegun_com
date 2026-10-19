import Foundation

struct NativeAITransferNotice {
    let version: String
    let enabled: Bool
    let text: String
    init(_ row: [String: Any]) throws {
        let fields = ["version", "recipient", "countries", "purpose", "items", "retention", "refusal", "contact", "termsUrl", "model", "processingRegion"]
        guard fields.allSatisfy({ !(row[$0] as? String ?? "").isEmpty }), let enabled = row["enabled"] as? Bool else { throw NativeAPIError.invalidData }
        #if DEBUG
        let permittedRegion = row["processingRegion"] as? String == "us-east-1" || (row["processingRegion"] as? String == "local-development" && row["provider"] as? String == "selfhost")
        #else
        let permittedRegion = row["processingRegion"] as? String == "us-east-1"
        #endif
        guard permittedRegion else { throw NativeAPIError.security("AI 처리 지역이 승인된 서비스 지역과 일치하지 않습니다.") }
        version = row["version"] as! String; self.enabled = enabled
        text = "처리자: \(row["recipient"]!)\n처리 국가·지역: \(row["countries"]!)\n앱 서버: \(row["processingRegion"]!)\n목적: \(row["purpose"]!)\n전송 항목: \(row["items"]!)\n보유·이용: \(row["retention"]!)\n거부: \(row["refusal"]!)\n문의: \(row["contact"]!)\n모델: \(row["model"]!)\n이용약관: \(row["termsUrl"]!)"
    }
}
struct NativeAIResult: Identifiable {
    let id: String
    let answer: String
    let model: String
}
@MainActor enum NativeAIService {
    static func notice(api: NativeAPI) async throws -> NativeAITransferNotice {
        guard let row = try await api.invokeFunction("ai-assistant", body: ["action": "notice"]) as? [String: Any] else { throw NativeAPIError.invalidData }
        return try NativeAITransferNotice(row)
    }
    static func generate(api: NativeAPI, prompt: String, purpose: String, noticeVersion: String, requestID: String) async throws -> NativeAIResult {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.count <= 6000,
              ["sermon", "prayer", "theology", "meeting-minutes"].contains(purpose), !noticeVersion.isEmpty else { throw NativeAPIError.security("질문과 전송 승인을 확인해 주세요.") }
        guard let row = try await api.invokeFunction("ai-assistant", body: ["prompt": prompt, "purpose": purpose, "noticeVersion": noticeVersion, "requestId": requestID]) as? [String: Any],
              row["requestId"] as? String == requestID, let answer = row["answer"] as? String, !answer.isEmpty,
              row["draftOnly"] as? Bool == true, let model = row["model"] as? String else { throw NativeAPIError.invalidData }
        try Task.checkCancellation()
        return NativeAIResult(id: requestID, answer: answer, model: model)
    }
}
