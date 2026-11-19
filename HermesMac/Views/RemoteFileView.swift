import SwiftUI
import AppKit

/// A non-image `MEDIA:` path from an assistant reply. The bytes stay on the
/// service until the user clicks 下载; nothing is cached or written implicitly.
struct RemoteFileView: View {
    let request: RemoteFileRequest
    let store: AppStore
    @State private var downloading = false
    @State private var failure: String?
    @State private var savedURL: URL?
    @State private var savedBytes = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.filename)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(request.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if downloading {
                    ProgressView().controlSize(.small)
                }
                Button(downloading ? "下载中…" : "下载") { download() }
                    .controlSize(.small)
                    .disabled(downloading)
                    .help("从服务读取到本机")
                    .accessibilityLabel("下载文件：\(request.filename)")
            }
            .padding(12)

            if let failure {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text(failure)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button("重试") { download() }
                        .controlSize(.small)
                        .disabled(downloading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else if let savedURL {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("已保存 \(ByteCountFormatter.string(fromByteCount: Int64(savedBytes), countStyle: .file))：\(savedURL.lastPathComponent)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.18)))
        .contextMenu {
            Button("下载…") { download() }
                .disabled(downloading)
            Button("复制远程路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(request.path, forType: .string)
            }
        }
    }

    private var icon: NSImage {
        let ext = (request.path as NSString).pathExtension
        return NSWorkspace.shared.icon(forFileType: ext.isEmpty ? "public.data" : ext)
    }

    private func download() {
        guard !downloading else { return }
        downloading = true
        failure = nil
        Task {
            do {
                let data = try await store.file(for: request)
                try Task.checkCancellation()
                downloading = false
                save(data)
            } catch is CancellationError {
                downloading = false
            } catch {
                downloading = false
                failure = error.localizedDescription
            }
        }
    }

    /// Saving only encodes a destination the user picked; the panel is modal so a
    /// closed conversation cannot leave a half-written file behind.
    private func save(_ data: Data) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = RemoteFileDecoder.suggestedName(for: request.path)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = "保存 \(request.filename)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            savedURL = url
            savedBytes = data.count
        } catch {
            failure = "无法写入文件：\(error.localizedDescription)"
        }
    }
}
