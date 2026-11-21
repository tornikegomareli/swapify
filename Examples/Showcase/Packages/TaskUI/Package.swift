// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaskUI",
    platforms: [.iOS("27.0")],
    products: [.library(name: "TaskUI", targets: ["TaskUI"])],
    targets: [.target(name: "TaskUI")]
)
