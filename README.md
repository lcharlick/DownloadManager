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


## Shared queue and platform backends (development branch)

`DownloadManager(backend:delegate:queueFile:executionEnabled:)` owns the ordered queue,
concurrency slots, progress and persisted user pause state. `DownloadQueueFile` saves a
versioned JSON document with atomic replacement. It stores IDs, application context,
state and counters; requests and credentials are not serialized. Native backends request
fresh credentials before an attempt by default. Apple's backend reuses its prepared or
reattached URLSession request so offline relaunch does not require a server probe;
explicit request updates still fence the old attempt and validate the resume fingerprint.
A delegate may throw `DownloadPreparationError.temporarilyUnavailable` to leave work
queued, with a bounded retry while the process is active. Hosts may also call
`retryPendingDownloads()` when connectivity changes.

`DownloadBackend` owns transfer I/O. Apple callers can continue using
`DownloadManager(sessionConfiguration:delegate:queueFile:)`; its backend uses background
URLSession and reconnects tasks by download/attempt UUID. The application must keep the
same background session identifier and forward background-session completion normally.
Non-Apple hosts inject a native backend and enable execution only while the platform
permits background work. No URLSession background emulation is used on Android.

Backends send progress, failure and completion events with the attempt UUID. Old attempt
callbacks are rejected. A completed file must remain available until `completed` returns
true. Implement `finalizeDownload` to throw when application storage fails; the queue
retains the completion location for retry. Existing non-throwing completion callbacks
remain supported through the default implementation. Queue mutations retain the existing
non-throwing API; hosts needing confirmed persistence call `checkPersistence()` afterward.

Call `restore()` before enabling a persisted queue. Restore is shared across concurrent
callers. Corrupt queue documents are preserved and block execution instead of being
silently overwritten. Native checkpoint persistence belongs to the backend, independently
of this queue JSON. Use a durable private directory, not an evictable cache.

Apple upgrade tests cover unchanged requests on reattached suspended tasks, cancellation
of rejected legacy tasks, and a legacy completion delivered before `restore()`. Callback
registration shares the same coordinator queue as explicit restoration. These host tests
do not replace testing a real background-session relaunch across an app upgrade on iOS.
