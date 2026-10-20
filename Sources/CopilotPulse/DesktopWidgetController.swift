import AppKit
import Combine
import SwiftUI

/// A borderless, non-activating panel pinned to the desktop (or floating), styled like a macOS widget.
/// It's an ordinary window we redraw ourselves, so it updates the instant data changes.
/// No WidgetKit timeline budget is involved.
@MainActor
final class DesktopWidgetController {
    private static let autosaveName = "CopilotPulseWidget"
    private static let cornerRadius: CGFloat = 20
    private static let margin: CGFloat = 24

    private let store: SessionStore
    private let settings: AppSettings
    private let loginItem: LoginItem
    private let updater: Updater
    private var panel: WidgetPanel?
    private var cancellables: Set<AnyCancellable> = []

    init(store: SessionStore, settings: AppSettings, loginItem: LoginItem, updater: Updater) {
        self.store = store
        self.settings = settings
        self.loginItem = loginItem
        self.updater = updater

        settings.$showWidget
            .combineLatest(settings.$placement, settings.$widgetSize)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show, placement, size in
                MainActor.assumeIsolated { self?.apply(show: show, placement: placement, size: size) }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.keepOnScreen() } }
            .store(in: &cancellables)
    }

    private func apply(show: Bool, placement: AppSettings.Placement, size: AppSettings.WidgetSize) {
        guard show else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        panel.level = placement == .desktop
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            : .floating
        resize(panel, to: CGSize(width: size.width, height: WidgetView.height(for: size)))
        keepOnScreen()
        panel.orderFrontRegardless()
        Log.app.info("Widget \(placement.rawValue, privacy: .public)/\(size.rawValue, privacy: .public) at \(NSStringFromRect(panel.frame), privacy: .public)")
    }

    private func makePanel() -> WidgetPanel {
        let panel = WidgetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.title = "Copilot Pulse"

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Self.cornerRadius)

        let host = FirstMouseHostingView(
            rootView: WidgetView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(loginItem)
                .environmentObject(updater)
        )
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background

        if !panel.setFrameUsingName(Self.autosaveName) {
            placeAtDefaultPosition(panel)
        }
        panel.setFrameAutosaveName(Self.autosaveName)
        self.panel = panel
        return panel
    }

    /// Resizes while keeping the top-left corner where the user put it.
    private func resize(_ panel: NSPanel, to size: CGSize) {
        var frame = panel.frame
        guard frame.size != size else { return }
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private func placeAtDefaultPosition(_ panel: NSPanel) {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - Self.margin, y: visible.maxY - size.height - Self.margin))
    }

    /// Brings the widget back if a display was disconnected or rearranged under it.
    private func keepOnScreen() {
        guard let panel else { return }
        let frame = panel.frame
        let isVisible = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            return overlap.width >= 60 && overlap.height >= 40
        }
        if !isVisible {
            placeAtDefaultPosition(panel)
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Never takes focus from the app you're working in.
final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on an inactive widget hit the row under the cursor.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
