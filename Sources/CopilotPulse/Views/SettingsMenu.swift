import PulseCore
import SwiftUI

/// Settings shared by the popover's gear menu and the widget's context menu.
struct SettingsMenuContent: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var loginItem: LoginItem

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

        Button("Open GitHub Copilot") { CopilotApp.activate() }
        Button("Quit Copilot Pulse") { NSApp.terminate(nil) }
    }
}
