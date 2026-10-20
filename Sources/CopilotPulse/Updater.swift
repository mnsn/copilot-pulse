import AppKit
import Combine
import Sparkle

/// In-app updates with Sparkle, from the appcast attached to the latest GitHub release.
///
/// Only the app checks for updates: the command-line modes and `--render` never start an updater,
/// and a binary without a feed URL and a public key in its bundle (such as a `.build` binary) can't.
@MainActor
final class Updater: NSObject, ObservableObject {
    /// Whether this copy of the app updates itself.
    @Published private(set) var isAvailable = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    /// The version a scheduled check found, while it waits for the user's attention.
    @Published private(set) var pendingVersion: String?

    private var controller: SPUStandardUpdaterController?
    private var cancellables: Set<AnyCancellable> = []

    /// Creates Sparkle's updater, which asks on the second launch whether to check automatically.
    func start() {
        guard controller == nil, Self.bundleHasUpdateSettings else { return }
        // GitHub's redirects set cookies, one of them a long-lived ID. Sending them back would let
        // GitHub link one day's check to the next, and Pulse makes no other requests that need them.
        HTTPCookieStorage.shared.cookieAcceptPolicy = .never
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)

        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self
        )
        self.controller = controller
        isAvailable = true

        let updater = controller.updater
        // The same for everyone, instead of the user's preferred languages. The notes are in English.
        updater.httpHeaders = ["Accept-Language": "en"]
        updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] value in MainActor.assumeIsolated { self?.canCheckForUpdates = value } }
            .store(in: &cancellables)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] value in MainActor.assumeIsolated { self?.automaticallyChecks = value } }
            .store(in: &cancellables)
        controller.startUpdater()
    }

    /// Checks now, or brings an update that's already waiting to the front.
    func checkForUpdates() {
        guard let controller else { return }
        // The app runs in the background; without this, Sparkle's window can open behind other apps.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    private static var bundleHasUpdateSettings: Bool {
        ["SUFeedURL", "SUPublicEDKey"].allSatisfy { key in
            (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.isEmpty == false
        }
    }
}

/// Gentle reminders: right after launch Sparkle shows a new version itself. Later, a scheduled check
/// mustn't pull focus from the app you're using, so the panel shows that an update is available.
extension Updater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        Log.app.info("Version \(version, privacy: .public) is available\(handleShowingUpdate ? "" : "; reminding in the panel", privacy: .public)")
        if !handleShowingUpdate {
            pendingVersion = version
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}
