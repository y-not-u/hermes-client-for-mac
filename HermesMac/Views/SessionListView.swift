import SwiftUI
import AppKit

struct SessionListView: View {
    @Bindable var store: AppStore
    @State private var renaming: SessionSummary?
    @State private var title = ""
    @State private var renameProfile = ""
    @State private var renameService = ""
    @FocusState private var isSearchFocused: Bool

    private var currentSessions: [SessionSummary] {
        store.sessions[store.selectedProfile] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 6) {
                    Text("会话")
                        .font(.system(size: 15, weight: .bold))

                    if !currentSessions.isEmpty {
                        Text("\(currentSessions.count)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.secondary.opacity(0.1), in: Capsule())
                    }
                }

                Spacer()

                Button {
                    Task { await store.loadSessions(profile: store.selectedProfile, query: store.search) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(store.listLoading ? 360 : 0))
                        .animation(store.listLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: store.listLoading)
                }
                .buttonStyle(.plain)
                .frame(width: 26, height: 26)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help("刷新会话")

                Button {
                    store.newSession()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 26, height: 26)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help("新会话 · ⌘N")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Modern Search Bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

                TextField("搜索会话…", text: $store.search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isSearchFocused)
                    .onChange(of: store.search) { _, _ in store.searchChanged() }

                if !store.search.isEmpty {
                    Button {
                        store.search = ""
                        store.searchChanged()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5.5)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSearchFocused ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // Sessions List in Clean ScrollView
            if currentSessions.isEmpty && !store.listLoading {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: store.search.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)

                    Text(store.search.isEmpty ? "暂无会话" : "未找到匹配会话")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    if store.search.isEmpty {
                        Button("新建会话") {
                            store.newSession()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Button("清除搜索") {
                            store.search = ""
                            store.searchChanged()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(currentSessions) { session in
                                SessionCardItem(
                                    session: session,
                                    isSelected: store.selectedSession == session.id,
                                    onSelect: {
                                        Task { await store.openSession(session.id) }
                                    },
                                    onRename: {
                                        renaming = session
                                        title = session.title
                                        renameProfile = store.selectedProfile
                                        renameService = store.service
                                    }
                                )
                                .id(session.id)
                            }

                            if store.listHasMore[store.selectedProfile] == true {
                                HStack {
                                    Spacer()
                                    Button("加载更多") {
                                        Task { await store.loadSessions(profile: store.selectedProfile, more: true) }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(store.listLoading)
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .cleanScrollBars()
                }
            }

            if store.listLoading && !currentSessions.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("加载中…").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.35))
        .alert("重命名会话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("标题", text: $title)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let row = renaming, renameService == store.service {
                    let name = title
                    let owner = renameProfile
                    let service = renameService
                    Task { await store.rename(row, to: name, profile: owner, service: service) }
                }
                renaming = nil
            }
        }
    }
}

// MARK: - Modern Session Card Item

private struct SessionCardItem: View {
    let session: SessionSummary
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: () -> Void

    @State private var isHovered = false

    private var parsed: (title: String, date: String?) {
        parseTitleAndDate(session.title)
    }

    private var displayPreview: String {
        cleanPreviewText(session.preview)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 7) {
                // Leading accent indicator bar
                if isSelected {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3, height: 16)
                } else {
                    Spacer().frame(width: 3)
                }

                VStack(alignment: .leading, spacing: 3) {
                    // Title row + optional extracted time badge
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(parsed.title)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.88))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 4)

                        if let date = parsed.date {
                            Text(date)
                                .font(.system(size: 10, weight: .regular))
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.8))
                                .lineLimit(1)
                        }
                    }

                    // Preview row
                    if !displayPreview.isEmpty {
                        Text(displayPreview)
                            .font(.system(size: 11))
                            .foregroundStyle(isSelected ? Color.secondary : Color.secondary.opacity(0.75))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .padding(.vertical, 7)
            .padding(.trailing, 8)
            .padding(.leading, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.12)
                    : (isHovered ? Color.secondary.opacity(0.06) : Color.clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("重命名…") { onRename() }
            Button("复制标题") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.title, forType: .string)
            }
            Button("复制会话 ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.id, forType: .string)
            }
        }
    }

    private func parseTitleAndDate(_ title: String) -> (title: String, date: String?) {
        let parts = title.components(separatedBy: " · ")
        if parts.count >= 2, let last = parts.last {
            let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            let hasMonth = months.contains { last.contains($0) }
            let hasTimeColon = last.contains(":") && last.range(of: #"\d+:\d+"#, options: .regularExpression) != nil
            let hasDateSlashOrDash = last.range(of: #"\d{1,4}[-/]\d{1,2}"#, options: .regularExpression) != nil
            let hasRelative = last.contains("今天") || last.contains("昨天") || last.contains("前天")

            if hasMonth || hasTimeColon || hasDateSlashOrDash || hasRelative {
                let mainTitle = parts.dropLast().joined(separator: " · ")
                return (mainTitle.isEmpty ? title : mainTitle, last)
            }
        }
        return (title, nil)
    }

    private func cleanPreviewText(_ preview: String) -> String {
        let text = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[IMPORTANT:") {
            if let closingIndex = text.firstIndex(of: "]") {
                let after = text[text.index(after: closingIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !after.isEmpty {
                    return after
                }
            }
            return "定时任务 · 计划自动执行"
        }
        return text
    }
}
