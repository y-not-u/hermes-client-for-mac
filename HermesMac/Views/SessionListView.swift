import SwiftUI
struct SessionListView: View {
    @Bindable var store: AppStore
    @State private var renaming: SessionSummary?
    @State private var title = ""
    @State private var renameProfile = ""
    @State private var renameService = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("会话").font(.headline)
                Spacer()
                Button { Task { await store.loadSessions(profile: store.selectedProfile, query: store.search) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("刷新会话")
                Button { store.newSession() } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.borderless).help("新会话 · ⌘N")
            }.padding(16)
            TextField("搜索会话", text: $store.search).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 12)
                .onChange(of: store.search) { _, _ in store.searchChanged() }
            List(selection: Binding(get: { store.selectedSession }, set: { value in if let value { Task { await store.openSession(value) } } })) {
                ForEach(store.sessions[store.selectedProfile] ?? []) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title).lineLimit(1)
                        if !session.preview.isEmpty { Text(session.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }.padding(.vertical, 3).tag(session.id)
                        .contextMenu { Button("重命名…") { renaming = session; title = session.title; renameProfile = store.selectedProfile; renameService = store.service } }
                }
                if store.listHasMore[store.selectedProfile] == true {
                    Button("加载更多") { Task { await store.loadSessions(profile: store.selectedProfile, more: true) } }.disabled(store.listLoading)
                }
            }.listStyle(.sidebar)
            if store.listLoading { ProgressView().controlSize(.small).padding(8) }
            HStack { Text(store.profileTitle).font(.caption).foregroundStyle(.secondary); Spacer(); Text("\((store.sessions[store.selectedProfile] ?? []).count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary) }.padding(12)
        }
        .alert("重命名会话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("标题", text: $title)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") { if let row = renaming, renameService == store.service { let name = title; let owner = renameProfile; let service = renameService; Task { await store.rename(row, to: name, profile: owner, service: service) } }; renaming = nil }
        }
    }
}
