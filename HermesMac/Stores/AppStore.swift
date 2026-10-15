import Foundation
import Observation
import AppKit

@MainActor @Observable final class AppStore {
    let botScreen = BotScreenStore()
    let local: LocalState
    var address: String
    var profiles: [Profile] = []
    var selectedProfile = ""
    var selectedSession: String?
    var sessions: [String: [SessionSummary]] = [:]
    var conversations: [ConversationKey: Conversation] = [:]
    var connection = "未连接"
    var connected = false
    var connecting = false
    var error: String?
    var search = ""
    var listLoading = false
    var listHasMore: [String: Bool] = [:]
    var draft = "" { didSet { persistDraft() } }
    let models = ModelCatalogStore()
    var modelCatalogs: [ModelPickerContext: ModelCatalog] { models.catalogs }
    var modelErrors: [ModelPickerContext: String] { models.errors }
    var modelLoading: Set<ModelPickerContext> { models.loading }
    var modelSwitching: Set<String> = []
    var modelConfirmation: ModelSwitchConfirmation?
    private var client: HermesClient?
    @ObservationIgnored private let imageCache = RemoteImageCache()
    @ObservationIgnored private let makeClient: (String) throws -> HermesClient
    @ObservationIgnored private let isAppActive: @MainActor () -> Bool
    @ObservationIgnored private let onReplyCompleted: @MainActor (ConversationKey, String, String) -> Void
    private var generation = UUID()
    private var navigation = UUID()
    private var connectionAttempt = UUID()
    private var routes: [String: ConversationKey] = [:]
    private var earlyFrames: [String: [JSON]] = [:]
    private var buffered: [JSON] = []
    private var flushTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var listRevision: [String: UUID] = [:]
    private var sendingSessions: Set<ConversationKey> = []
    // A draft has no stored ID until creation returns. Navigation identifies each
    // new-session composer so a later composer can create independently.
    private var creatingSessions: [UUID: String] = [:]
    private var sessionMutations: Set<ConversationKey> = []
    @ObservationIgnored private var conversationAccessOrder: [ConversationKey] = []
    private let maxCachedConversations = 20
    private let historyPageSize = 20

    private func touchConversation(_ key: ConversationKey) {
        conversationAccessOrder.removeAll { $0 == key }
        conversationAccessOrder.append(key)
    }

    // A soft limit: local state that still needs attention must survive eviction.
    func pruneConversationCache() {
        conversationAccessOrder.removeAll { conversations[$0] == nil }
        for key in conversations.keys where !conversationAccessOrder.contains(key) {
            conversationAccessOrder.insert(key, at: 0)
        }
        for key in conversationAccessOrder {
            guard conversations.count > maxCachedConversations else { break }
            guard let c = conversations[key], key != currentKey,
                  !c.generating, !c.uncertain, !c.loading, !c.queryingStatus, !c.unread,
                  c.recoverableMessageID == nil, c.approvals.isEmpty, c.submittingApprovals.isEmpty,
                  !sendingSessions.contains(key), !modelSwitching.contains(key.profile),
                  !sessionMutations.contains(key), modelConfirmation?.key != key,
                  !modelLoading.contains(ModelPickerContext(service: key.service, profile: key.profile, sessionID: key.storedID)) else { continue }
            conversations.removeValue(forKey: key)
            let runtimeIDs = routes.filter { $0.value == key }.map(\.key)
            for id in runtimeIDs { routes.removeValue(forKey: id); earlyFrames.removeValue(forKey: id) }
            let context = ModelPickerContext(service: key.service, profile: key.profile, sessionID: key.storedID)
            models.remove(context)
        }
        conversationAccessOrder.removeAll { conversations[$0] == nil }
    }
    init(local: LocalState? = nil, makeClient: ((String) throws -> HermesClient)? = nil,
         isAppActive: @escaping @MainActor () -> Bool = { NSApp?.isActive ?? true },
         onReplyCompleted: @escaping @MainActor (ConversationKey, String, String) -> Void = { _, _, _ in }) {
        let state = local ?? LocalState()
        self.local = state; address = state.address
        self.makeClient = makeClient ?? { try HermesClient(address: $0) }
        self.isAppActive = isAppActive
        self.onReplyCompleted = onReplyCompleted
    }
    var service: String { client?.service ?? address }
    var currentKey: ConversationKey? { selectedSession.map { ConversationKey(service: service, profile: selectedProfile, storedID: $0) } }
    var current: Conversation? { currentKey.flatMap { conversations[$0] } }
    func image(for request: RemoteImageRequest) async throws -> RemoteImageFile {
        guard let client, client.service == request.conversation.service else {
            throw ClientError(message: "请先连接图片所属的 Hermes 服务")
        }
        return try await imageCache.image(for: request) { try await client.imageData(for: request) }
    }
    var profileTitle: String { profiles.first(where: { $0.name == selectedProfile })?.displayName ?? "Hermes" }
    var canSend: Bool {
        connected && !selectedProfile.isEmpty && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !(currentKey.map { sendingSessions.contains($0) } ?? (creatingSessions[navigation] != nil))
        && !modelSwitching.contains(selectedProfile) && current?.readOnlyReason == nil && current?.loading != true
        && (selectedSession == nil || current != nil)
        && (currentKey.map { !sessionMutations.contains($0) } ?? true)
        && current?.uncertain != true
    }
    var modelContext: ModelPickerContext {
        ModelPickerContext(service: service, profile: selectedProfile, sessionID: selectedSession)
    }
    var modelCatalog: ModelCatalog? { modelCatalogs[modelContext] }
    var canSwitchModel: Bool {
        connected && !selectedProfile.isEmpty && !profileBusy(selectedProfile)
        && !modelSwitching.contains(selectedProfile) && current?.loading != true
        && current?.readOnlyReason == nil && (selectedSession == nil || current?.runtimeID != nil)
        && (currentKey.map { !sessionMutations.contains($0) } ?? true)
    }
    func loadModels(refresh: Bool = false) async {
        guard connected, !selectedProfile.isEmpty, let client else { return }
        let epoch = generation
        await models.load(modelContext, runtimeID: current?.runtimeID, refresh: refresh, using: client)
        if epoch == generation { pruneConversationCache() }
    }
    func switchModel(_ choice: ModelChoice, confirmation: ModelSwitchConfirmation? = nil) async {
        guard canSwitchModel, let client else { return }
        if let confirmation {
            guard confirmation.key == currentKey, confirmation.key.service == service else { return }
        } else {
            guard modelCatalog?.providers.contains(where: {
                $0.choices.contains(choice) && !$0.unavailable.contains(choice.model)
            }) == true else { return }
        }
        let profile = selectedProfile; let epoch = generation; let origin = navigation
        let startingContext = modelContext
        modelSwitching.insert(profile)
        defer { if epoch == generation { modelSwitching.remove(profile); pruneConversationCache() } }
        do {
            let c: Conversation
            if let current { c = current }
            else {
                let snapshot = try await client.execute(.createSession(profile: profile))
                guard epoch == generation else { return }
                let id = snapshot["stored_session_id"].string
                guard !id.isEmpty else { throw ClientError(message: "服务未返回持久会话 ID，请升级 Hermes") }
                let key = ConversationKey(service: service, profile: profile, storedID: id)
                c = Conversation(key: key); c.snapshot(snapshot); conversations[key] = c; touchConversation(key); bind(c)
                sessions[profile, default: []].insert(SessionSummary(id: id, title: "新会话"), at: 0)
                // Keep the user's draft while moving it into the newly created session.
                if navigation == origin {
                    local.update(service) {
                        $0.lastSession[profile] = id
                        $0.drafts[LocalState.draftKey(profile: profile, session: id)] = draft
                        $0.drafts.removeValue(forKey: LocalState.draftKey(profile: profile, session: nil))
                    }
                    selectedSession = id
                    models.copyCatalog(from: startingContext, to: modelContext)
                }
            }
            guard epoch == generation, navigation == origin, currentKey == c.key else { return }
            guard let runtime = c.runtimeID, !runtime.isEmpty else { throw ClientError(message: "会话未恢复，请重连后再切换模型") }
            let result = try await client.execute(.setModel(profile: profile, runtimeID: runtime,
                                                           choice: choice, confirmed: confirmation != nil))
            guard epoch == generation else { return }
            if result["confirm_required"].bool {
                if currentKey == c.key {
                    modelConfirmation = ModelSwitchConfirmation(key: c.key, choice: choice,
                        message: result["confirm_message"].string.isEmpty ? result["warning"].string : result["confirm_message"].string)
                }
                return
            }
            guard result["key"].string == "model", !result["value"].string.isEmpty else {
                throw ClientError(message: "服务未确认模型切换，请刷新模型列表检查当前状态")
            }
            let context = ModelPickerContext(service: c.key.service, profile: profile, sessionID: c.key.storedID)
            // Invalidate reads started before the mutation's response.
            models.didSwitch(context, model: result["value"].string, provider: choice.provider)
            if currentKey == c.key { await loadModels() }
        } catch {
            guard epoch == generation else { return }
            models.setError(error.localizedDescription, for: ModelPickerContext(service: startingContext.service, profile: profile,
                sessionID: selectedProfile == profile && navigation == origin ? selectedSession : startingContext.sessionID))
        }
    }
    func profileBusy(_ profile: String) -> Bool {
        creatingSessions.values.contains(profile) || sendingSessions.contains { $0.profile == profile }
        || conversations.values.contains { $0.key.profile == profile && ($0.generating || $0.uncertain) }
    }
    func profileApproval(_ profile: String) -> Bool { conversations.values.contains { $0.key.profile == profile && !$0.approvals.isEmpty } }
    func profileUnread(_ profile: String) -> Bool { conversations.values.contains { $0.key.profile == profile && $0.unread } }
    private func persistDraft() {
        guard !selectedProfile.isEmpty else { return }
        let key = LocalState.draftKey(profile: selectedProfile, session: selectedSession)
        local.setDraft(draft, for: key, service: service)
    }
    func connect(address newAddress: String? = nil, token: String? = nil) async {
        reconnectTask?.cancel(); reconnectTask = nil
        let attempt = UUID(); connectionAttempt = attempt; var activated = false
        do {
            let next = try makeClient(newAddress ?? address)
            if let token { try await next.setSessionToken(token) }
            guard connectionAttempt == attempt else { return }
            let changed = next.service != service
            if changed {
                await botScreen.close()
                guard connectionAttempt == attempt else { return }
            }
            generation = attempt; activated = true
            let epoch = attempt
            botScreen.disconnected()
            client?.disconnect(); client = next; connected = false; connecting = true; connection = "连接中…"; error = nil
            models.reset(); modelSwitching = []; modelConfirmation = nil
            sendingSessions = []; creatingSessions = [:]; routes = [:]; earlyFrames = [:]; buffered = []; flushTask?.cancel(); flushTask = nil
            if changed { conversationAccessOrder = []; conversations = [:]; sessions = [:]; profiles = []; sendingSessions = []; creatingSessions = [:]; selectedProfile = ""; selectedSession = nil; draft = ""; search = "" }
            address = next.service; local.address = address
            installCallbacks(next, epoch: epoch)
            try await next.connect(); guard epoch == generation else { return }
            try await restoreConnection(next, epoch: epoch)
        } catch {
            guard connectionAttempt == attempt else { return }
            if !activated { self.error = error.localizedDescription; return }
            guard attempt == generation else { return }
            connecting = false; connected = false; connection = "连接失败"; self.error = error.localizedDescription
            if HermesClient.isTransientConnectionError(error), let client {
                scheduleReconnect(client, epoch: attempt)
            }
        }
    }
    private func restoreConnection(_ client: HermesClient, epoch: UUID) async throws {
        routes = [:]; earlyFrames = [:]
        try await loadProfiles(client, epoch: epoch)
        guard epoch == generation, !Task.isCancelled else { return }
        connected = true; connecting = false; connection = "已连接"; error = nil
        for conversation in Array(conversations.values) where profiles.contains(where: { $0.name == conversation.key.profile }) {
            guard epoch == generation, !Task.isCancelled else { return }
            guard conversations[conversation.key] === conversation else { continue }
            await resume(conversation, client: client, epoch: epoch)
        }
        let saved = local.state(service)
        let profile = profiles.contains(where: { $0.name == selectedProfile }) ? selectedProfile : (profiles.contains(where: { $0.name == saved.selectedProfile }) ? saved.selectedProfile : profiles.first?.name ?? "")
        await selectProfile(profile)
    }
    private func scheduleReconnect(_ client: HermesClient, epoch: UUID) {
        guard reconnectTask == nil else { return }
        connecting = true; connection = "等待自动重连…"
        reconnectTask = Task { [weak self] in
            let delays = [2, 4, 8, 16, 30]
            var attempt = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(delays[min(attempt, delays.count - 1)])) }
                catch { return }
                guard let self, epoch == self.generation, !Task.isCancelled else { return }
                self.connection = "正在自动重连…"
                do {
                    try await client.connect()
                    guard epoch == self.generation, !Task.isCancelled else { return }
                    try await self.restoreConnection(client, epoch: epoch)
                    guard epoch == self.generation, !Task.isCancelled else { return }
                    self.reconnectTask = nil
                    return
                } catch {
                    guard epoch == self.generation, !Task.isCancelled else { return }
                    self.connected = false; self.error = error.localizedDescription
                    if !HermesClient.isTransientConnectionError(error) {
                        self.connecting = false; self.connection = "连接失败"; self.reconnectTask = nil
                        return
                    }
                    self.connection = "等待自动重连…"
                    attempt += 1
                }
            }
        }
    }
    private func loadProfiles(_ client: HermesClient, epoch: UUID) async throws {
        let json = try await client.rest("/api/profiles"); guard epoch == generation else { return }
        let values = json["profiles"].array.map(Profile.init).filter { !$0.name.isEmpty }
        let order = local.state(service).profileOrder
        profiles = values.sorted { (order.firstIndex(of: $0.name) ?? Int.max, $0.name) < (order.firstIndex(of: $1.name) ?? Int.max, $1.name) }
        local.update(service) { $0.profileOrder = profiles.map(\.name) }
        let names = Set(profiles.map(\.name))
        for c in conversations.values where !names.contains(c.key.profile) { c.generating = false; c.uncertain = false; c.readOnlyReason = "此 profile 已被删除"; c.approvals = [] }
    }
    private func installCallbacks(_ client: HermesClient, epoch: UUID) {
        client.onFrame = { [weak self] frame in
            guard let self, self.generation == epoch else { return }
            if self.botScreen.receive(frame) { return }
            self.buffered.append(frame)
            if self.flushTask == nil {
                self.flushTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(40)); guard let self, !Task.isCancelled else { return }
                    let frames = self.buffered; self.buffered = []; self.flushTask = nil
                    for frame in frames { self.route(frame) }
                    self.pruneConversationCache()
                }
            }
        }
        client.onDisconnect = { [weak self, weak client] error in
            guard let self, let client, self.generation == epoch else { return }
            // Flush received frames before declaring the stream uncertain.
            self.flushTask?.cancel(); self.flushTask = nil
            let frames = self.buffered; self.buffered = []; frames.forEach { self.route($0) }
            self.botScreen.disconnected()
            self.connected = false; self.connection = "已断开 · 等待重连"; self.error = error.localizedDescription
            for c in self.conversations.values { if c.generating { c.uncertain = true }; c.runtimeID = nil }
            self.scheduleReconnect(client, epoch: epoch)
        }
    }
    func selectProfile(_ profile: String) async {
        guard profiles.contains(where: { $0.name == profile }) else { return }
        modelConfirmation = nil
        navigation = UUID(); selectedProfile = profile; selectedSession = local.state(service).lastSession[profile]; search = ""
        draft = local.state(service).drafts[LocalState.draftKey(profile: profile, session: selectedSession)] ?? ""
        local.update(service) { $0.selectedProfile = profile }
        if let pending = conversations.values.first(where: { $0.key.profile == profile && !$0.approvals.isEmpty }) { selectedSession = pending.key.storedID; restoreDraft() }
        await botScreen.configure(client: client, profile: profile, connected: connected)
        await loadSessions(profile: profile)
        if let selectedSession { await openSession(selectedSession, profile: profile) }
    }
    func cycleProfile(_ direction: Int) {
        guard !profiles.isEmpty else { return }
        let index = profiles.firstIndex(where: { $0.name == selectedProfile }) ?? 0
        let target = profiles[(index + direction + profiles.count) % profiles.count].name
        Task { await selectProfile(target) }
    }
    func moveProfile(_ name: String, by delta: Int) {
        guard let i = profiles.firstIndex(where: { $0.name == name }), profiles.indices.contains(i + delta) else { return }
        profiles.swapAt(i, i + delta); local.update(service) { $0.profileOrder = profiles.map(\.name) }
    }
    private func restoreDraft() { draft = local.state(service).drafts[LocalState.draftKey(profile: selectedProfile, session: selectedSession)] ?? "" }
    func newSession() { defer { pruneConversationCache() }; modelConfirmation = nil; navigation = UUID(); selectedSession = nil; local.update(service) { $0.lastSession.removeValue(forKey: selectedProfile) }; restoreDraft() }
    func searchChanged() {
        searchTask?.cancel(); let profile = selectedProfile; let query = search
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300)); guard let self, !Task.isCancelled else { return }
            await self.loadSessions(profile: profile, query: query)
        }
    }
    func loadSessions(profile: String, query: String = "", more: Bool = false) async {
        guard let client, connected, !profile.isEmpty else { return }
        let epoch = generation; let revision = UUID(); listRevision[profile] = revision; listLoading = true
        defer { if listRevision[profile] == revision { listLoading = false } }
        let offset = more ? (sessions[profile]?.count ?? 0) : 0
        do {
            let path = query.isEmpty ? "/api/sessions" : "/api/sessions/search"
            // Filter at the source so cron runs do not consume list/search page slots.
            let result = try await client.rest(path, query: [URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "limit", value: "40"), URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "q", value: query), URLQueryItem(name: "exclude_sources", value: "cron")])
            guard epoch == generation, listRevision[profile] == revision else { return }
            let rawRows = result[query.isEmpty ? "sessions" : "results"].array
            let rows = rawRows.filter { !$0["archived"].bool }.map(SessionSummary.init)
            if more { sessions[profile, default: []].append(contentsOf: rows.filter { row in !(sessions[profile] ?? []).contains(where: { $0.id == row.id }) }) }
            else {
                let open = (sessions[profile] ?? []).filter { row in conversations.values.contains { $0.key.profile == profile && $0.key.storedID == row.id && ($0.generating || $0.messages.isEmpty) } && !rows.contains(where: { $0.id == row.id }) }
                sessions[profile] = query.isEmpty ? open + rows : rows
            }
            listHasMore[profile] = rawRows.count == 40 && query.isEmpty
        } catch { guard epoch == generation else { return }; self.error = error.localizedDescription }
    }
    func openSession(_ id: String, profile: String? = nil) async {
        let owner = profile ?? selectedProfile
        guard owner == selectedProfile, let client else { return }
        guard !sessionMutations.contains(ConversationKey(service: service, profile: owner, storedID: id)) else { return }
        navigation = UUID(); selectedSession = id; restoreDraft(); local.update(service) { $0.lastSession[owner] = id }
        let key = ConversationKey(service: service, profile: owner, storedID: id)
        touchConversation(key)
        defer { pruneConversationCache() }
        if let c = conversations[key] { c.unread = false; if c.runtimeID != nil || c.loading { return } }
        let c = conversations[key] ?? Conversation(key: key); conversations[key] = c
        await resume(c, client: client, epoch: generation)
    }
    private func resume(_ c: Conversation, client: HermesClient, epoch: UUID) async {
        guard !(c.loading && c.loadingEpoch == epoch), c.readOnlyReason != "此 profile 已被删除" else { return }
        c.loading = true; c.loadingEpoch = epoch
        defer { if c.loadingEpoch == epoch { c.loading = false; c.loadingEpoch = nil; pruneConversationCache() } }
        // Fetch a bounded display page over HTTP, never the full model/tool history
        // over WebSocket. Read it before resume so the newer inflight snapshot wins.
        var history: [Message]?
        var historyError: String?
        c.historyReadAfter = client.receivedOrdinal
        do {
            let result = try await historyPage(c, client: client)
            guard epoch == generation else { return }
            var rows = result["messages"].array
            // Tool records consume history page slots. When a send is uncertain,
            // look beyond the latest page before concluding its user text is absent.
            if c.uncertain, let sent = c.messages.last(where: { $0.role == "user" }) {
                var pageCount = rows.count
                while pageCount == historyPageSize, rows.count < historyPageSize * 10,
                      !Message.visibleHistory(rows).contains(where: { $0.role == "user" && $0.text == sent.text }) {
                    let older = try await historyPage(c, client: client, offset: rows.count)["messages"].array
                    guard epoch == generation else { return }
                    pageCount = older.count
                    rows.insert(contentsOf: older, at: 0)
                }
            }
            history = Message.visibleHistory(rows)
            c.historyOffset = rows.count
            c.hasOlder = rows.count >= historyPageSize && rows.count % historyPageSize == 0
            c.historyBacklog = []
        } catch {
            guard epoch == generation else { return }
            historyError = "历史消息加载失败：\(error.localizedDescription)"
        }
        do {
            let snapshot = try await client.execute(.resumeSession(profile: c.key.profile, sessionID: c.key.storedID))
            guard epoch == generation else { return }
            c.snapshot(snapshot, history: history)
            if let historyError, c.error == nil { c.error = historyError }
            bind(c)
            for request in snapshot["open_requests"].array where request["method"].string != "approval" {
                try? await client.respond(id: request["id"].string)
            }
        } catch {
            guard epoch == generation else { return }
            c.runtimeID = nil; c.generating = false; c.uncertain = false; c.approvals = []
            c.readOnlyReason = "历史暂无法恢复，当前为只读：\(error.localizedDescription)"
            if c.messages.isEmpty, let history { c.messages = history }
            if let historyError { c.error = historyError }
        }
    }
    private func historyPage(_ c: Conversation, client: HermesClient, offset: Int = 0) async throws -> JSON {
        try await client.rest("/api/sessions/\(c.key.storedID)/messages", query: [
            URLQueryItem(name: "profile", value: c.key.profile),
            URLQueryItem(name: "limit", value: String(historyPageSize)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "order", value: "latest"),
            URLQueryItem(name: "inline_images", value: "false")
        ])
    }
    func loadOlder(_ c: Conversation) async {
        guard let client, c.key.service == client.service, conversations[c.key] === c, !c.loading else { return }
        if !c.historyBacklog.isEmpty {
            let page = Array(c.historyBacklog.suffix(100)); c.historyBacklog.removeLast(page.count)
            c.messages.insert(contentsOf: page, at: 0); c.hasOlder = !c.historyBacklog.isEmpty; return
        }
        c.loading = true; defer { c.loading = false; pruneConversationCache() }; let epoch = generation
        do {
            let result = try await historyPage(c, client: client, offset: c.historyOffset)
            guard epoch == generation else { return }
            let rows = result["messages"].array; c.historyOffset += rows.count; c.hasOlder = rows.count == historyPageSize
            let existing = Set(c.messages.map(\.id))
            c.messages.insert(contentsOf: Message.visibleHistory(rows).filter { !existing.contains($0.id) }, at: 0)
        } catch { c.error = error.localizedDescription }
    }
    func retryResume() async {
        guard let c = current, let client, connected, !c.loading, !c.queryingStatus else { return }
        let epoch = generation
        c.queryingStatus = true; c.statusQueryResult = nil
        defer { c.queryingStatus = false; pruneConversationCache() }
        c.readOnlyReason = nil
        await resume(c, client: client, epoch: epoch)
        guard epoch == generation else { return }
        if c.uncertain {
            c.statusQueryResult = "已查询，仍无法确认。" + (c.error ?? "请稍后重试或检查服务端历史。")
        }
    }
    func recoverUnconfirmedMessage() {
        guard connected, let c = current, let text = c.recoverUnconfirmedMessage() else { return }
        draft = draft.isEmpty ? text : draft + "\n\n" + text
    }
    private func bind(_ c: Conversation) {
        guard let id = c.runtimeID, !id.isEmpty else { return }; routes[id] = c.key
        for frame in earlyFrames.removeValue(forKey: id) ?? [] { route(frame) }
    }
    func submitDraft(queue: Bool = false) {
        let origin = navigation
        Task { guard origin == navigation else { return }; await send(queue: queue) }
    }
    func stopCurrent() {
        guard let c = current else { return }
        Task { await interrupt(conversation: c) }
    }
    func send(queue: Bool = false) async {
        guard canSend, let client else { return }
        // Seal already received text before inserting a correction in the transcript.
        flushFrames()
        guard canSend else { return }
        if let c = current, c.generating {
            await sendFollowUp(c, client: client, queue: queue)
            return
        }
        let profile = selectedProfile; let text = draft; let epoch = generation; let startingSession = selectedSession; let originNavigation = navigation
        var sendingKey = currentKey
        if let sendingKey { sendingSessions.insert(sendingKey) }
        else { creatingSessions[originNavigation] = profile }
        defer {
            if epoch == generation {
                if let sendingKey { sendingSessions.remove(sendingKey) }
                creatingSessions.removeValue(forKey: originNavigation)
                pruneConversationCache()
            }
        }
        do {
            var c: Conversation
            if let current { c = current }
            else {
                let snapshot = try await client.execute(.createSession(profile: profile))
                guard epoch == generation else { return }
                let id = snapshot["stored_session_id"].string
                guard !id.isEmpty else { throw ClientError(message: "服务未返回持久会话 ID，请升级 Hermes") }
                let key = ConversationKey(service: service, profile: profile, storedID: id)
                c = Conversation(key: key); c.snapshot(snapshot); conversations[key] = c; touchConversation(key); bind(c)
                sessions[profile, default: []].insert(SessionSummary(id: id, title: String(text.prefix(40))), at: 0)
                sendingKey = key; sendingSessions.insert(key)
                creatingSessions.removeValue(forKey: originNavigation)
                if navigation == originNavigation || selectedProfile != profile {
                    local.update(service) { $0.lastSession[profile] = id }
                }
                let draftKey = LocalState.draftKey(profile: profile, session: startingSession)
                let pendingDraft = local.state(service).drafts[draftKey] ?? ""
                if navigation == originNavigation {
                    local.update(service) { $0.drafts[LocalState.draftKey(profile: profile, session: id)] = pendingDraft == text ? "" : pendingDraft }
                    if selectedProfile == profile && selectedSession == startingSession { selectedSession = id }
                }
            }
            guard let runtime = c.runtimeID, !runtime.isEmpty else { throw ClientError(message: "会话未恢复，请重连后再发送") }
            c.begin(text)
            local.update(service) {
                let key = LocalState.draftKey(profile: profile, session: startingSession)
                if (startingSession != nil || navigation == originNavigation || selectedProfile != profile),
                   $0.drafts[key] == text { $0.drafts[key] = "" }
            }
            if navigation == originNavigation && selectedProfile == profile && selectedSession == c.key.storedID {
                if draft == text { draft = "" } else { persistDraft() }
            }
            do { _ = try await client.execute(.submitPrompt(profile: profile, runtimeID: runtime, text: text)) }
            catch { guard epoch == generation else { return }; c.uncertain = true; c.error = "发送结果未知：\(error.localizedDescription)。请重新查询状态，不会自动重发。" }
        } catch { guard epoch == generation else { return }; self.error = error.localizedDescription }
    }
    private func flushFrames() {
        flushTask?.cancel(); flushTask = nil
        let frames = buffered; buffered = []; frames.forEach { route($0) }; pruneConversationCache()
    }
    private func sendFollowUp(_ c: Conversation, client: HermesClient, queue: Bool) async {
        guard let runtime = c.runtimeID else { return }
        let text = draft; let epoch = generation; let origin = navigation
        let profile = c.key.profile
        sendingSessions.insert(c.key)
        defer { if epoch == generation { sendingSessions.remove(c.key); pruneConversationCache() } }
        let messageID = c.appendFollowUp(text, splitReply: !queue)
        draft = ""
        do {
            var status = ""
            var preserveReply = queue
            if !queue {
                for method in [HermesRPCRequest.FollowUpMethod.redirect, .steer] {
                    do {
                        let result = try await client.execute(.followUp(method, profile: profile, runtimeID: runtime, text: text))
                        guard epoch == generation else { return }
                        flushFrames()
                        let response = result["status"].string
                        if response == "redirected" || response == "queued" {
                            preserveReply = method == .redirect && response == "queued"
                            status = method == .steer ? "已提交引导，等待执行边界" : (response == "queued" ? "已排队，等待下一轮" : "已提交改向")
                            break
                        }
                        guard response == "rejected" else { throw ClientError(message: "服务返回了未知提交状态") }
                    } catch let error as ClientError where error.rpcCode == -32601 || error.rpcCode == 4010 {
                        // Only a definite refusal permits trying another method.
                    }
                }
            }
            guard epoch == generation else { return }
            if status.isEmpty {
                let result = try await client.execute(.submitPrompt(profile: profile, runtimeID: runtime, text: text, queued: true))
                guard epoch == generation else { return }
                flushFrames()
                switch result["status"].string {
                case "queued": status = "已排队，等待下一轮"
                case "streaming": status = "已提交下一轮"
                default: throw ClientError(message: "服务返回了未知排队状态")
                }
                preserveReply = result["status"].string == "queued"
                c.moveFollowUpToEnd(messageID)
            }
            if preserveReply { c.moveFollowUpToEnd(messageID) }
            c.setDelivery(messageID, status, preserveReply: preserveReply)
        } catch {
            guard epoch == generation else { return }
            if let failure = error as? ClientError, failure.rpcCode != nil {
                flushFrames()
                c.setDelivery(messageID, "提交失败", preserveReply: true)
                c.error = "补充消息未提交：\(failure.localizedDescription)"
                let key = LocalState.draftKey(profile: profile, session: c.key.storedID)
                if (local.state(service).drafts[key] ?? "").isEmpty {
                    local.update(service) { $0.drafts[key] = text }
                    if navigation == origin && current === c && draft.isEmpty { draft = text }
                }
            } else {
                c.setDelivery(messageID, "提交结果未知")
                c.uncertain = true
                c.error = "补充消息发送结果未知：\(error.localizedDescription)。请重新查询状态，不会自动重发。"
            }
        }
    }
    func interrupt(conversation: Conversation? = nil) async {
        guard let c = conversation ?? current, let runtime = c.runtimeID, let client, c.key.service == client.service, conversations[c.key] === c else { return }
        do { _ = try await client.execute(.interrupt(profile: c.key.profile, runtimeID: runtime)) }
        catch { c.error = error.localizedDescription }
    }
    func approve(_ approval: Approval, conversation c: Conversation, choice: String) async {
        guard let client, c.key.service == client.service, conversations[c.key] === c,
              c.approvals.contains(where: { $0.id == approval.id }), c.runtimeID != nil,
              approval.params["choices"].array.contains(.string(choice)), !c.uncertain, connected,
              !c.submittingApprovals.contains(approval.id) else { return }
        let epoch = generation
        c.submittingApprovals.insert(approval.id)
        c.approvalErrors.removeValue(forKey: approval.id)
        defer { c.submittingApprovals.remove(approval.id); pruneConversationCache() }
        do {
            let requestID = approval.params["request_id"].string
            if !requestID.isEmpty, let runtime = c.runtimeID {
                let result = try await client.execute(.approve(runtimeID: runtime, requestID: requestID, choice: choice))
                guard epoch == generation else { return }
                guard result["resolved"].number > 0 || result["resolved"] == .bool(true) else {
                    throw ClientError(message: "服务端未确认此审批，请查询会话状态后重试")
                }
            } else {
                try await client.respond(id: approval.id, result: .object(["choice": .string(choice)]))
            }
            guard epoch == generation else { return }
            c.approvals.removeAll { $0.id == approval.id }
        } catch {
            guard epoch == generation else { return }
            c.approvalErrors[approval.id] = "审批提交失败：\(error.localizedDescription)"
        }
    }
    func rename(_ row: SessionSummary, to title: String, profile owner: String? = nil, service expectedService: String? = nil) async {
        guard expectedService == nil || expectedService == service else { return }
        guard let client, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let profile = owner ?? selectedProfile; let epoch = generation
        do {
            _ = try await client.rest("/api/sessions/\(row.id)", method: "PATCH", body: .object(["title": .string(title), "profile": .string(profile)]))
            guard epoch == generation else { return }
            if let index = sessions[profile]?.firstIndex(where: { $0.id == row.id }) { sessions[profile]?[index].title = title }
        } catch { guard epoch == generation else { return }; self.error = error.localizedDescription }
    }
    func canRemoveSession(_ id: String, profile: String) -> Bool {
        let key = ConversationKey(service: service, profile: profile, storedID: id)
        let conversation = conversations[key]
        return connected && !sendingSessions.contains(key) && !sessionMutations.contains(key)
            && conversation?.generating != true && conversation?.uncertain != true && conversation?.loading != true
    }
    func removeSession(_ row: SessionSummary, archive: Bool, profile: String, service expectedService: String) async {
        guard expectedService == service, let client, canRemoveSession(row.id, profile: profile) else { return }
        let epoch = generation
        let key = ConversationKey(service: expectedService, profile: profile, storedID: row.id)
        sessionMutations.insert(key)
        defer { sessionMutations.remove(key); pruneConversationCache() }
        do {
            if archive {
                _ = try await client.rest("/api/sessions/\(row.id)", method: "PATCH",
                    body: .object(["profile": .string(profile), "archived": .bool(true)]))
            } else {
                _ = try await client.rest("/api/sessions/\(row.id)", method: "DELETE",
                    query: [URLQueryItem(name: "profile", value: profile)])
            }
            guard epoch == generation else { return }
            sessions[profile]?.removeAll { $0.id == row.id }
            conversations.removeValue(forKey: key)
            routes = routes.filter { $0.value != key }
            if selectedProfile == profile && selectedSession == row.id { newSession() }
            local.update(expectedService) {
                if $0.lastSession[profile] == row.id { $0.lastSession.removeValue(forKey: profile) }
                if !archive { $0.drafts.removeValue(forKey: LocalState.draftKey(profile: profile, session: row.id)) }
            }
            await loadSessions(profile: profile, query: selectedProfile == profile ? search : "")
        } catch {
            guard epoch == generation else { return }
            self.error = "\(archive ? "归档" : "删除")会话失败：\(error.localizedDescription)"
        }
    }
    private func route(_ frame: JSON) {
        let params = frame["params"]; let id = params["session_id"].string
        if id.isEmpty {
            if !frame["id"].string.isEmpty { let client = client; Task { try? await client?.respond(id: frame["id"].string) } }
            return
        }
        guard let key = routes[id], let c = conversations[key] else {
            if earlyFrames.count < 100 && (earlyFrames[id]?.count ?? 0) < 1000 { earlyFrames[id, default: []].append(frame) }; return
        }
        if frame["_receivedOrdinal"].number <= c.receivedAfter {
            // Tool identities and terminal full text are idempotent. A snapshot is authoritative
            // for stream text/requests, but a tool event emitted during snapshot construction
            // can arrive before its response; retain these independent tool records.
            let type = params["type"].string
            if type == "tool.start" || type == "tool.complete" || (type == "message.complete" && (c.generating || frame["_receivedOrdinal"].number > c.historyReadAfter)) {
                applyEvent(type: type, payload: params["payload"], to: c)
            }
            return
        }
        if frame["method"].string == "event" { applyEvent(type: params["type"].string, payload: params["payload"], to: c) }
        else if frame["method"].string == "approval" {
            if !c.approvals.contains(where: { $0.id == frame["id"].string }) { c.approvals.append(Approval(id: frame["id"].string, params: params)) }
        } else if !frame["id"].string.isEmpty {
            let requestID = frame["id"].string; let client = client
            Task { try? await client?.respond(id: requestID) }
            c.error = "此客户端尚不支持服务请求：\(frame["method"].string)"
        }
    }
    func applyEvent(type: String, payload: JSON, to conversation: Conversation) {
        let wasGenerating = conversation.generating
        let active = isAppActive()
        conversation.apply(type: type, payload: payload, visible: active && currentKey == conversation.key)
        guard type == "message.complete", wasGenerating, conversation.error == nil, !active else { return }
        let profile = profiles.first { $0.name == conversation.key.profile }?.displayName ?? conversation.key.profile
        onReplyCompleted(conversation.key, profile, payload["text"].string)
    }
}
