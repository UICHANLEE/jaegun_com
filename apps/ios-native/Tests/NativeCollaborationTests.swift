import XCTest
@testable import JaegunNative

final class NativeCollaborationTests: XCTestCase {
    func testChannelInputBoundariesAndVisibility() {
        XCTAssertTrue(NativeCollaborationPolicy.channelInput(name: "청년부", description: "", visibility: "public"))
        XCTAssertTrue(NativeCollaborationPolicy.channelInput(name: "소모임", description: "초대 모임", visibility: "private"))
        XCTAssertFalse(NativeCollaborationPolicy.channelInput(name: "  ", description: "", visibility: "public"))
        XCTAssertFalse(NativeCollaborationPolicy.channelInput(name: String(repeating: "가", count: 61), description: "", visibility: "public"))
        XCTAssertFalse(NativeCollaborationPolicy.channelInput(name: "모임", description: String(repeating: "가", count: 501), visibility: "public"))
        XCTAssertFalse(NativeCollaborationPolicy.channelInput(name: "모임", description: "", visibility: "global"))
    }
    func testTextValidationAndWaitlistLabel() {
        XCTAssertFalse(NativeCollaborationPolicy.textInput(" \n "))
        XCTAssertTrue(NativeCollaborationPolicy.textInput(String(repeating: "가", count: 4000)))
        XCTAssertFalse(NativeCollaborationPolicy.textInput(String(repeating: "가", count: 4001)))
        XCTAssertEqual(NativeCollaborationPolicy.responseLabel("waitlist"), "대기")
        XCTAssertEqual(NativeCollaborationPolicy.responseLabel(""), "미응답")
    }
}
