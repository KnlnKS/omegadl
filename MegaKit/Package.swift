// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MegaKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MegaKit", targets: ["MegaKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt", from: "5.3.0")
    ],
    targets: [
        .target(
            name: "MegaKit",
            dependencies: [.product(name: "BigInt", package: "BigInt")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MegaKitTests",
            dependencies: ["MegaKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
