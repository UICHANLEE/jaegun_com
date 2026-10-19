import SwiftUI
import PhotosUI
import AVKit
import UniformTypeIdentifiers
import Combine

struct NativeMediaAttachment: Identifiable {
    let id: String
    let path: String
    let kind: String
    let mimeType: String
    let byteSize: Int
    let fileName: String
    var channelPayload: [String: Any] { ["id": id, "path": path, "kind": kind, "mimeType": mimeType, "byteSize": byteSize, "fileName": fileName] }
}

enum NativeMediaPolicy {
    static let formats = ["image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/avif": "avif", "image/heic": "heic", "image/heif": "heif", "video/mp4": "mp4", "video/quicktime": "mov", "video/webm": "webm"]
    static func detectedMime(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(32))
        func ascii(_ start: Int, _ end: Int) -> String { b.count >= end ? String(bytes: b[start..<end], encoding: .ascii) ?? "" : "" }
        if b.starts(with: [255,216,255]) { return "image/jpeg" }
        if b.starts(with: [137,80,78,71,13,10,26,10]) { return "image/png" }
        if ascii(0,4) == "RIFF", ascii(8,12) == "WEBP" { return "image/webp" }
        if b.starts(with: [26,69,223,163]) { return "video/webm" }
        if ascii(4,8) == "ftyp" {
            let brand = ascii(8,12)
            if ["avif","avis"].contains(brand) { return "image/avif" }
            if ["heic","heix","hevc","hevx"].contains(brand) { return "image/heic" }
            if ["heif","heim","heis","mif1","msf1"].contains(brand) { return "image/heif" }
            return brand == "qt  " ? "video/quicktime" : "video/mp4"
        }
        return nil
    }
    static func valid(path: String, bucket: String) -> Bool {
        guard ["community-media", "avatars"].contains(bucket), !path.contains(".."), !path.contains("\\") else { return false }
        let parts = path.split(separator: "/")
        return parts.count >= 2 && parts.count <= 4 && parts.allSatisfy { !$0.isEmpty && $0.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil }
    }
}

@MainActor final class NativeMediaService {
    private weak var session: NativeSession?
    private var cache: [String: (URL, Date)] = [:]
    private var binding = ""
    private var transport: URLSession
    private var transition = UUID()
    private var transitions: AnyCancellable?
    private var pendingUploads: [String:NativeMediaAttachment] = [:]
    private static func makeTransport() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration:configuration)
    }
    init(session: NativeSession, transport: URLSession? = nil) {
        self.session=session; self.transport=transport ?? Self.makeTransport()
        transitions=Publishers.CombineLatest3(session.$context,session.$signedIn,session.$consentRequired)
            .map { value in
                let member=value.0["membership"] as? [String:Any] ?? [:]
                let profile=value.0["profile"] as? [String:Any] ?? [:]
                return "\(value.1):\(value.2):\(nativeText(member,"organization_id")):\(nativeText(member,"status")):\(nativeText(profile,"id"))"
            }.removeDuplicates().dropFirst().sink { [weak self] _ in self?.clear() }
    }
    func clear() { pendingUploads.removeAll(); clearSignedURLs() }
    func clearSignedURLs() { cache.removeAll(); binding = ""; transition=UUID(); transport.invalidateAndCancel(); transport=Self.makeTransport() }
    private func identity() throws -> String {
        guard let session, session.signedIn, !session.consentRequired,
              nativeText(session.context["membership"] as? [String: Any] ?? [:], "status") == "active",
              UUID(uuidString:nativeText(session.context["profile"] as? [String:Any] ?? [:],"id")) != nil,
              UUID(uuidString:nativeText(session.context["membership"] as? [String:Any] ?? [:],"organization_id")) != nil else { clear(); throw NativeAPIError.sessionExpired }
        let value = "\(session.sessionGeneration):\(nativeText(session.context["profile"] as? [String: Any] ?? [:], "id")):\(nativeText(session.context["membership"] as? [String: Any] ?? [:], "organization_id")):\(transition)"
        if binding != value { cache.removeAll(); binding = value }
        return value
    }
    private func validate(_ actor: String) throws { guard try identity() == actor, !Task.isCancelled else { throw CancellationError() } }
    private func authorizedRequest(path: String, method: String) async throws -> (URLRequest, String) {
        let actor = try identity()
        guard let session else { throw NativeAPIError.sessionExpired }
        if session.api.tokens?.expiresAt.timeIntervalSinceNow ?? 0 < 90 { try await session.api.refresh() }
        try validate(actor)
        guard let token = session.api.tokens?.accessToken, var components = URLComponents(url: NativeConfig.url, resolvingAgainstBaseURL: false), components.scheme == "https" else { throw NativeAPIError.sessionExpired }
        components.path = path
        guard let url = components.url else { throw NativeAPIError.invalidData }
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue(NativeConfig.key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return (request, actor)
    }
    func upload(fileURL: URL, purpose: String, targetID: String, organizationID: String, onObjectPathCreated: ((String)->Void)? = nil) async throws -> NativeMediaAttachment {
        guard let directory = ["post":"posts", "message":"messages", "channel":"channels"][purpose], UUID(uuidString: targetID) != nil, UUID(uuidString: organizationID) != nil else { throw NativeAPIError.invalidData }
        let actor = try identity()
        guard let session, nativeText(session.context["membership"] as? [String: Any] ?? [:], "organization_id").lowercased() == organizationID.lowercased() else { throw NativeAPIError.security("업로드할 교회를 다시 확인해 주세요.") }
        let resource = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        let handle = try FileHandle(forReadingFrom: fileURL); defer { try? handle.close() }
        guard resource.isRegularFile == true, let size = resource.fileSize, size > 0,
              let mime = NativeMediaPolicy.detectedMime(try handle.read(upToCount: 32) ?? Data()), let ext = NativeMediaPolicy.formats[mime],
              size <= (mime.hasPrefix("image/") ? 15 * 1024 * 1024 : 500 * 1024 * 1024) else { throw NativeAPIError.security("사진은 15MB, 영상은 500MB까지 지원합니다. 원본 사진·영상 파일을 선택해 주세요.") }
        let key="\(session.sessionGeneration):\(nativeText(session.context["profile"] as? [String:Any] ?? [:],"id")):\(organizationID.lowercased()):\(purpose):\(targetID.lowercased()):\(fileURL.path):\(size):\(mime)"
        let existing=pendingUploads[key]
        let attachment:NativeMediaAttachment
        if let existing { attachment=existing }
        else {
            let id=UUID().uuidString.lowercased()
            let path="\(organizationID.lowercased())/\(directory)/\(targetID.lowercased())/\(id).\(ext)"
            attachment=NativeMediaAttachment(id:id,path:path,kind:mime.hasPrefix("image/") ? "image" : "video",mimeType:mime,byteSize:size,fileName:"\(id).\(ext)")
            pendingUploads[key]=attachment
        }
        try validate(actor)
        onObjectPathCreated?(attachment.path)
        if existing != nil, try await uploadedObjectMatches(attachment,actor:actor) { return attachment }
        var (request, _) = try await authorizedRequest(path: "/storage/v1/object/community-media/\(attachment.path)", method: "POST")
        try validate(actor)
        request.setValue(mime, forHTTPHeaderField: "Content-Type"); request.setValue("false", forHTTPHeaderField: "x-upsert")
        let (_, raw) = try await transport.upload(for: request, fromFile: fileURL)
        try validate(actor)
        guard let response=raw as? HTTPURLResponse else { throw NativeAPIError.invalidData }
        guard (200..<300).contains(response.statusCode) else { throw NativeAPIError.response(response.statusCode) }
        return attachment
    }
    private func uploadedObjectMatches(_ attachment:NativeMediaAttachment,actor:String) async throws -> Bool {
        let (request,_)=try await authorizedRequest(path:"/storage/v1/object/info/community-media/\(attachment.path)",method:"GET")
        let (data,raw)=try await transport.data(for:request)
        try validate(actor)
        guard let response=raw as? HTTPURLResponse else { throw NativeAPIError.invalidData }
        if response.statusCode == 404 { return false }
        if response.statusCode == 400, let failure=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
           ["NoSuchKey","not_found","404"].contains(nativeText(failure,"code",fallback:nativeText(failure,"statusCode"))) { return false }
        guard (200..<300).contains(response.statusCode) else { throw NativeAPIError.response(response.statusCode) }
        guard let info=try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw NativeAPIError.invalidData }
        let metadata=info["metadata"] as? [String:Any] ?? [:]
        let size=(info["size"] as? NSNumber)?.intValue ?? (metadata["size"] as? NSNumber)?.intValue
        let mime=nativeText(info,"content_type",fallback:nativeText(info,"contentType",fallback:nativeText(metadata,"mimetype")))
        guard size == attachment.byteSize, mime == attachment.mimeType else { throw NativeAPIError.security("이전 업로드의 크기·형식이 일치하지 않습니다. 업로드를 중단했습니다.") }
        return true
    }
    func signedURL(path: String, bucket: String = "community-media", forceRefresh: Bool = false) async throws -> URL {
        guard NativeMediaPolicy.valid(path: path, bucket: bucket) else { throw NativeAPIError.invalidData }
        let actor = try identity(); let key = "\(actor):\(bucket):\(path)"
        if !forceRefresh, let cached = cache[key], cached.1 > Date() { return cached.0 }
        var (request, _) = try await authorizedRequest(path: "/storage/v1/object/sign/\(bucket)/\(path)", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["expiresIn":60])
        let (data, raw) = try await transport.data(for: request)
        try validate(actor)
        guard let response = raw as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], let signed = value["signedURL"] as? String,
              let url = URL(string: signed.hasPrefix("/") ? "\(NativeConfig.url.absoluteString.trimmingCharacters(in:CharacterSet(charactersIn:"/")))/storage/v1\(signed)" : signed),
              url.scheme == "https", url.host == NativeConfig.url.host else { throw NativeAPIError.security("미디어 접근 권한이 없거나 링크 발급이 실패했습니다.") }
        cache[key] = (url, Date().addingTimeInterval(45)); return url
    }
    func imageData(path:String,bucket:String = "community-media") async throws -> Data {
        let actor=try identity(); let url=try await signedURL(path:path,bucket:bucket)
        let (data,response)=try await transport.data(from:url)
        try validate(actor)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 15 * 1024 * 1024 else { throw NativeAPIError.invalidData }
        return data
    }
    func remove(paths:[String],bucket:String = "community-media") async throws {
        guard !paths.isEmpty else { return }
        guard paths.count <= 8, paths.allSatisfy({ NativeMediaPolicy.valid(path:$0,bucket:bucket) }) else { throw NativeAPIError.invalidData }
        var (request,actor)=try await authorizedRequest(path:"/storage/v1/object/\(bucket)",method:"DELETE")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody=try JSONSerialization.data(withJSONObject:["prefixes":paths])
        let (_,raw)=try await transport.data(for:request)
        try validate(actor)
        guard let response=raw as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw NativeAPIError.security("첨부 정리를 완료하지 못했습니다. 같은 삭제 요청을 다시 확인해 주세요.") }
        cache.removeAll()
        let removed=Set(paths); pendingUploads=pendingUploads.filter { !removed.contains($0.value.path) }
    }
    func abandon(paths:[String],bucket:String = "community-media") async throws {
        guard !paths.isEmpty else { return }
        guard paths.count<=20, paths.allSatisfy({ NativeMediaPolicy.valid(path:$0,bucket:bucket) }), let session else { throw NativeAPIError.invalidData }
        let actor=try identity()
        let response=try await session.api.rpc("abandon_direct_media_objects",body:["p_bucket_id":bucket,"p_storage_paths":paths])
        try validate(actor)
        guard let value=response as? [String:Any] else { throw NativeAPIError.invalidData }
        let queued=(value["queued_count"] as? NSNumber)?.intValue ?? -1
        let existing=(value["already_queued_count"] as? NSNumber)?.intValue ?? -1
        guard value["cleanup_queued"] as? Bool == true || (queued>=0 && existing>=0 && queued+existing == paths.count) else { throw NativeAPIError.security("첨부 정리 예약을 확인하지 못했습니다. 같은 요청으로 다시 확인해 주세요.") }
        let abandoned=Set(paths); pendingUploads=pendingUploads.filter { !abandoned.contains($0.value.path) }; cache.removeAll()
    }
}

struct NativeMediaPicker: View {
    @EnvironmentObject private var session: NativeSession
    @Binding var files: [URL]
    var maximum = 4
    @State private var selected: [PhotosPickerItem] = []
    @State private var loading = false
    @State private var error: String?
    private var identity: String { collaborationIdentity(session) }
    var body: some View {
        VStack(alignment: .leading) {
            PhotosPicker(selection: $selected, maxSelectionCount: max(1,maximum), matching: .any(of: [.images, .videos])) { Label(loading ? "미디어 준비 중" : "사진·영상 (\(files.count)/\(max(0,maximum)))", systemImage: "photo.on.rectangle") }.disabled(loading || maximum <= 0 || identity.isEmpty)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if !files.isEmpty { Button("첨부 선택 지우기", role: .destructive) { files.forEach { try? FileManager.default.removeItem(at: $0) }; files = []; selected = [] } }
        }.onChange(of: selected) { _, items in
            Task { @MainActor in
                let actor=identity
                loading = true; error = nil
                defer { if identity == actor && selected == items { loading=false } }
                var prepared: [URL] = []
                do {
                    for item in items.prefix(max(0,maximum)) {
                        guard !actor.isEmpty, identity == actor, selected == items, !Task.isCancelled else { throw CancellationError() }
                        guard let media=try await item.loadTransferable(type:NativePickedMedia.self) else { throw NativeAPIError.invalidData }
                        prepared.append(media.url)
                    }
                    guard !Task.isCancelled, selected == items, identity == actor else { prepared.forEach { try? FileManager.default.removeItem(at: $0) }; return }
                    files.forEach { try? FileManager.default.removeItem(at: $0) }; files = prepared
                } catch {
                    prepared.forEach { try? FileManager.default.removeItem(at:$0) }
                    if identity == actor && selected == items { self.error="사진·영상을 준비하지 못했습니다. 원본 파일을 다시 선택해 주세요." }
                }
            }
        }
        .onChange(of:identity) { _, _ in
            selected=[]; files.forEach { try? FileManager.default.removeItem(at:$0) }; files=[]; loading=false; error=nil
        }
    }
}

private struct NativePickedMedia: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in try copy(received.file) }
        FileRepresentation(importedContentType: .movie) { received in try copy(received.file) }
    }
    private static func copy(_ file: URL) throws -> Self {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(file.pathExtension)
        try FileManager.default.copyItem(at: file, to: destination)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
        return Self(url: destination)
    }
}

struct NativeMediaView: View {
    @EnvironmentObject private var session: NativeSession
    @Environment(\.scenePhase) private var phase
    let path: String
    let kind: String
    var bucket = "community-media"
    @State private var service: NativeMediaService?
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var error: String?
    @State private var retry = UUID()
    @State private var loadedIdentity = ""
    private var identity: String { "\(session.sessionGeneration):\(session.signedIn):\(session.consentRequired):\(nativeText(session.context["membership"] as? [String: Any] ?? [:], "status")):\(nativeText(session.context["membership"] as? [String: Any] ?? [:], "organization_id")):\(bucket):\(path)" }
    var body: some View {
        VStack {
            if loadedIdentity == identity, phase == .active, session.signedIn, !session.consentRequired, let image { Image(uiImage: image).resizable().scaledToFit() }
            else if loadedIdentity == identity, phase == .active, session.signedIn, !session.consentRequired, let player { VideoPlayer(player: player).frame(minHeight: 200) }
            else if let error { Text(error).font(.caption).foregroundStyle(.red); Button("미디어 다시 확인") { retry = UUID() } }
            else { ProgressView("미디어 확인 중") }
        }.task(id: "\(identity):\(path):\(retry):\(phase == .active)") {
            let actor = identity; clear()
            guard phase == .active, session.signedIn, !session.consentRequired else { return }
            let service = NativeMediaService(session: session); self.service = service
            do {
                repeat {
                    guard identity == actor, !Task.isCancelled else { return }
                    if kind == "video" {
                        let url = try await service.signedURL(path: path, bucket: bucket, forceRefresh: true)
                        guard identity == actor, !Task.isCancelled else { return }
                        let time = player?.currentTime() ?? .zero; let playing = (player?.rate ?? 0) > 0
                        let item = AVPlayerItem(url: url)
                        if let player {
                            player.replaceCurrentItem(with: item)
                            _ = await player.seek(to: time)
                            guard identity == actor, !Task.isCancelled, phase == .active, self.player === player else { player.pause(); return }
                            if playing { player.play() }
                        }
                        else { player = AVPlayer(playerItem: item) }
                        loadedIdentity=actor
                        try await Task.sleep(for: .seconds(40))
                    } else {
                        let bytes = try await service.imageData(path:path,bucket:bucket)
                        guard identity == actor, !Task.isCancelled else { return }
                        let decoded = try await NativeBackgroundWork.thumbnail(bytes)
                        guard identity == actor, phase == .active, !Task.isCancelled else { return }
                        image = UIImage(cgImage: decoded.image); loadedIdentity=actor; break
                    }
                } while !Task.isCancelled && identity == actor
            } catch { guard identity == actor, !Task.isCancelled else { return }; clear(); self.error = error.localizedDescription }
        }.onDisappear { clear() }
    }
    private func clear() { service?.clear(); service = nil; player?.pause(); player = nil; image = nil; loadedIdentity=""; error = nil }
}
