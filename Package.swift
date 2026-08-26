// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DownloadManager",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10)],
    products: [
        .library(
            name: "DownloadManager",
            targets: ["DownloadManager"]
        ),
        .library(
            name: "DownloadKit",
            targets: ["DownloadKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/krzysztofzablocki/Difference.git", branch: "master"),
        .package(url: "https://github.com/httpswift/swifter.git", branch: "stable"),
    ],
    targets: [
        .target(
            name: "DownloadKit",
            dependencies: [],
            path: "Sources/DownloadManager"
        ),
        .target(
            name: "DownloadManager",
            dependencies: ["DownloadKit"],
            path: "Sources/DownloadManagerCompatibility"
        ),
        .testTarget(
            name: "DownloadManagerTests",
            dependencies: [
                "DownloadKit",
                "Difference",
                .product(name: "Swifter", package: "swifter")
            ]
        ),
        .testTarget(
            name: "DownloadManagerCompatibilityTests",
            dependencies: ["DownloadManager"]
        ),
    ]
)
