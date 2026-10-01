// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Prancheta",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(name: "Prancheta", linkerSettings: [.linkedLibrary("sqlite3")])
    ]
)
