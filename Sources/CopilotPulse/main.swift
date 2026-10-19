import AppKit

// `CopilotPulse --dump | --json | --watch | --help` work from a terminal without starting the UI.
if let code = CLI.run(Array(CommandLine.arguments.dropFirst())) {
    exit(code)
}

MainActor.assumeIsolated {
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--render") {
        exit(Renderer.run(directory: index + 1 < arguments.count ? arguments[index + 1] : "render"))
    }

    // One instance per user; a second launch (e.g. running the binary again) just exits.
    if let bundleId = Bundle.main.bundleIdentifier {
        let me = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .contains(where: { $0.processIdentifier != me }) {
            exit(0)
        }
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
