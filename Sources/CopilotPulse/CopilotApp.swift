import AppKit

/// Talking to the GitHub Copilot desktop app.
@MainActor
enum CopilotApp {
    static let bundleIdentifier = "com.github.githubapp"

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
    }

    static var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// Opens a session or chat via the app's `ghapp://` deep link.
    static func open(sessionId: String) {
        guard let url = URL(string: "ghapp://sessions/\(sessionId)") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let applicationURL {
            NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static func activate() {
        guard let applicationURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
    }
}
