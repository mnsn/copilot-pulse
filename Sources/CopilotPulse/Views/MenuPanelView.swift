import PulseCore
import SwiftUI

/// The menu-bar popover: every session grouped by what it needs from you.
struct MenuPanelView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var loginItem: LoginItem
    @EnvironmentObject private var updater: Updater

    @LocalState private var contentHeight: CGFloat = 0
    @LocalState private var showIdle = false

    private static let maxListHeight: CGFloat = 540

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                list
                    .padding(8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 60), Self.maxListHeight))
            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear { loginItem.refresh() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "waveform.path.ecg")
                .foregroundStyle(.tint)
            Text("Copilot Pulse")
                .font(.headline)
            Spacer()
            CountChips(counts: store.counts)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }

            if store.hasLoaded && store.activeSessions.isEmpty {
                QuietView(idleCount: store.counts.idle)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }

            ForEach([DisplayPhase.needsYou, .running, .done, .stopped], id: \.self) { phase in
                let sessions = store.sessions(in: phase)
                if !sessions.isEmpty {
                    section(phase, sessions)
                }
            }

            let idle = store.sessions(in: .idle)
            if !idle.isEmpty {
                DisclosureGroup(isExpanded: $showIdle) {
                    VStack(spacing: 0) {
                        ForEach(idle) { session in
                            SessionRowView(session: session, now: store.now, compact: true) { store.open(session) }
                        }
                    }
                } label: {
                    Text("Idle (\(idle.count))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showIdle.toggle() } }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private func section(_ phase: DisplayPhase, _ sessions: [SessionSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(phase.title) (\(sessions.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(phase.color)
                Spacer()
                if phase == .done || phase == .stopped {
                    Button("Clear") { store.clear(phase) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .help("Mark these as seen")
                }
            }
            .padding(.horizontal, 8)
            ForEach(sessions) { session in
                SessionRowView(session: session, now: store.now) { store.open(session) }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                CopilotApp.activate()
            } label: {
                Label("Open Copilot", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            Spacer()
            if let version = updater.pendingVersion {
                Button {
                    updater.checkForUpdates()
                } label: {
                    Label("Update Available", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .help("Copilot Pulse \(version) is available")
            }
            Menu {
                SettingsMenuContent()
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct QuietView: View {
    let idleCount: Int

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("All quiet")
                .font(.system(size: 13, weight: .semibold))
            Text(idleCount == 0 ? "No sessions yet" : idleCount == 1 ? "1 idle session" : "\(idleCount) idle sessions")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
