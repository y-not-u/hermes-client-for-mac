import SwiftUI

struct ModelPickerView: View {
    @Bindable var store: AppStore
    @State private var isHovered = false

    private var isInteractive: Bool {
        store.connected && store.canSwitchModel
    }

    private var title: String {
        if store.modelSwitching.contains(store.selectedProfile) { return "切换中…" }
        if let model = store.modelCatalog?.model, !model.isEmpty { return model }
        return store.modelLoading.contains(store.modelContext) ? "加载模型…" : "选择模型"
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Menu {
                if let catalog = store.modelCatalog {
                    ForEach(catalog.providers) { provider in
                        Menu(provider.name) {
                            ForEach(provider.choices) { choice in
                                Button {
                                    Task { await store.switchModel(choice) }
                                } label: {
                                    if choice.model == catalog.model && choice.provider == catalog.provider {
                                        Label(choice.model, systemImage: "checkmark")
                                    } else { Text(choice.model) }
                                }
                                .disabled(!store.canSwitchModel || provider.unavailable.contains(choice.model))
                            }
                        }
                    }
                    if catalog.providers.isEmpty { Text("暂无可用模型，请先在 Hermes 配置提供商") }
                }
                if store.modelLoading.contains(store.modelContext) { Text("正在加载模型…") }
                if let error = store.modelErrors[store.modelContext] { Text(error) }
                Divider()
                Button("刷新模型列表") { Task { await store.loadModels(refresh: true) } }
                    .disabled(!store.connected || store.modelLoading.contains(store.modelContext))
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: store.modelErrors[store.modelContext] == nil ? "cpu" : "exclamationmark.triangle")
                    Text(title).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 11))
                .foregroundStyle(isHovered && isInteractive ? Color.primary : Color.secondary)
                .frame(maxWidth: 170)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                (isHovered && isInteractive) ? Color.accentColor.opacity(0.12) : Color.clear,
                in: Capsule()
            )
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .disabled(!store.connected || !store.canSwitchModel)
            .help(store.modelErrors[store.modelContext] ?? (store.canSwitchModel ? "切换当前会话的模型" : "任务完成后可切换模型"))
            .accessibilityLabel("模型：\(title)")
        }
        .task(id: "\(store.connected)-\(store.modelContext)-\(store.current?.runtimeID ?? "")-\(store.current?.generating == true)") {
            await store.loadModels()
        }
        .alert("确认切换模型", isPresented: Binding(
            get: { store.modelConfirmation != nil },
            set: { if !$0 { store.modelConfirmation = nil } }
        ), presenting: store.modelConfirmation) { confirmation in
            Button("切换") { Task { await store.switchModel(confirmation.choice, confirmation: confirmation) } }
            Button("取消", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }
}
