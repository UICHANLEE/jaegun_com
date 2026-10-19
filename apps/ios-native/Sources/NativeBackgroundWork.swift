import Foundation
import CoreGraphics
import ImageIO

// JSONSerialization creates immutable containers (no mutableContainers option).
// The result is transferred once to the caller; the worker never retains or
// mutates it. No account data is cached here.
struct NativeJSONPayload: @unchecked Sendable { let value: Any }
// CGImage is an immutable raster. UIKit construction stays on the main actor.
struct NativeDecodedImage: @unchecked Sendable { let image: CGImage }

enum NativeBackgroundWork {
    static func json(_ data: Data) async throws -> NativeJSONPayload {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let value = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            try Task.checkCancellation()
            return NativeJSONPayload(value: value)
        }
        let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        return result
    }

    static func thumbnail(_ data: Data, maximumPixelSize: Int = 2048) async throws -> NativeDecodedImage {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard (1...4096).contains(maximumPixelSize),
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
                  ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
            try Task.checkCancellation()
            return NativeDecodedImage(image: image)
        }
        let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        return result
    }
}
