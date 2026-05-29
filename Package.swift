// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowGrid",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.2"),
    ],
    targets: [
        .executableTarget(
            name: "WindowGrid",
            path: "Sources/WindowGrid",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
