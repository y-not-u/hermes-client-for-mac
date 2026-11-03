import AppKit
import UniformTypeIdentifiers

struct ComposerAttachment: Identifiable {
    static let maxBytes = 10 * 1024 * 1024
    static let maxCount = 8
    static let maxTotalBytes = 32 * 1024 * 1024

    let id = UUID()
    let name: String
    let data: Data
    let mimeType: String

    var isImage: Bool { mimeType.hasPrefix("image/") }

    init(name: String, data: Data, mimeType: String) throws {
        guard data.count <= Self.maxBytes else { throw ClientError(message: "附件 \(name) 超过 10 MB 限制") }
        self.name = name; self.data = data; self.mimeType = mimeType
    }

    /// File URLs take precedence over a Finder item's thumbnail or text representation.
    @MainActor static func read(from pasteboard: NSPasteboard) throws -> [ComposerAttachment] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            guard urls.count <= maxCount else { throw ClientError(message: "一次最多粘贴 8 个附件") }
            return try urls.map { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { throw ClientError(message: "暂不支持粘贴文件夹：\(url.lastPathComponent)") }
                guard (values.fileSize ?? 0) <= maxBytes else { throw ClientError(message: "附件 \(url.lastPathComponent) 超过 10 MB 限制") }
                let type = UTType(filenameExtension: url.pathExtension)
                let supportedImages = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]
                let mime = supportedImages.contains(url.pathExtension.lowercased()) ? (type?.preferredMIMEType ?? "application/octet-stream") : "application/octet-stream"
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
                return try ComposerAttachment(name: url.lastPathComponent, data: data, mimeType: mime)
            }
        }
        let items = (pasteboard.pasteboardItems ?? []).filter { $0.availableType(from: [.png, .tiff]) != nil }
        guard items.count <= maxCount else { throw ClientError(message: "一次最多粘贴 8 个附件") }
        return try items.compactMap { item in
            if let png = item.data(forType: .png) {
                return try ComposerAttachment(name: "粘贴图片.png", data: png, mimeType: "image/png")
            }
            if let tiff = item.data(forType: .tiff) {
                guard tiff.count <= maxBytes,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
                      bitmap.pixelsWide <= 40_000_000 / bitmap.pixelsHigh,
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw ClientError(message: "无法读取剪贴板图片，或图片超过 10 MB 限制")
                }
                return try ComposerAttachment(name: "粘贴图片.png", data: png, mimeType: "image/png")
            }
            return nil
        }
    }
}
