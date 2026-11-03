import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("应用更新", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(updater.configuration.displayVersion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("自动检查更新", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.setAutomaticallyChecksForUpdates($0) }))
                .disabled(!updater.isAvailable)
            HStack(alignment: .top, spacing: 12) {
                Text(updater.isAvailable
                     ? "从 GitHub Releases 检查新版本，安装前会征求你的确认。"
                     : "开发构建不检查更新，请使用正式发布版。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("检查更新…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}
