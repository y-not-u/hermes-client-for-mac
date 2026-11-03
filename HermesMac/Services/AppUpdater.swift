import Foundation
import Combine
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    let configuration = UpdateConfiguration(bundleIdentifier: Bundle.main.bundleIdentifier,
                                            info: Bundle.main.infoDictionary ?? [:])
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    let isAvailable: Bool
    private var started = false
    #if canImport(Sparkle)
    private let controller: SPUStandardUpdaterController?
    #endif

    private init() {
        #if canImport(Sparkle) && !DEBUG
        isAvailable = configuration.supportsUpdates
        controller = isAvailable ? SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: nil, userDriverDelegate: nil) : nil
        if let updater = controller?.updater {
            updater.publisher(for: \.canCheckForUpdates)
                .receive(on: DispatchQueue.main)
                .assign(to: &$canCheckForUpdates)
            updater.publisher(for: \.automaticallyChecksForUpdates)
                .receive(on: DispatchQueue.main)
                .assign(to: &$automaticallyChecksForUpdates)
        }
        #else
        // SwiftPM is the unit-test entry point; only packaged Release apps update.
        isAvailable = false
        #if canImport(Sparkle)
        controller = nil
        #endif
        #endif
    }

    func start() {
        guard isAvailable, !started else { return }
        started = true
        #if canImport(Sparkle)
        controller?.startUpdater()
        #endif
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        #if canImport(Sparkle)
        controller?.checkForUpdates(nil)
        #endif
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isAvailable else { return }
        #if canImport(Sparkle)
        controller?.updater.automaticallyChecksForUpdates = enabled
        #endif
    }
}
