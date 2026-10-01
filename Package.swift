// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Prancheta",
    platforms: [.macOS(.v27)],
    targets: [
        .executableTarget(name: "Prancheta", linkerSettings: [.linkedLibrary("sqlite3")])
    ]
)
