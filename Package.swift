// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "DownloadManager",
    platforms: [.macOS(.v11), .iOS(.v14), .watchOS(.v7)],
    products: [
        .library(
            name: "DownloadManager",
            targets: ["DownloadManager"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/krzysztofzablocki/Difference.git", branch: "master"),
        .package(url: "https://github.com/httpswift/swifter.git", branch: "stable"),
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
                .product(name: "Swifter", package: "swifter")
            ]
        ),
    ]
)
