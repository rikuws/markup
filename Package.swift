// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Markup",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Markup", targets: ["Markup"])
    ],
    targets: [
        .executableTarget(
            name: "Markup",
            path: "Sources/Markup",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
