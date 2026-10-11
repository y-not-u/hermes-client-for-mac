import Foundation
import Observation

@MainActor @Observable final class AppStore {
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
    private var client: HermesClient?
    @ObservationIgnored private let makeClient: (String) throws -> HermesClient
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
    private var busyProfiles: Set<String> = []
    init(local: LocalState? = nil, makeClient: ((String) throws -> HermesClient)? = nil) { let state = local ?? LocalState(); self.local = state; address = state.address; self.makeClient = makeClient ?? { try HermesClient(address: $0) } }
    var service: String { client?.service ?? address }
    var currentKey: ConversationKey? { selectedSession.map { ConversationKey(service: service, profile: selectedProfile, storedID: $0) } }
    var current: Conversation? { currentKey.flatMap { conversations[$0] } }
    var profileTitle: String { profiles.first(where: { $0.name == selectedProfile })?.displayName ?? "Hermes" }
    var canSend: Bool { connected && !selectedProfile.isEmpty && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !profileBusy(selectedProfile) && current?.readOnlyReason == nil && current?.loading != true && (selectedSession == nil || current != nil) }
    func profileBusy(_ profile: String) -> Bool { busyProfiles.contains(profile) || conversations.values.contains { $0.key.profile == profile && ($0.generating || $0.uncertain) } }
    func profileApproval(_ profile: String) -> Bool { conversations.values.contains { $0.key.profile == profile && !$0.approvals.isEmpty } }
    func profileUnread(_ profile: String) -> Bool { conversations.values.contains { $0.key.profile == profile && $0.unread } }
    private func persistDraft() {
        guard !selectedProfile.isEmpty else { return }
        let key = LocalState.draftKey(profile: selectedProfile, session: selectedSession)
        local.update(service) { $0.drafts[key] = draft }
    }
    func connect(address newAddress: String? = nil, token: String? = nil) async {
        reconnectTask?.cancel(); reconnectTask = nil
        let attempt = UUID(); connectionAttempt = attempt; var activated = false
        do {
            let next = try makeClient(newAddress ?? address)
            if let token { try await next.setSessionToken(token) }
            guard connectionAttempt == attempt else { return }
            let changed = next.service != service
            generation = attempt; activated = true
            let epoch = attempt
            client?.disconnect(); client = next; connected = false; connecting = true; connection = "连接中…"; error = nil
            busyProfiles = []; routes = [:]; earlyFrames = [:]; buffered = []; flushTask?.cancel(); flushTask = nil
            if changed { conversations = [:]; sessions = [:]; profiles = []; busyProfiles = []; selectedProfile = ""; selectedSession = nil; draft = ""; search = "" }
            address = next.service; local.address = address
            installCallbacks(next, epoch: epoch)
            try await next.connect(); guard epoch == generation else { return }
            connected = true; connecting = false; connection = "已连接"
            try await loadProfiles(next, epoch: epoch)
            // Reattach every previously open session, including background turns and approvals.
            for conversation in Array(conversations.values) {
                guard epoch == generation else { return }
                await resume(conversation, client: next, epoch: epoch)
            }
            let saved = local.state(service)
            let profile = profiles.contains(where: { $0.name == selectedProfile }) ? selectedProfile : (profiles.contains(where: { $0.name == saved.selectedProfile }) ? saved.selectedProfile : profiles.first?.name ?? "")
            await selectProfile(profile)
        } catch {
            guard connectionAttempt == attempt else { return }
            if !activated { self.error = error.localizedDescription; return }
            guard attempt == generation else { return }; connecting = false; connected = false; connection = "连接失败"; self.error = error.localizedDescription }
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
            self.buffered.append(frame)
            if self.flushTask == nil {
                self.flushTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(40)); guard let self, !Task.isCancelled else { return }
                    let frames = self.buffered; self.buffered = []; self.flushTask = nil
                    for frame in frames { self.route(frame) }
                }
            }
        }
        client.onDisconnect = { [weak self] error in
            guard let self, self.generation == epoch else { return }
            // Flush received frames before declaring the stream uncertain.
            self.flushTask?.cancel(); self.flushTask = nil
            let frames = self.buffered; self.buffered = []; frames.forEach { self.route($0) }
            self.connected = false; self.connection = "已断开 · 等待重连"; self.error = error.localizedDescription
            for c in self.conversations.values { if c.generating { c.uncertain = true }; c.runtimeID = nil }
            self.reconnectTask = Task { [weak self] in
                for seconds in [2, 4, 8, 16, 30] {
                    try? await Task.sleep(for: .seconds(seconds))
                    guard let self, !Task.isCancelled, epoch == self.generation else { return }
                    do {
                        try await client.connect(); guard epoch == self.generation else { return }
                        self.routes = [:]; self.earlyFrames = [:]
                        try await self.loadProfiles(client, epoch: epoch)
                        for c in Array(self.conversations.values) where self.profiles.contains(where: { $0.name == c.key.profile }) { await self.resume(c, client: client, epoch: epoch) }
                        self.connected = true; self.connection = "已连接"; self.error = nil; return
                    } catch { guard epoch == self.generation, !Task.isCancelled else { return }; self.error = error.localizedDescription }
                }
                guard let self, epoch == self.generation, !Task.isCancelled else { return }
                self.connection = "已断开 · 请手动重新连接"
            }
        }
    }
    func selectProfile(_ profile: String) async {
        guard profiles.contains(where: { $0.name == profile }) else { return }
        navigation = UUID(); selectedProfile = profile; selectedSession = local.state(service).lastSession[profile]; search = ""
        draft = local.state(service).drafts[LocalState.draftKey(profile: profile, session: selectedSession)] ?? ""
        local.update(service) { $0.selectedProfile = profile }
        if let pending = conversations.values.first(where: { $0.key.profile == profile && !$0.approvals.isEmpty }) { selectedSession = pending.key.storedID; restoreDraft() }
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
    func newSession() { navigation = UUID(); selectedSession = nil; local.update(service) { $0.lastSession.removeValue(forKey: selectedProfile) }; restoreDraft() }
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
            let result = try await client.rest(path, query: [URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "limit", value: "40"), URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "q", value: query)])
            guard epoch == generation, listRevision[profile] == revision else { return }
            let rows = result[query.isEmpty ? "sessions" : "results"].array.map(SessionSummary.init)
            if more { sessions[profile, default: []].append(contentsOf: rows.filter { row in !(sessions[profile] ?? []).contains(where: { $0.id == row.id }) }) }
            else {
                let open = (sessions[profile] ?? []).filter { row in conversations.values.contains { $0.key.profile == profile && $0.key.storedID == row.id && ($0.generating || $0.messages.isEmpty) } && !rows.contains(where: { $0.id == row.id }) }
                sessions[profile] = query.isEmpty ? open + rows : rows
            }
            listHasMore[profile] = rows.count == 40 && query.isEmpty
        } catch { guard epoch == generation else { return }; self.error = error.localizedDescription }
    }
    func openSession(_ id: String, profile: String? = nil) async {
        let owner = profile ?? selectedProfile
        guard owner == selectedProfile, let client else { return }
        navigation = UUID(); selectedSession = id; restoreDraft(); local.update(service) { $0.lastSession[owner] = id }
        let key = ConversationKey(service: service, profile: owner, storedID: id)
        if let c = conversations[key] { c.unread = false; if c.runtimeID != nil || c.loading { return } }
        let c = conversations[key] ?? Conversation(key: key); conversations[key] = c
        await resume(c, client: client, epoch: generation)
    }
    private func resume(_ c: Conversation, client: HermesClient, epoch: UUID) async {
        guard !(c.loading && c.loadingEpoch == epoch), c.readOnlyReason != "此 profile 已被删除" else { return }
        c.loading = true; c.loadingEpoch = epoch
        defer { if c.loadingEpoch == epoch { c.loading = false; c.loadingEpoch = nil } }
        do {
            let snapshot = try await client.request("session.resume", ["profile": .string(c.key.profile), "session_id": .string(c.key.storedID), "omit_messages": .bool(false)])
            guard epoch == generation else { return }
            c.snapshot(snapshot); c.historyOffset = c.messages.count + c.historyBacklog.count; c.hasOlder = !c.historyBacklog.isEmpty
            bind(c)
            for request in snapshot["open_requests"].array where request["method"].string != "approval" {
                try? await client.respond(id: request["id"].string)
            }
        } catch {
            guard epoch == generation else { return }
            c.runtimeID = nil; c.generating = false; c.uncertain = false; c.approvals = []
            c.readOnlyReason = "历史暂无法恢复，当前为只读：\(error.localizedDescription)"
            if c.messages.isEmpty {
                do {
                    let result = try await client.rest("/api/sessions/\(c.key.storedID)/messages", query: [URLQueryItem(name: "profile", value: c.key.profile), URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "order", value: "latest")])
                    guard epoch == generation else { return }
                    c.messages = result["messages"].array.map(Message.init).filter { $0.role != "system" && !$0.text.isEmpty }; c.historyOffset = result["messages"].array.count; c.hasOlder = c.historyOffset == 100
                } catch { c.error = error.localizedDescription }
            }
        }
    }
    func loadOlder(_ c: Conversation) async {
        guard let client, c.key.service == client.service, conversations[c.key] === c, !c.loading else { return }
        if !c.historyBacklog.isEmpty {
            let page = Array(c.historyBacklog.suffix(100)); c.historyBacklog.removeLast(page.count)
            c.messages.insert(contentsOf: page, at: 0); c.hasOlder = !c.historyBacklog.isEmpty; return
        }
        c.loading = true; defer { c.loading = false }; let epoch = generation
        do {
            let result = try await client.rest("/api/sessions/\(c.key.storedID)/messages", query: [URLQueryItem(name: "profile", value: c.key.profile), URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "offset", value: String(c.historyOffset)), URLQueryItem(name: "order", value: "latest")])
            guard epoch == generation else { return }
            let rows = result["messages"].array; c.historyOffset += rows.count; c.hasOlder = rows.count == 100
            let existing = Set(c.messages.map(\.id))
            c.messages.insert(contentsOf: rows.map(Message.init).filter { $0.role != "system" && !$0.text.isEmpty && !existing.contains($0.id) }, at: 0)
        } catch { c.error = error.localizedDescription }
    }
    func retryResume() async { if let c = current, let client { c.readOnlyReason = nil; await resume(c, client: client, epoch: generation) } }
    private func bind(_ c: Conversation) {
        guard let id = c.runtimeID, !id.isEmpty else { return }; routes[id] = c.key
        for frame in earlyFrames.removeValue(forKey: id) ?? [] { route(frame) }
    }
    func submitDraft() {
        let origin = navigation
        Task { guard origin == navigation else { return }; await send() }
    }
    func stopCurrent() {
        guard let c = current else { return }
        Task { await interrupt(conversation: c) }
    }
    func send() async {
        guard canSend, let client else { return }
        let profile = selectedProfile; let text = draft; let epoch = generation; let startingSession = selectedSession; let originNavigation = navigation
        busyProfiles.insert(profile); defer { if epoch == generation { busyProfiles.remove(profile) } }
        do {
            var c: Conversation
            if let current { c = current }
            else {
                let snapshot = try await client.request("session.create", ["profile": .string(profile), "source": .string("dashboard"), "close_on_disconnect": .bool(false)])
                guard epoch == generation else { return }
                let id = snapshot["stored_session_id"].string
                guard !id.isEmpty else { throw ClientError(message: "服务未返回持久会话 ID，请升级 Hermes") }
                let key = ConversationKey(service: service, profile: profile, storedID: id)
                c = Conversation(key: key); c.snapshot(snapshot); conversations[key] = c; bind(c)
                sessions[profile, default: []].insert(SessionSummary(id: id, title: String(text.prefix(40))), at: 0)
                local.update(service) { $0.lastSession[profile] = id }
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
                if $0.drafts[key] == text { $0.drafts[key] = "" }
            }
            if navigation == originNavigation && selectedProfile == profile && selectedSession == c.key.storedID {
                if draft == text { draft = "" } else { persistDraft() }
            }
            do { _ = try await client.request("prompt.submit", ["session_id": .string(runtime), "profile": .string(profile), "text": .string(text)]) }
            catch { guard epoch == generation else { return }; c.uncertain = true; c.error = "发送结果未知：\(error.localizedDescription)。请重新查询状态，不会自动重发。" }
        } catch { guard epoch == generation else { return }; self.error = error.localizedDescription }
    }
    func interrupt(conversation: Conversation? = nil) async {
        guard let c = conversation ?? current, let runtime = c.runtimeID, let client, c.key.service == client.service, conversations[c.key] === c else { return }
        do { _ = try await client.request("session.interrupt", ["session_id": .string(runtime), "profile": .string(c.key.profile)]) }
        catch { c.error = error.localizedDescription }
    }
    func approve(_ approval: Approval, conversation c: Conversation, choice: String) async {
        guard let client, c.key.service == client.service, conversations[c.key] === c,
              c.approvals.contains(where: { $0.id == approval.id }), c.runtimeID != nil,
              approval.params["choices"].array.contains(.string(choice)), !c.uncertain, connected else { return }; let epoch = generation
        do { try await client.respond(id: approval.id, result: .object(["choice": .string(choice)])); guard epoch == generation else { return }; c.approvals.removeAll { $0.id == approval.id } }
        catch { c.error = error.localizedDescription }
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
            if type == "tool.start" || type == "tool.complete" || (type == "message.complete" && c.generating) {
                c.apply(type: type, payload: params["payload"], visible: currentKey == key)
            }
            return
        }
        if frame["method"].string == "event" { c.apply(type: params["type"].string, payload: params["payload"], visible: currentKey == key) }
        else if frame["method"].string == "approval" {
            if !c.approvals.contains(where: { $0.id == frame["id"].string }) { c.approvals.append(Approval(id: frame["id"].string, params: params)) }
        } else if !frame["id"].string.isEmpty {
            let requestID = frame["id"].string; let client = client
            Task { try? await client?.respond(id: requestID) }
            c.error = "此客户端尚不支持服务请求：\(frame["method"].string)"
        }
    }
}
