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
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5")
    ],
    targets: [
        .executableTarget(
            name: "Markup",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/Markup",
            exclude: [
                "Markup.entitlements",
                "Info.plist"
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
