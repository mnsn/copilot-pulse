import AppKit
import Combine
import PulseCore
import SwiftUI

/// Menu-bar item showing colored counts, with the session list in a popover.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let store: SessionStore
    private var cancellables: Set<AnyCancellable> = []

    private static let shownPhases: [DisplayPhase] = [.needsYou, .running, .done, .stopped]

    init(store: SessionStore, settings: AppSettings, loginItem: LoginItem) {
        self.store = store
        super.init()

        let host = NSHostingController(
            rootView: MenuPanelView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(loginItem)
        )
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            let glyph = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Copilot Pulse")
            glyph?.isTemplate = true
            button.image = glyph
        }
        statusItem.autosaveName = "CopilotPulseStatusItem"

        render(store.counts)
        store.$counts
            .removeDuplicates()
            .sink { [weak self] counts in MainActor.assumeIsolated { self?.render(counts) } }
            .store(in: &cancellables)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.logPlacement() }
        }

        // Opening a session hands focus to Copilot; don't leave the list hanging open.
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.popover.performClose(nil) } }
            .store(in: &cancellables)
    }

    func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        store.refresh()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func logPlacement() {
        let frame = statusItem.button?.window?.frame ?? .zero
        Log.app.info("Menu bar item visible=\(self.statusItem.isVisible, privacy: .public) frame=\(NSStringFromRect(frame), privacy: .public)")
    }

    private func render(_ counts: PhaseCounts) {
        guard let button = statusItem.button else { return }
        let font = NSFont.menuBarFont(ofSize: 0)
        let title = NSMutableAttributedString()
        var spoken: [String] = []
        for phase in Self.shownPhases where counts[phase] > 0 {
            title.append(NSAttributedString(string: " "))
            title.append(Self.symbol(phase.symbol, color: phase.nsColor, font: font))
            title.append(NSAttributedString(
                string: "\u{2009}\(counts[phase])",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .medium),
                             .foregroundColor: NSColor.labelColor]
            ))
            spoken.append("\(counts[phase]) \(phase.title.lowercased())")
        }
        button.attributedTitle = title
        button.imagePosition = title.length == 0 ? .imageOnly : .imageLeading
        button.toolTip = spoken.isEmpty ? "Copilot Pulse: all quiet" : "Copilot Pulse: " + spoken.joined(separator: ", ")
        button.setAccessibilityLabel(button.toolTip)
    }

    private static func symbol(_ name: String, color: NSColor, font: NSFont) -> NSAttributedString {
        let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize - 2, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return NSAttributedString() }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0, y: (font.capHeight - image.size.height) / 2,
            width: image.size.width, height: image.size.height
        )
        return NSAttributedString(attachment: attachment)
    }
}
