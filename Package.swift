// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "DownloadManager",
    platforms: [.macOS(.v10_15), .iOS(.v13), .watchOS(.v7)],
    products: [
        .library(
            name: "DownloadManager",
            targets: ["DownloadManager"]
        ),
    ],
    dependencies: [
        .package(name: "Difference", url: "https://github.com/krzysztofzablocki/Difference.git", .branch("master")),
        .package(name: "Swifter", url: "https://github.com/httpswift/swifter.git", .branch("stable")),
    ],
    targets: [
        .target(
            name: "DownloadManager",
            dependencies: []
        ),
        .testTarget(
            name: "DownloadManagerTests",
            dependencies: [
                "DownloadManager",
                "Difference",
                "Swifter",
            ]
        ),
    ]
)
