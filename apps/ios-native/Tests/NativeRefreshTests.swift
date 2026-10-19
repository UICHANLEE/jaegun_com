import XCTest
@testable import JaegunNative

private final class RefreshProtocol: URLProtocol {
    static let lock = NSLock()
    static var started: XCTestExpectation?
    static var pending: RefreshProtocol?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.pending = self; let started = Self.started; Self.lock.unlock()
        started?.fulfill()
    }
    override func stopLoading() {}
    static func complete() throws {
        lock.lock(); let pending = pending; self.pending = nil; lock.unlock()
        let request = try XCTUnwrap(pending)
        let data = try JSONSerialization.data(withJSONObject: ["access_token": "refreshed-access", "refresh_token": "refreshed-old-actor", "expires_in": 3600, "user": ["id": "10000000-0000-0000-0000-000000000001"]])
        request.client?.urlProtocol(request, didReceive: HTTPURLResponse(url: request.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        request.client?.urlProtocol(request, didLoad: data)
        request.client?.urlProtocolDidFinishLoading(request)
    }
}

final class NativeRefreshTests: XCTestCase {
    @MainActor func testConcurrentReadsShareOneRefreshAndPersistOnce() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefreshProtocol.self]
        let transport = URLSession(configuration: config)
        defer { transport.invalidateAndCancel() }
        let api = NativeAPI(transport: transport)
        api.tokens = NativeTokens(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .distantPast)
        var persisted = 0
        api.didRefresh = { _ in persisted += 1 }
        let started = expectation(description: "one shared refresh")
        RefreshProtocol.lock.withLock { RefreshProtocol.started = started }
        let first = Task { try await api.refresh() }
        let second = Task { try await api.refresh() }
        await fulfillment(of: [started], timeout: 3)
        try RefreshProtocol.complete()
        try await first.value
        try await second.value
        XCTAssertEqual(api.tokens?.refreshToken, "refreshed-old-actor")
        XCTAssertEqual(persisted, 1)
    }
    @MainActor func testConcurrentRefreshCannotRestoreLoggedOutCredentials() async throws {
        try await exercise(replacement: nil)
    }
    @MainActor func testConcurrentRefreshCannotOverwriteDifferentAccount() async throws {
        try await exercise(replacement: NativeTokens(accessToken: "new-actor-access", refreshToken: "new-actor-refresh", expiresAt: .distantFuture))
    }
    @MainActor private func exercise(replacement: NativeTokens?) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefreshProtocol.self]
        let transport = URLSession(configuration: config)
        defer { transport.invalidateAndCancel() }
        let api = NativeAPI(transport: transport)
        api.tokens = NativeTokens(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .distantPast)
        var persisted = 0
        api.didRefresh = { _ in persisted += 1 }
        let started = expectation(description: "refresh request held in transport")
        RefreshProtocol.lock.withLock { RefreshProtocol.started = started }
        let first = Task { try await api.refresh() }
        let second = Task { try await api.refresh() }
        await fulfillment(of: [started], timeout: 3)
        api.tokens = replacement
        try RefreshProtocol.complete()
        for task in [first, second] {
            do { try await task.value; XCTFail("An old actor refresh must fail after a session transition") }
            catch { guard case NativeAPIError.sessionExpired = error else { throw error } }
        }
        XCTAssertEqual(api.tokens?.refreshToken, replacement?.refreshToken)
        XCTAssertEqual(persisted, 0)
    }
}
