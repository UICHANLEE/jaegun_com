import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, mkdtempSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";

const source = (file) => readFileSync(new URL(`../../apps/ios-native/Sources/${file}`, import.meta.url), "utf8");

test("actual Swift background JSON/image workers preserve data, bounds, alpha and cancellation", () => {
  const driver = `
Task {
  do {
    let fixture = (0..<5000).map { ["id": $0, "text": "공동체 테스트"] as [String: Any] }
    let data = try JSONSerialization.data(withJSONObject: fixture)
    let payload = try await NativeBackgroundWork.json(data)
    precondition((payload.value as? [[String: Any]])?.count == 5000)
    precondition(((payload.value as? [[String: Any]])?.last?["id"] as? Int) == 4999)
    let scalar = try await NativeBackgroundWork.json(Data("null".utf8))
    precondition(scalar.value is NSNull)
    do { _ = try await NativeBackgroundWork.json(Data("broken".utf8)); fatalError("invalid JSON accepted") } catch { }
    let context = CGContext(data: nil, width: 4000, height: 3000, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 0.5))
    context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
    let original = context.makeImage()!
    let bytes = NSMutableData()
    let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, original, nil)
    precondition(CGImageDestinationFinalize(destination))
    let imageData = bytes as Data
    let decoded = try await NativeBackgroundWork.thumbnail(imageData, maximumPixelSize: 512)
    precondition(decoded.image.width == 512 && decoded.image.height == 384)
    precondition(decoded.image.alphaInfo != .none && decoded.image.alphaInfo != .noneSkipLast && decoded.image.alphaInfo != .noneSkipFirst)
    precondition(decoded.image.bytesPerRow * decoded.image.height < original.bytesPerRow * original.height / 10)
    let rotatedBytes = NSMutableData()
    let rotatedDestination = CGImageDestinationCreateWithData(rotatedBytes, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(rotatedDestination, original, [kCGImagePropertyOrientation: 6] as CFDictionary)
    precondition(CGImageDestinationFinalize(rotatedDestination))
    let rotated = try await NativeBackgroundWork.thumbnail(rotatedBytes as Data, maximumPixelSize: 512)
    precondition(rotated.image.width == 384 && rotated.image.height == 512)
    do { _ = try await NativeBackgroundWork.thumbnail(Data("broken".utf8)); fatalError("invalid image accepted") } catch { }
    do { _ = try await NativeBackgroundWork.thumbnail(imageData, maximumPixelSize: 0); fatalError("invalid bound accepted") } catch { }
    let cancelled = Task { () throws -> NativeJSONPayload in
      withUnsafeCurrentTask { $0?.cancel() }
      return try await NativeBackgroundWork.json(data)
    }
    cancelled.cancel()
    do { _ = try await cancelled.value; fatalError("cancellation lost") } catch is CancellationError { }
    let cancelledImage = Task { () throws -> NativeDecodedImage in
      withUnsafeCurrentTask { $0?.cancel() }
      return try await NativeBackgroundWork.thumbnail(imageData)
    }
    do { _ = try await cancelledImage.value; fatalError("image cancellation lost") } catch is CancellationError { }
    print("JSON:5000 rows; image:4000x3000 -> 512x384; alpha/errors/cancellation passed")
    exit(0)
  } catch { print("Worker test failed: \\(error)"); exit(1) }
}
dispatchMain()
`;
  const cache = mkdtempSync(join(tmpdir(), "jaegun-background-swift-"));
  const result = execFileSync("xcrun", ["swift", "-module-cache-path", cache, "-e", source("NativeBackgroundWork.swift") + driver], { encoding: "utf8", timeout: 60000 });
  assert.match(result, /JSON:5000 rows; image:4000x3000 -> 512x384; alpha\/errors\/cancellation passed/);
});

test("integration preserves protected-read order and rejects stale UI results", () => {
  assert.ok(source("NativeAPI.swift").includes("(try await NativeBackgroundWork.json(data)).value"));
  const media = source("NativeMedia.swift");
  assert.ok(media.includes("NativeBackgroundWork.thumbnail(bytes)"));
  assert.ok(media.includes("guard identity == actor, phase == .active, !Task.isCancelled"));
  assert.ok(media.includes('["expiresIn":60]'));
  const bible = source("NativeBibleReader.swift");
  assert.ok(bible.includes("try existingManifest ?? NativeBibleText.manifest()"));
  assert.ok(bible.includes("readRequestID == request"));
  assert.ok(bible.includes("SHA256.hash(data: bytes)"));
  const detail = source("NativeBoardPostDetailView.swift");
  assert.ok(detail.indexOf('"list_community_posts"') < detail.indexOf("async let mediaRead"));
  assert.ok(detail.includes("let (mediaRows, commentValue) = try await (mediaRead, commentsRead)"));
  const feed = source("NativeBoardFeedView.swift");
  assert.ok(feed.includes("let visiblePosts = displayedPosts"));
  assert.ok(!feed.includes("displayedPosts[index]"));
  for (const file of ["NativeMeetingViews.swift", "NativeLiveViews.swift"]) {
    assert.ok(source(file).includes("guard !Task.isCancelled, identity == boundIdentity, tabActive, scenePhase == .active"));
  }
});
