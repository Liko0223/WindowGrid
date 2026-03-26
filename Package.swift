// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowGrid",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "WindowGrid",
            path: "Sources/WindowGrid",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
