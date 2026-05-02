// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GhosttyLabels",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ghostty-labels", targets: ["GhosttyLabels"])
    ],
    targets: [
        .executableTarget(name: "GhosttyLabels")
    ]
)
