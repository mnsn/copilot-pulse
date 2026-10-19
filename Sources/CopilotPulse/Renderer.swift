import AppKit
import PulseCore
import SwiftUI

/// `--render <dir>`: draws the menu panel and each widget size from live data into PNGs (light and dark).
/// Useful for checking layout without screen-recording permission, and for README screenshots.
@MainActor
enum Renderer {
    static func run(directory: String) -> Int32 {
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            fputs("Can't create \(directory): \(error.localizedDescription)\n", stderr)
            return 1
        }

        _ = NSApplication.shared
        let suite = "CopilotPulse.render"
        guard let defaults = UserDefaults(suiteName: suite) else { return 1 }
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let loginItem = LoginItem()
        let store = SessionStore(settings: settings)
        store.receive(SessionEngine.loadOnce())

        var written: [String] = []
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let suffix = dark ? "dark" : "light"
            let menu = MenuPanelView()
                .background(Color(nsColor: .windowBackgroundColor))
            if let file = render(menu, appearance: appearance, store: store, settings: settings, loginItem: loginItem,
                                 to: output.appending(path: "menu-\(suffix).png")) {
                written.append(file)
            }
            for size in AppSettings.WidgetSize.allCases {
                settings.widgetSize = size
                let widget = WidgetView()
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(16)
                if let file = render(widget, appearance: appearance, store: store, settings: settings, loginItem: loginItem,
                                     to: output.appending(path: "widget-\(size.rawValue)-\(suffix).png")) {
                    written.append(file)
                }
            }
        }
        written.forEach { print($0) }
        return written.isEmpty ? 1 : 0
    }

    private static func render<V: View>(
        _ view: V, appearance: NSAppearance?, store: SessionStore, settings: AppSettings, loginItem: LoginItem, to url: URL
    ) -> String? {
        let host = NSHostingView(rootView: view
            .environmentObject(store)
            .environmentObject(settings)
            .environmentObject(loginItem))
        host.appearance = appearance
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        // Let SwiftUI settle measured sizes (the menu list measures itself) before sizing the image.
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        do {
            try data.write(to: url)
            return url.path
        } catch {
            fputs("Can't write \(url.path): \(error.localizedDescription)\n", stderr)
            return nil
        }
    }
}
