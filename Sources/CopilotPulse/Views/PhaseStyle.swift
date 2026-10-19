import PulseCore
import SwiftUI

extension DisplayPhase {
    var title: String {
        switch self {
        case .needsYou: return "Needs You"
        case .running: return "Running"
        case .done: return "Finished"
        case .stopped: return "Stopped"
        case .idle: return "Idle"
        }
    }

    var color: Color {
        switch self {
        case .needsYou: return .orange
        case .running: return .blue
        case .done: return .green
        case .stopped: return .red
        case .idle: return .secondary
        }
    }

    /// Symbol used for count chips in the menu bar and widget header.
    var symbol: String {
        switch self {
        case .needsYou: return "hand.raised.fill"
        case .running: return "bolt.fill"
        case .done: return "checkmark.circle.fill"
        case .stopped: return "exclamationmark.triangle.fill"
        case .idle: return "moon.zzz.fill"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .needsYou: return .systemOrange
        case .running: return .systemBlue
        case .done: return .systemGreen
        case .stopped: return .systemRed
        case .idle: return .secondaryLabelColor
        }
    }
}

extension StatusReason {
    var symbol: String {
        switch self {
        case .question: return "questionmark.bubble.fill"
        case .planApproval: return "list.bullet.clipboard.fill"
        case .permission: return "lock.shield.fill"
        case .working: return "bolt.circle.fill"
        case .starting: return "hourglass.circle.fill"
        case .finished: return "checkmark.circle.fill"
        case .interrupted: return "stop.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .unresponsive: return "exclamationmark.triangle.fill"
        case .idle: return "moon.zzz.fill"
        }
    }

    var color: Color {
        switch self {
        case .question, .planApproval, .permission: return .orange
        case .working, .starting: return .blue
        case .finished: return .green
        case .interrupted: return .gray
        case .failed: return .red
        case .unresponsive: return .yellow
        case .idle: return .secondary
        }
    }
}

extension SessionSnapshot {
    /// Symbol and tint for a row; idle rows keep their last state's symbol, greyed out.
    var rowSymbol: String { reason.symbol }
    var rowColor: Color { phase == .idle ? .secondary : reason.color }

    var subtitle: String {
        var parts = [headline]
        if let projectName, !projectName.isEmpty { parts.append(projectName) } else if isChat { parts.append("Chat") }
        return parts.joined(separator: " · ")
    }
}
