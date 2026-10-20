// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopilotPulse",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "CopilotPulse", targets: ["CopilotPulse"]),
    ],
    dependencies: [
        // In-app updates. Only the app target uses it; PulseCore and its tests don't.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "PulseCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "CopilotPulse",
            dependencies: [
                "PulseCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // scripts/build-app.sh embeds Sparkle.framework in the app's Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "PulseCoreTests",
            dependencies: ["PulseCore"]
        ),
    ]
)
