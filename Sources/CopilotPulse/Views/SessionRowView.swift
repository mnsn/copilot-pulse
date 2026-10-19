import PulseCore
import SwiftUI

/// One session: status icon, name, state line, optional detail, and how long it's been in that state.
struct SessionRowView: View {
    let session: SessionSnapshot
    let now: Date
    var compact = false
    var action: () -> Void

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
        .accessibilityValue(session.detail ?? "")
        .accessibilityHint("Opens the session in GitHub Copilot")
    }

    private var compactLine: String {
        guard let detail = session.detail else { return session.subtitle }
        return "\(session.headline) · \(detail)"
    }

    private var helpText: String {
        var lines = [session.displayName, session.subtitle]
        if let detail = session.detail { lines.append(detail) }
        if !session.choices.isEmpty { lines.append("Options: " + session.choices.joined(separator: " | ")) }
        lines.append("Click to open in GitHub Copilot")
        return lines.joined(separator: "\n")
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
