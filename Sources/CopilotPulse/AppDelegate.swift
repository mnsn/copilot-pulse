import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let loginItem = LoginItem()
    private lazy var store = SessionStore(settings: settings)
    private var statusItem: StatusItemController?
    private var widget: DesktopWidgetController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu-bar app has no visible windows most of the time; don't let macOS reclaim it.
        ProcessInfo.processInfo.disableAutomaticTermination("Shows live Copilot session status")
        Log.app.info("Launched from \(Bundle.main.bundlePath, privacy: .public)")
        statusItem = StatusItemController(store: store, settings: settings, loginItem: loginItem)
        widget = DesktopWidgetController(store: store, settings: settings, loginItem: loginItem)
        store.start()
    }

    /// Launching the app again (Finder, Spotlight, `open`) shows the session list.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.showPopover()
        return false
    }
}
