// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Markup",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Markup", targets: ["Markup"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.1")
    ],
    targets: [
        .executableTarget(
            name: "Markup",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Markup",
            exclude: [
                "Markup.entitlements"
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
