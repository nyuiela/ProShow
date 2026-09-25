// swift-tools-version: 5.9
// Optional SwiftPM layout for shared models/services.
// Prefer opening ProShow.xcodeproj in Xcode for the full multiplatform app.
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
    targets: [
        .target(
            name: "ProShowCore",
            path: "ProShow",
            sources: [
                "Models",
                "Services",
                "Shared",
            ]
        ),
    ]
)
