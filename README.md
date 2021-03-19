# DownloadManager

A `URLSession`-based download manager in Swift.

## Features

- Support for background `URLSession`s
- Downloads are pausable and cancellable
- Progress can be tracked for the entire download manager, individual downloads, or a subset of downloads
- Support for concurrent downloads
- Easy integration with SwiftUI (see example project)
- No external dependencies

## Installation

### Swift Package Manager

Create a `Package.swift` file.

```swift
import PackageDescription

let package = Package(
    name: "SampleProject",
    dependencies: [
        .Package(url: "https://github.com/lcharlick/DownloadManager.git" from: "1.0.0")
    ]
)
```
