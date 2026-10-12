import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RemoteImageView: View {
    let request: RemoteImageRequest
    let store: AppStore
    @State private var file: RemoteImageFile?
    @State private var thumbnail: NSImage?
    @State private var failure: String?
    @State private var attempt = 0
    @State private var previewing = false
    @State private var exporting = false
    @State private var exportFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let thumbnail {
                Button { previewing = true } label: {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 340)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("点击查看大图")
                .accessibilityLabel("查看图片：\(request.filename)")
            } else {
                HStack(alignment: .top, spacing: 10) {
                    if let failure {
                        Image(systemName: "photo.badge.exclamationmark")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("图片加载失败").font(.system(size: 12, weight: .semibold))
                            Text(failure).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                            Text("MEDIA:" + request.path).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary).textSelection(.enabled)
                            Button("重试") { self.failure = nil; attempt += 1 }
                                .controlSize(.small)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                        Text("正在加载图片…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
            }
            HStack(spacing: 8) {
                Text(request.filename)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if file != nil {
                    Button { previewing = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .help("查看大图").accessibilityLabel("查看大图")
                    Button { exporting = true } label: { Image(systemName: "square.and.arrow.down") }
                        .help("保存图片").accessibilityLabel("保存图片")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.04))
        }
        .frame(maxWidth: 560, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.18)))
        .contextMenu {
            if file != nil {
                Button("查看大图") { previewing = true }
                Button("保存图片…") { exporting = true }
            }
            Button("复制远程路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(request.path, forType: .string)
            }
        }
        .task(id: attempt) {
            do {
                let result = try await store.image(for: request)
                try Task.checkCancellation()
                guard let image = NSImage(data: result.thumbnail) else { throw ClientError(message: "无法显示图片预览") }
                file = result; thumbnail = image; failure = nil
            } catch is CancellationError {
                // A profile/session switch cancels this view, not the shared cache download.
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
        .sheet(isPresented: $previewing) {
            if let file { ImagePreviewView(file: file, filename: request.filename) }
        }
        .fileExporter(isPresented: $exporting,
                      document: file.map { ImageExportDocument(url: $0.url) },
                      contentType: UTType(filenameExtension: (request.path as NSString).pathExtension) ?? .image,
                      defaultFilename: request.filename) { result in
            if case .failure(let error) = result { exportFailure = error.localizedDescription }
        }
        .alert("图片保存失败", isPresented: Binding(get: { exportFailure != nil }, set: { if !$0 { exportFailure = nil } })) {
            Button("好", role: .cancel) { exportFailure = nil }
        } message: { Text(exportFailure ?? "") }
    }
}

private struct ImagePreviewView: View {
    let file: RemoteImageFile
    let filename: String
    @Environment(\.dismiss) private var dismiss
    @State private var zoom = 1.0
    @State private var image: NSImage?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(filename).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(file.pixelWidth) × \(file.pixelHeight)").font(.caption).foregroundStyle(.secondary)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            GeometryReader { geometry in
                if let image {
                    let fit = min((geometry.size.width - 24) / image.size.width, (geometry.size.height - 24) / image.size.height)
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: image.size.width * fit * zoom, height: image.size.height * fit * zoom)
                            .padding(12)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    }
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            HStack(spacing: 12) {
                Button("适合窗口") { zoom = 1 }
                Slider(value: $zoom, in: 1...5).frame(width: 200).accessibilityLabel("图片缩放")
                Text("\(Int(zoom * 100))%").monospacedDigit().frame(width: 50)
                Spacer()
            }
            .padding(12)
        }
        .frame(minWidth: 640, idealWidth: 860, minHeight: 480, idealHeight: 660)
        .task { image = NSImage(contentsOf: file.url) ?? NSImage(data: file.thumbnail) }
    }
}

private struct ImageExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.image] }
    let url: URL
    init(url: URL) { self.url = url }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.fileReadUnsupportedScheme) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }
}
