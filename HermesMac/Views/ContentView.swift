import SwiftUI
struct ContentView: View {
    var store: AppStore
    var body: some View {
        HStack(spacing: 0) {
            ProfileRail(store: store).frame(width: 68)
            Divider()
            HSplitView {
                SessionListView(store: store).frame(minWidth: 210, idealWidth: 260, maxWidth: 400)
                ChatView(store: store).frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
struct ProfileRail: View {
    var store: AppStore
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles").font(.title2).foregroundStyle(.tint).padding(.top, 18).accessibilityLabel("Hermes")
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(store.profiles) { profile in
                        Button { Task { await store.selectProfile(profile.name) } } label: {
                            ZStack(alignment: .bottomTrailing) {
                                Text(String(profile.displayName.prefix(1)).uppercased()).font(.system(size: 20, weight: .medium))
                                    .frame(width: 44, height: 44)
                                    .background(store.selectedProfile == profile.name ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                                    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(store.selectedProfile == profile.name ? Color.accentColor : Color.clear, lineWidth: 2) }
                                if store.profileApproval(profile.name) {
                                    Image(systemName: "exclamationmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .orange).background(.background, in: Circle())
                                } else if store.profileBusy(profile.name) {
                                    ProgressView().controlSize(.mini).padding(2).background(.background, in: Circle())
                                } else if store.profileUnread(profile.name) { Circle().fill(.tint).frame(width: 10, height: 10).overlay { Circle().stroke(.background, lineWidth: 2) } }
                            }
                        }
                        .buttonStyle(.plain).help(profile.displayName + (profile.description.isEmpty ? "" : " · " + profile.description))
                        .accessibilityLabel(profile.displayName).accessibilityValue(store.profileApproval(profile.name) ? "待审批" : store.profileBusy(profile.name) ? "生成中" : store.profileUnread(profile.name) ? "未读完成" : "")
                        .contextMenu {
                            Button("向上移动") { store.moveProfile(profile.name, by: -1) }
                            Button("向下移动") { store.moveProfile(profile.name, by: 1) }
                        }
                    }
                }.padding(.vertical, 8)
            }
            Spacer(minLength: 0)
            SettingsLink { Image(systemName: "gearshape").font(.title3).frame(width: 44, height: 36) }.buttonStyle(.plain).help("连接设置")
        }.padding(.bottom, 12).background(.bar)
    }
}
