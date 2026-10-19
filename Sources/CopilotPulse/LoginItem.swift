import Combine
import Foundation
import ServiceManagement

/// "Launch at login" through the system's login-items service.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = false
    /// macOS can hold a login item until the user allows it in System Settings › Login Items.
    @Published private(set) var needsApproval = false
    @Published private(set) var lastError: String?

    /// Registering only makes sense for the bundled app, not a bare `swift run` binary.
    var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    init() {
        refresh()
    }

    func refresh() {
        let status = isAvailable ? SMAppService.mainApp.status : .notRegistered
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
        if enabled, needsApproval { openSystemSettings() }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
