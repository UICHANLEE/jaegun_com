import XCTest
@testable import JaegunNative

final class NativeAITests: XCTestCase {
    private var notice: [String: Any] {
        ["version": "v1:sha256", "enabled": true, "recipient": "Local operator", "countries": "Local workstation only", "purpose": "Draft generation", "items": "Explicit prompt only", "retention": "Memory only", "refusal": "Decline without affecting membership", "contact": "Operator", "termsUrl": "https://example.test/terms", "model": "configured-model", "processingRegion": "us-east-1"]
    }
    func testNoticeRequiresAllFactualTransferFields() throws {
        let parsed = try NativeAITransferNotice(notice)
        XCTAssertTrue(parsed.enabled)
        XCTAssertEqual(parsed.version, "v1:sha256")
        for text in ["Local operator", "Local workstation only", "Explicit prompt only", "Memory only", "us-east-1", "configured-model"] { XCTAssertTrue(parsed.text.contains(text)) }
        for field in ["version", "recipient", "countries", "purpose", "items", "retention", "refusal", "contact", "termsUrl", "model", "processingRegion", "enabled"] {
            var incomplete = notice; incomplete.removeValue(forKey: field)
            XCTAssertThrowsError(try NativeAITransferNotice(incomplete), field)
        }
    }
    func testDisabledNoticeNeverBecomesAnApproval() throws {
        var disabled = notice; disabled["enabled"] = false
        XCTAssertFalse(try NativeAITransferNotice(disabled).enabled)
        disabled["enabled"] = "true"
        XCTAssertThrowsError(try NativeAITransferNotice(disabled))
    }
    func testRegionPinsProductionAndBoundsDebugException() throws {
        var local = notice
        local["processingRegion"] = "local-development"
        local["provider"] = "selfhost"
        #if DEBUG
        XCTAssertTrue(try NativeAITransferNotice(local).text.contains("local-development"))
        #else
        XCTAssertThrowsError(try NativeAITransferNotice(local))
        #endif
        local["provider"] = "gemini"
        XCTAssertThrowsError(try NativeAITransferNotice(local))
        local["processingRegion"] = "unapproved-region"
        XCTAssertThrowsError(try NativeAITransferNotice(local))
    }
}
