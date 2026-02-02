// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CloudMount",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess", from: "4.2.2"),
    ],
    targets: [
        .executableTarget(
            name: "CloudMount",
            dependencies: [
                .product(name: "KeychainAccess", package: "KeychainAccess"),
            ],
            path: "Sources/CloudMount",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
    ]
)
