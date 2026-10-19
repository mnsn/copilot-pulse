import os

/// Diagnostics: `log show --last 10m --predicate 'subsystem == "com.asaf.CopilotPulse"'`
enum Log {
    static let app = Logger(subsystem: "com.asaf.CopilotPulse", category: "app")
}
