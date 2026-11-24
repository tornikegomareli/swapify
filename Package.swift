// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swapify",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "swapify", targets: ["swapify"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
    ],
    targets: [
        .target(name: "SwapifyCore"),
        .executableTarget(
            name: "swapify",
            dependencies: [
                "SwapifyCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "SwapifyCoreTests", dependencies: ["SwapifyCore"], exclude: ["Fixtures"]),
    ]
)
