import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct RemoteImageFile: Sendable {
    let url: URL
    let thumbnail: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

enum RemoteImageDecoder {
    static let maxBytes = 16 * 1024 * 1024
    static func dataURL(_ value: String) throws -> Data {
        guard let comma = value.firstIndex(of: ","),
              value[..<comma].lowercased().hasPrefix("data:image/"),
              value[..<comma].lowercased().hasSuffix(";base64") else {
            throw ClientError(message: "图片接口未返回有效的图片内容")
        }
        let encoded = value[value.index(after: comma)...]
        guard encoded.utf8.count <= ((maxBytes + 2) / 3) * 4 else {
            throw ClientError(message: "图片超过 16 MB，无法预览")
        }
        guard let data = Data(base64Encoded: String(encoded)), !data.isEmpty, data.count <= maxBytes else {
            throw ClientError(message: "图片数据损坏或过大")
        }
        return data
    }

    static func file(_ data: Data, url: URL) throws -> RemoteImageFile {
        guard data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 40_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600
              ] as CFDictionary) else {
            throw ClientError(message: "无法解码图片，或图片尺寸过大")
        }
        let preview = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(preview, UTType.png.identifier as CFString, 1, nil) else {
            throw ClientError(message: "无法生成图片预览")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ClientError(message: "无法生成图片预览") }
        return RemoteImageFile(url: url, thumbnail: preview as Data, pixelWidth: width, pixelHeight: height)
    }
}

/// The key includes the service, profile, stored session and message: scratch paths may be reused.
actor RemoteImageCache {
    private let directory: URL
    private let maxDiskBytes: Int
    private var pending: [String: Task<RemoteImageFile, Error>] = [:]
    init(directory: URL? = nil, maxDiskBytes: Int = 200 * 1024 * 1024) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hermes.mac/Media", isDirectory: true)
        self.maxDiskBytes = maxDiskBytes
    }
    func image(for request: RemoteImageRequest, load: @escaping @Sendable () async throws -> Data) async throws -> RemoteImageFile {
        let keyData = try JSONEncoder().encode([
            request.conversation.service, request.conversation.profile, request.conversation.storedID,
            request.messageID, request.path
        ])
        let key = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined()
        if let task = pending[key] { return try await task.value }
        let target = directory.appendingPathComponent(key).appendingPathExtension((request.path as NSString).pathExtension.lowercased())
        let task = Task {
            if let data = try? Data(contentsOf: target), let cached = try? RemoteImageDecoder.file(data, url: target) {
                return cached
            }
            let data = try await load()
            let image = try RemoteImageDecoder.file(data, url: target)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            prune(excluding: target)
            return image
        }
        pending[key] = task
        defer { pending[key] = nil }
        return try await task.value
    }
    private func prune(excluding target: URL) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let entries = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? [])
            .compactMap { url -> (URL, Int, Date)? in
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        for (url, size, _) in entries where total > maxDiskBytes && url != target {
            if (try? FileManager.default.removeItem(at: url)) != nil { total -= size }
        }
    }
}
