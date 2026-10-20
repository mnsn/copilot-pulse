import PulseCore
import SwiftUI

/// One session: status icon, name, state line, optional detail, how long it's been in that state, and,
/// if turned on, how full its context window is.
struct SessionRowView: View {
    let session: SessionSnapshot
    let now: Date
    var compact = false
    var action: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @LocalState private var isHovered = false

    /// Fixed height of a compact row, so the widget can size itself to a whole number of rows.
    static let compactHeight: CGFloat = 42

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: session.rowSymbol)
                    .font(.system(size: compact ? 15 : 17))
                    .foregroundStyle(session.rowColor)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(session.displayName)
                            .font(.system(size: 13, weight: session.phase == .idle ? .regular : .semibold))
                            .foregroundStyle(session.phase == .idle ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        if let contextUsage {
                            ContextUsageView(usage: contextUsage)
                        }
                        Text(Elapsed.short(since: session.since, now: now))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    if compact {
                        Text(compactLine)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(session.subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(session.phase == .idle ? Color.secondary : session.rowColor)
                            .lineLimit(1)
                        if let detail = session.detail {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(session.phase == .needsYou ? 3 : 2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, compact ? 5 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.displayName), \(session.headline)")
        .accessibilityValue([session.detail, contextUsage.map(ContextUsageView.description)].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens the session in GitHub Copilot")
    }

    /// The session's context usage, when the setting is on and the app has measured it.
    private var contextUsage: ContextUsage? {
        settings.showContextUsage ? session.contextUsage : nil
    }

    private var compactLine: String {
        guard let detail = session.detail else { return session.subtitle }
        return "\(session.headline) · \(detail)"
    }

    private var helpText: String {
        var lines = [session.displayName, session.subtitle]
        if let detail = session.detail { lines.append(detail) }
        if !session.choices.isEmpty { lines.append("Options: " + session.choices.joined(separator: " | ")) }
        if let contextUsage { lines.append(ContextUsageView.description(contextUsage)) }
        lines.append("Click to open in GitHub Copilot")
        return lines.joined(separator: "\n")
    }
}

/// How full a session's context window is: a ring and a percentage. It turns orange as the
/// conversation nears the size at which Copilot compacts it (about 80% of the window).
struct ContextUsageView: View {
    let usage: ContextUsage

    static let warningFraction = 0.7

    var body: some View {
        HStack(spacing: 3) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: usage.fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 9, height: 9)
            Text("\(usage.percent)%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(color)
        }
        .fixedSize()
    }

    private var color: Color {
        usage.fraction >= Self.warningFraction ? .orange : .secondary
    }

    static func description(_ usage: ContextUsage) -> String {
        let tokens = usage.tokens.formatted(.number.notation(.compactName))
        let limit = usage.limit.formatted(.number.notation(.compactName))
        return "Context: \(usage.percent)% full (\(tokens) of \(limit) tokens)"
    }
}

/// Small "icon count" chips for the non-empty phases.
struct CountChips: View {
    let counts: PhaseCounts
    var phases: [DisplayPhase] = [.needsYou, .running, .done, .stopped]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(phases, id: \.self) { phase in
                if counts[phase] > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: phase.symbol)
                            .foregroundStyle(phase.color)
                        Text("\(counts[phase])")
                            .monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .help("\(counts[phase]) \(phase.title.lowercased())")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
