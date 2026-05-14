// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "threadline-overlay",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "threadline-overlay",
            path: "Sources/threadline-overlay",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
