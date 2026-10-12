// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ProShowCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "ProShowCore", targets: ["ProShowCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/AudioKit/AudioKit.git", from: "5.6.1"),
        .package(url: "https://github.com/AudioKit/AudioKitUI.git", from: "0.3.6"),
        .package(url: "https://github.com/AudioKit/Controls.git", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "ProShowCore",
            dependencies: [
                .product(name: "AudioKit", package: "AudioKit"),
                .product(name: "AudioKitUI", package: "AudioKitUI"),
                .product(name: "Controls", package: "Controls"),
            ],
            path: "ProShow",
            exclude: [
                "App",
                "Features",
                "Resources",
                "Services/ChromaKeyFilter.metal",
                "Services/TransitionShaders.metal",
                "ProShow.entitlements",
                "ProShowDeveloperID.entitlements",
            ],
            sources: [
                "Models",
                "Services",
                "Shared",
            ]
        ),
        .testTarget(
            name: "ProShowCoreTests",
            dependencies: ["ProShowCore"],
            path: "Tests/ProShowCoreTests"
        ),
    ]
)
