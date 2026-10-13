import SwiftUI
import AppKit

struct ContentView: View {
    var store: AppStore

    var body: some View {
        HStack(spacing: 0) {
            ProfileRail(store: store)
                .frame(width: 68)

            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.5))
                .frame(width: 1)

            HSplitView {
                SessionListView(store: store)
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 380)

                ChatView(store: store)
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(WindowAccessor { window in
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
        })
    }
}

struct ProfileRail: View {
    var store: AppStore

    var body: some View {
        VStack(spacing: 12) {
            // Spacing for macOS window control traffic lights
            Color.clear
                .frame(height: 38)

            // Profiles list
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    ForEach(store.profiles) { profile in
                        ProfileRailItem(
                            profile: profile,
                            isSelected: store.selectedProfile == profile.name,
                            hasApproval: store.profileApproval(profile.name),
                            isBusy: store.profileBusy(profile.name),
                            hasUnread: store.profileUnread(profile.name),
                            onSelect: {
                                Task { await store.selectProfile(profile.name) }
                            },
                            onMove: { delta in
                                store.moveProfile(profile.name, by: delta)
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }

            Spacer(minLength: 0)

            // Bottom Settings Link
            ProfileRailSettingsButton()
        }
        .padding(.bottom, 12)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }
}

private struct ProfileRailItem: View {
    let profile: Profile
    let isSelected: Bool
    let hasApproval: Bool
    let isBusy: Bool
    let hasUnread: Bool
    let onSelect: () -> Void
    let onMove: (Int) -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .leading) {
                // Leading selection indicator bar
                HStack(spacing: 0) {
                    if isSelected {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: 3.5, height: 24)
                    } else if isHovered {
                        Capsule()
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: 3.5, height: 12)
                    }
                    Spacer()
                }

                // Avatar and status badges
                HStack {
                    Spacer()
                    ZStack(alignment: .bottomTrailing) {
                        ProfileAvatar(
                            name: profile.name,
                            displayName: profile.displayName,
                            size: 40,
                            cornerRadius: isSelected ? 12 : (isHovered ? 13 : 14),
                            isSelected: isSelected
                        )
                        .scaleEffect(isHovered && !isSelected ? 1.05 : 1.0)
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)

                        // Status badges
                        if hasApproval {
                            ZStack {
                                Circle()
                                    .fill(.orange)
                                    .frame(width: 14, height: 14)
                                Image(systemName: "exclamationmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                            .offset(x: 2, y: 2)
                        } else if isBusy {
                            ZStack {
                                Circle()
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .frame(width: 14, height: 14)
                                ProgressView()
                                    .controlSize(.mini)
                            }
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                            .offset(x: 2, y: 2)
                        } else if hasUnread {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                                .offset(x: 1, y: 1)
                        }
                    }
                    Spacer()
                }
            }
            .frame(width: 68, height: 44)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(profile.displayName + (profile.description.isEmpty ? "" : " · " + profile.description))
        .accessibilityLabel(profile.displayName)
        .accessibilityValue(hasApproval ? "待审批" : isBusy ? "生成中" : hasUnread ? "未读完成" : "")
        .contextMenu {
            Button("向上移动") { onMove(-1) }
            Button("向下移动") { onMove(1) }
        }
    }
}

private struct ProfileRailSettingsButton: View {
    @State private var isHovered = false

    var body: some View {
        SettingsLink {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered ? Color.secondary.opacity(0.12) : Color.clear)

                Image(systemName: "gearshape")
                    .font(.system(size: 16))
                    .foregroundStyle(isHovered ? .primary : .secondary)
            }
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("连接设置")
    }
}

struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            configure(window)
        }
    }
}
