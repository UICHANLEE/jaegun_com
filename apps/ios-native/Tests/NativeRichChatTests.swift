import XCTest
@testable import JaegunNative

private final class MediaSigningProtocol: URLProtocol {
    static let lock = NSLock()
    static var pending: MediaSigningProtocol?
    static var started: XCTestExpectation?
    static var count = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.pending=self; Self.count += 1; let started=Self.started; Self.lock.unlock(); started?.fulfill()
    }
    override func stopLoading() {}
    static func complete(signed:String = "/object/sign/community-media/church/messages/conversation/file.jpg?token=private") throws {
        try completePayload(["signedURL":signed])
    }
    static func completePayload(_ payload:[String:Any],status:Int=200) throws {
        lock.lock(); let pending=pending; self.pending=nil; lock.unlock()
        let request=try XCTUnwrap(pending)
        request.client?.urlProtocol(request,didReceive:HTTPURLResponse(url:request.request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        request.client?.urlProtocol(request,didLoad:try JSONSerialization.data(withJSONObject:payload))
        request.client?.urlProtocolDidFinishLoading(request)
    }
}

final class NativeRichChatTests: XCTestCase {
    private let actor="aa600000-0000-4000-8000-000000000001"
    private let church="aa600000-0000-4000-8000-000000000002"
    private let path="aa600000-0000-4000-8000-000000000002/channels/aa600000-0000-4000-8000-000000000003/aa600000-0000-4000-8000-000000000004.jpg"
    func testSignatureValidationRejectsDocumentsAndRecognizesAllowedNativeMedia() {
        XCTAssertNil(NativeMediaPolicy.detectedMime(Data("%PDF-1.7".utf8)))
        XCTAssertNil(NativeMediaPolicy.detectedMime(Data([80,75,3,4])))
        XCTAssertNil(NativeMediaPolicy.detectedMime(Data("<svg/>".utf8)))
        XCTAssertEqual(NativeMediaPolicy.detectedMime(Data([255,216,255,0])),"image/jpeg")
        XCTAssertEqual(NativeMediaPolicy.detectedMime(Data([137,80,78,71,13,10,26,10])),"image/png")
        XCTAssertEqual(NativeMediaPolicy.detectedMime(Data([0,0,0,24]+Array("ftypheic".utf8))),"image/heic")
        XCTAssertEqual(NativeMediaPolicy.detectedMime(Data([0,0,0,24]+Array("ftypqt  ".utf8))),"video/quicktime")
        XCTAssertEqual(NativeMediaPolicy.detectedMime(Data([0,0,0,24]+Array("ftypisom".utf8))),"video/mp4")
    }
    func testPrivateMediaPathRejectsTraversalURLsAndUnknownBucket() {
        XCTAssertTrue(NativeMediaPolicy.valid(path:path,bucket:"community-media"))
        XCTAssertFalse(NativeMediaPolicy.valid(path:"church/../secret.jpg",bucket:"community-media"))
        XCTAssertFalse(NativeMediaPolicy.valid(path:"https://outside.example/image.jpg",bucket:"community-media"))
        XCTAssertFalse(NativeMediaPolicy.valid(path:"church/messages/room/file.jpg?token=attacker",bucket:"community-media"))
        XCTAssertFalse(NativeMediaPolicy.valid(path:path,bucket:"documents"))
    }
    func testRealtimeUsesBoundedBackoffAndRequiresExactJoinReply() {
        XCTAssertEqual((0...7).map(NativeRealtimePolicy.retryDelay),[1,2,4,8,16,30,30,30])
        XCTAssertTrue(NativeRealtimePolicy.validReply(["event":"phx_reply","ref":"join","payload":["status":"ok"]],reference:"join"))
        XCTAssertFalse(NativeRealtimePolicy.validReply(["event":"phx_reply","ref":"old","payload":["status":"ok"]],reference:"join"))
        XCTAssertFalse(NativeRealtimePolicy.validReply(["event":"phx_reply","ref":"join","payload":["status":"error"]],reference:"join"))
        let subscription=NativeRealtimeChange(table:"channel_change_events",filter:"channel_id=eq.channel").payload
        XCTAssertEqual(subscription["table"] as? String,"channel_change_events")
        XCTAssertEqual(subscription["filter"] as? String,"channel_id=eq.channel")
    }
    @MainActor private func makeSession() -> NativeSession {
        let session=NativeSession(); session.signedIn=true; session.consentRequired=false
        session.context=["profile":["id":actor],"membership":["organization_id":church,"status":"active"]]
        session.api.tokens=NativeTokens(accessToken:"actor-token",refreshToken:"refresh-token",expiresAt:.distantFuture)
        return session
    }
    private func makeTransport() -> URLSession {
        let config=URLSessionConfiguration.ephemeral; config.protocolClasses=[MediaSigningProtocol.self]
        return URLSession(configuration:config)
    }
    @MainActor func testSigningUsesActorBearerSixtySecondTTLAndMemoryCache() async throws {
        let session=makeSession(); let transport=makeTransport(); defer { transport.invalidateAndCancel() }
        let media=NativeMediaService(session:session,transport:transport)
        let started=expectation(description:"signing request")
        MediaSigningProtocol.lock.withLock { MediaSigningProtocol.started=started; MediaSigningProtocol.count=0 }
        let task=Task { try await media.signedURL(path:path) }
        await fulfillment(of:[started],timeout:3)
        let request=try XCTUnwrap(MediaSigningProtocol.lock.withLock { MediaSigningProtocol.pending?.request })
        XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer actor-token")
        XCTAssertEqual(request.url?.path,"/storage/v1/object/sign/community-media/\(path)")
        var body=request.httpBody
        if body == nil, let stream=request.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes=[UInt8](repeating:0,count:1024); let count=stream.read(&bytes,maxLength:bytes.count); if count>0 { body=Data(bytes.prefix(count)) }
        }
        let payload=try JSONSerialization.jsonObject(with:try XCTUnwrap(body)) as? [String:Any]
        XCTAssertEqual((payload?["expiresIn"] as? NSNumber)?.intValue,60)
        try MediaSigningProtocol.complete()
        let first=try await task.value; let cached=try await media.signedURL(path:path)
        XCTAssertEqual(first,cached)
        XCTAssertEqual(MediaSigningProtocol.lock.withLock { MediaSigningProtocol.count },1)
        XCTAssertEqual(first.host,NativeConfig.url.host)
        let renewing=expectation(description:"video renewal bypasses cached bearer")
        MediaSigningProtocol.lock.withLock { MediaSigningProtocol.started=renewing }
        let renewal=Task { try await media.signedURL(path:path,forceRefresh:true) }
        await fulfillment(of:[renewing],timeout:3); try MediaSigningProtocol.complete()
        _=try await renewal.value
        XCTAssertEqual(MediaSigningProtocol.lock.withLock { MediaSigningProtocol.count },2)
    }
    @MainActor func testUncertainUploadReconcilesExactObjectInsteadOfUploadingAnotherPath() async throws {
        let session=makeSession(); let transport=makeTransport(); defer { transport.invalidateAndCancel() }
        let media=NativeMediaService(session:session,transport:transport)
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        try Data([255,216,255,0]).write(to:file); defer { try? FileManager.default.removeItem(at:file) }
        var intended:[String]=[]
        let started=expectation(description:"first upload request")
        MediaSigningProtocol.lock.withLock { MediaSigningProtocol.started=started; MediaSigningProtocol.count=0 }
        let first=Task { try await media.upload(fileURL:file,purpose:"channel",targetID:actor,organizationID:church,onObjectPathCreated:{ intended.append($0) }) }
        await fulfillment(of:[started],timeout:3)
        try MediaSigningProtocol.completePayload(["message":"upstream unavailable"],status:503)
        do { _=try await first.value; XCTFail("Uncertain upload must ask for explicit retry") } catch { }
        XCTAssertEqual(intended.count,1)
        let checking=expectation(description:"reconcile uploaded object metadata")
        MediaSigningProtocol.lock.withLock { MediaSigningProtocol.started=checking }
        let retry=Task { try await media.upload(fileURL:file,purpose:"channel",targetID:actor,organizationID:church,onObjectPathCreated:{ intended.append($0) }) }
        await fulfillment(of:[checking],timeout:3)
        let request=try XCTUnwrap(MediaSigningProtocol.lock.withLock { MediaSigningProtocol.pending?.request })
        XCTAssertEqual(request.httpMethod,"GET")
        XCTAssertEqual(request.url?.path,"/storage/v1/object/info/community-media/\(intended[0])")
        try MediaSigningProtocol.completePayload(["size":4,"content_type":"image/jpeg"])
        let attachment=try await retry.value
        XCTAssertEqual(attachment.path,intended[0])
        XCTAssertEqual(intended,[attachment.path,attachment.path])
        XCTAssertEqual(MediaSigningProtocol.lock.withLock { MediaSigningProtocol.count },2)
    }
    @MainActor func testSigningRejectsResponseAfterActorTransition() async throws {
        let session=makeSession(); let transport=makeTransport(); defer { transport.invalidateAndCancel() }
        let media=NativeMediaService(session:session,transport:transport)
        let started=expectation(description:"held actor-bound response")
        MediaSigningProtocol.lock.withLock { MediaSigningProtocol.started=started; MediaSigningProtocol.count=0 }
        let task=Task { try await media.signedURL(path:path) }
        await fulfillment(of:[started],timeout:3)
        session.context=["profile":["id":"aa600000-0000-4000-8000-000000000009"],"membership":["organization_id":church,"status":"active"]]
        try MediaSigningProtocol.complete()
        do { _=try await task.value; XCTFail("Old actor's signed URL must not be returned or cached") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled || NativeChatFailurePolicy.requiresClearingProtectedContent(error)) }
    }
    @MainActor func testConsentClosedMediaFailsBeforeNetwork() async throws {
        let session=makeSession(); session.consentRequired=true
        let media=NativeMediaService(session:session)
        do { _=try await media.signedURL(path:path); XCTFail("Consent gate must deny signed media") }
        catch { guard case NativeAPIError.sessionExpired=error else { throw error } }
    }
    @MainActor func testAttachmentPayloadCannotCarryMentionsOrForwardedMedia() {
        let media=NativeMediaAttachment(id:actor,path:path,kind:"image",mimeType:"image/jpeg",byteSize:120,fileName:"사진.jpg")
        XCTAssertEqual(Set(media.channelPayload.keys),Set(["id","path","kind","mimeType","byteSize","fileName"]))
        XCTAssertNil(media.channelPayload["mentionUserIds"])
        XCTAssertNil(media.channelPayload["url"])
    }
}
