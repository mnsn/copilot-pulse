import PulseCore
import SwiftUI

/// Settings shared by the popover's gear menu and the widget's context menu.
struct SettingsMenuContent: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var loginItem: LoginItem
    @EnvironmentObject private var updater: Updater

    var body: some View {
        Toggle("Show Desktop Widget", isOn: $settings.showWidget)

        Picker("Widget Position", selection: $settings.placement) {
            ForEach(AppSettings.Placement.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)

        Picker("Widget Size", selection: $settings.widgetSize) {
            ForEach(AppSettings.WidgetSize.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)

        Picker("Keep Finished Sessions For", selection: $settings.keepEndedMinutes) {
            ForEach(AppSettings.keepEndedChoices, id: \.minutes) { Text($0.title).tag($0.minutes) }
        }
        .pickerStyle(.menu)

        Toggle("Show Context Usage", isOn: $settings.showContextUsage)

        if loginItem.isAvailable {
            Toggle("Launch at Login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            if loginItem.needsApproval {
                Button("Allow in Login Items Settings…") { loginItem.openSystemSettings() }
            } else if let error = loginItem.lastError {
                Text("Launch at Login failed: \(error)")
            }
        }

        Divider()

        if updater.isAvailable {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
            Toggle("Check for Updates Automatically", isOn: Binding(
                get: { updater.automaticallyChecks },
                set: { updater.setAutomaticallyChecks($0) }
            ))
            Divider()
        }

        Button("Open GitHub Copilot") { CopilotApp.activate() }
        Button("Quit Copilot Pulse") { NSApp.terminate(nil) }
    }
}
