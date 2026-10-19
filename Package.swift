// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopilotPulse",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "CopilotPulse", targets: ["CopilotPulse"]),
    ],
    targets: [
        .target(
            name: "PulseCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "CopilotPulse",
            dependencies: ["PulseCore"]
        ),
        .testTarget(
            name: "PulseCoreTests",
            dependencies: ["PulseCore"]
        ),
    ]
)
