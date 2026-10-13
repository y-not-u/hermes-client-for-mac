import Foundation
import Observation

@MainActor @Observable final class BotScreenStore {
    private(set) var isOpen = false
    private(set) var connected = false
    private(set) var profile = ""
    private(set) var status: BotScreenStatus?
    private(set) var unsupported = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var busy = false
    private(set) var viewer: BotScreenViewerConnection?
    private(set) var viewerConnected = false
    private var statuses: [BotScreenKey: BotScreenStatus] = [:]
    private var viewerID = ""
    private var key: BotScreenKey?
    private var client: HermesClient?
    private var epoch = UUID()
    private var statusRevision = UUID()
    private var viewerRevision = UUID()
    private var retryTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let requestOverride: ((String, [String: JSON]) async throws -> JSON)?
    init(request: ((String, [String: JSON]) async throws -> JSON)? = nil) { requestOverride = request }
    private func request(_ client: HermesClient, _ method: String, _ params: [String: JSON]) async throws -> JSON {
        if let requestOverride { return try await requestOverride(method, params) }
        return try await client.request(method, params)
    }
    var hasControl: Bool { connected && status?.lease.heldBy(viewerID) == true }
    var humanHasControl: Bool { status?.lease.holder == "human" }

    func configure(client next: HermesClient?, profile nextProfile: String, connected nextConnected: Bool) async {
        let nextKey = next.map { BotScreenKey(service: $0.service, profile: nextProfile) }
        guard nextKey != key || client !== next || connected != nextConnected else { return }
        // Release only our own capability on a deliberate profile/service change. Never force.
        if connected, !viewerID.isEmpty, nextKey != key, let client, let key {
            let id = viewerID
            Task { [weak self] in
                do {
                    guard let self else { return }
                    _ = try await self.request(client, "display.lease.release", ["profile": .string(key.profile), "viewer_id": .string(id)])
                }
                catch { self?.notice = "\(key.profile) 的交还结果未知，请切回该电脑查询控制权" }
            }
        }
        invalidateViewer()
        epoch = UUID(); statusRevision = UUID(); busy = false; viewerID = ""
        key = nextKey; client = next; profile = nextProfile; connected = nextConnected
        status = nextKey.flatMap { statuses[$0] }; unsupported = false; error = nil
        if connected, isOpen { await refresh(); if status?.running == true { await reconnectViewer() }; beginPolling() }
    }
    func disconnected() {
        connected = false; epoch = UUID(); statusRevision = UUID(); busy = false
        invalidateViewer()
        // Viewer identity is scoped to the RPC transport, so it cannot be reused after RPC reconnect.
        viewerID = ""; error = isOpen ? "连接已断开，等待 Hermes 重连" : nil
    }
    func open() async {
        isOpen = true
        await refresh()
        if status?.running == true { await reconnectViewer() }
        beginPolling()
    }
    func close() async {
        isOpen = false; retryTask?.cancel(); retryTask = nil; pollTask?.cancel(); pollTask = nil
        // Hiding immediately invalidates pending observe replies, before a release awaits network IO.
        let oldClient = client; let oldKey = key; let oldID = viewerID; let owned = connected && !viewerID.isEmpty
        epoch = UUID(); statusRevision = UUID(); busy = false; viewer = nil; viewerConnected = false
        if owned, let oldClient, let oldKey {
            do { _ = try await request(oldClient, "display.lease.release", ["profile": .string(oldKey.profile), "viewer_id": .string(oldID)]) }
            catch { self.notice = "\(oldKey.profile) 的交还结果未知，请重新打开该电脑查询控制权" }
        }
    }
    func refresh() async {
        guard connected, let client, let key, !profile.isEmpty else { return }
        let origin = epoch; let revision = UUID(); statusRevision = revision
        do {
            let json = try await request(client, "display.status", ["profile": .string(key.profile)])
            guard origin == epoch, revision == statusRevision else { return }
            try apply(json); unsupported = false; error = nil
            if status?.running != true { viewerRevision = UUID(); viewer = nil; viewerConnected = false }
        } catch {
            guard origin == epoch, revision == statusRevision else { return }; fail(error)
        }
    }
    func start() async { await mutate("display.start", attachAfter: true) }
    func stop() async {
        if humanHasControl {
            guard hasControl else { error = "另一位用户正在控制电脑，请先由持有人交还控制权"; return }
            await handBack()
            guard !humanHasControl else { return }
        }
        await mutate("display.stop", attachAfter: false)
        if status?.running == false { invalidateViewer() }
    }
    func takeOver() async {
        guard viewer != nil, !viewerID.isEmpty else { error = "请先连接桌面再接管"; return }
        await mutate("display.lease.acquire", extra: ["viewer_id": .string(viewerID), "reason": .string("Hermes Mac 接管")], leaseOnly: true)
    }
    func handBack() async {
        guard hasControl, !viewerID.isEmpty else { return }
        await mutate("display.lease.release", extra: ["viewer_id": .string(viewerID)], leaseOnly: true)
    }
    private func mutate(_ method: String, extra: [String: JSON] = [:], leaseOnly: Bool = false, attachAfter: Bool = false) async {
        guard connected, !busy, let client, let key else { return }
        let origin = epoch; busy = true; error = nil
        defer { if origin == epoch { busy = false } }
        var params = extra; params["profile"] = .string(key.profile)
        do {
            let result = try await request(client, method, params)
            guard origin == epoch else {
                if method == "display.lease.acquire", BotScreenLease(result["lease"]).heldBy(params["viewer_id"]!.string) {
                    do { _ = try await request(client, "display.lease.release", ["profile": .string(key.profile), "viewer_id": params["viewer_id"]!]) }
                    catch { self.notice = "\(key.profile) 的迟到接管已生效，交还结果未知，请切回查询" }
                }
                return
            }
            if leaseOnly {
                guard ["agent", "human"].contains(result["lease"]["holder"].string) else {
                    throw ClientError(message: "服务未返回有效控制权，请查询桌面状态")
                }
                applyLease(BotScreenLease(result["lease"]))
            } else { try apply(result) }
            if attachAfter, isOpen { await reconnectViewer() }
        } catch {
            guard origin == epoch else {
                if method == "display.lease.acquire" { self.notice = "\(key.profile) 的接管结果未知，请切回该电脑查询控制权" }
                return
            }; fail(error)
            // Mutations are never retried: their result may be unknown. Read the authoritative state.
            if !unsupported {
                let message = self.error
                await refresh()
                if origin == epoch, !unsupported { self.error = message }
            }
        }
    }
    func reconnectViewer() async {
        guard isOpen, connected, status?.running == true, let client, let key else { return }
        retryTask?.cancel(); retryTask = nil
        let origin = epoch; let attempt = UUID(); viewer = nil; viewerConnected = false
        viewerRevision = attempt
        var params: [String: JSON] = ["profile": .string(key.profile)]
        if !viewerID.isEmpty { params["viewer_id"] = .string(viewerID) }
        do {
            let observed = try await request(client, "display.observe", params)
            guard origin == epoch, attempt == viewerRevision, isOpen else { return }
            let connection = try BotScreenViewerConnection.make(baseURL: client.baseURL, observe: observed)
            try apply(observed); viewerID = observed["viewer_id"].string; viewer = connection; error = nil
        } catch {
            guard origin == epoch, attempt == viewerRevision else { return }; fail(error)
        }
    }
    func handleViewerEvent(_ event: BotScreenViewerEvent) {
        switch event {
        case .connected(let id):
            guard viewer?.id == id else { return }; viewerConnected = true; error = nil
        case .disconnected(let id, _):
            guard viewer?.id == id else { return }; viewerConnected = false; viewer = nil
            scheduleViewerRetry()
        case .failed(let id, let message):
            guard viewer?.id == id else { return }; viewerConnected = false; viewer = nil; error = message
            scheduleViewerRetry()
        }
    }
    func receive(_ frame: JSON) -> Bool {
        guard frame["method"].string == "event", frame["params"]["type"].string.hasPrefix("display.") else { return false }
        let type = frame["params"]["type"].string; let payload = frame["params"]["payload"]
        guard let key, let current = status, !current.profileKey.isEmpty,
              payload["profile_key"].string == current.profileKey else { return true }
        if type == "display.lease" {
            statusRevision = UUID(); applyLease(BotScreenLease(payload["lease"]))
        } else if type == "display.status" { statusRevision = UUID(); do { try apply(payload) } catch { fail(error) } }
        else if type == "display.install.done", payload["status"] != .null { do { try apply(payload["status"]) } catch { fail(error) } }
        if let status { statuses[key] = status }
        return true
    }
    private func apply(_ json: JSON) throws {
        guard !json["profile_key"].string.isEmpty,
              case .bool = json["supported"], case .bool = json["installed"], case .bool = json["running"],
              ["agent", "human"].contains(json["lease"]["holder"].string) else {
            throw ClientError(message: "服务返回了无效桌面状态，请检查 Hermes 版本")
        }
        var next = BotScreenStatus(json)
        // A status request can race a newer global lease transition.
        if let status, status.profileKey == next.profileKey, status.lease.epoch > next.lease.epoch { next.lease = status.lease }
        status = next; if let key { statuses[key] = next }
        if !next.running { viewerRevision = UUID(); viewer = nil; viewerConnected = false }
    }
    private func applyLease(_ lease: BotScreenLease) {
        guard ["agent", "human"].contains(lease.holder), var current = status, lease.epoch >= current.lease.epoch else { return }
        current.lease = lease; status = current; if let key { statuses[key] = current }
    }
    private func fail(_ failure: Error) {
        if let failure = failure as? ClientError, failure.rpcCode == -32601 {
            unsupported = true; error = "此 Hermes 服务尚不支持 Bot Screen，请升级服务端"; invalidateViewer()
        } else { error = failure.localizedDescription }
    }
    private func invalidateViewer() {
        retryTask?.cancel(); retryTask = nil; pollTask?.cancel(); pollTask = nil
        viewerRevision = UUID(); viewer = nil; viewerConnected = false
    }
    private func scheduleViewerRetry() {
        guard isOpen, connected, !unsupported, retryTask == nil else { return }
        let origin = epoch
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, origin == self.epoch else { return }
            self.retryTask = nil
            await self.refresh(); await self.reconnectViewer()
        }
    }
    private func beginPolling() {
        pollTask?.cancel()
        guard isOpen, connected, !unsupported else { return }
        let origin = epoch
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled, origin == self.epoch, self.isOpen else { return }
                if !self.busy {
                    await self.refresh()
                    if self.viewer == nil, self.status?.running == true { await self.reconnectViewer() }
                }
            }
        }
    }
    func dismissNotice() { notice = nil }
}
