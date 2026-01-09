//
//  ViewModel.swift
//  Example
//
//  Created by Lachlan Charlick on 19/3/21.
//

import DownloadManager
import Foundation

protocol ViewModelType: Observable {
    var status: DownloadStatus { get }
    var queue: [Download] { get }

    var fractionCompleted: Double { get }
    var totalExpected: Int64 { get }
    var totalReceived: Int64 { get }
    var throughput: Int { get }
    var estimatedTimeRemaining: TimeInterval? { get }

    func pause(_ download: Download)
    func resume(_ download: Download)
    func cancel(_ downloads: Set<Download.ID>)
    func cancel(at offsets: IndexSet)
}

@Observable
class ViewModel: ViewModelType {
    var status: DownloadStatus
    var queue = [Download]()

    var fractionCompleted: Double {
        manager.fractionCompleted
    }

    var totalExpected: Int64 {
        manager.totalExpected
    }

    var totalReceived: Int64 {
        manager.totalReceived
    }

    var throughput: Int = 0
    var estimatedTimeRemaining: TimeInterval?

    private let manager: DownloadManager

    private var observation: NSKeyValueObservation?

    private var resumeData = [Download.ID: Data]()

    init(manager: DownloadManager = .init(sessionConfiguration: .default)) {
        self.manager = manager
        status = manager.status
        Task {
            await manager.setDelegate(self)
        }
    }

    func download(_ items: [Item]) async {
        let downloads = items.map {
            Download(url: $0.url, expected: Int64($0.estimatedSize))
        }
        await manager.append(downloads)
    }

    func pause(_ download: Download) {
        Task {
            await manager.pause(download)
        }
    }

    func resume(_ download: Download) {
        Task {
            await manager.resume(download)
        }
    }

    func cancel(_ ids: Set<Download.ID>) {
        let downloads = ids.compactMap(manager.download(with:))
        Task {
            await manager.remove(Set(downloads))
        }
    }

    func cancel(at offsets: IndexSet) {
        let downloads = offsets.map { queue[$0] }
        Task {
            await manager.remove(Set(downloads))
        }
    }

    struct Item {
        let id: Int
        let url: URL
        let estimatedSize: Int
    }
}

extension ViewModel: DownloadManagerDelegate {
    func downloadQueueDidChange(_ items: [Download]) async {
        print("queue changed (\(items.count))")
        queue = items
    }

    func downloadStatusDidChange(_ download: Download) async {
        print("status changed for item: \(download.id)")
        status = manager.status
    }

    func downloadDidUpdateProgress(_: Download) async {
        // Progress updates are automatically handled by @Observable
    }

    func downloadThroughputDidChange(_ throughput: Int) async {
        self.throughput = throughput
        if throughput > 0 {
            estimatedTimeRemaining = Double(totalExpected - totalReceived) / Double(throughput)
        } else {
            estimatedTimeRemaining = nil
        }
    }

    func download(_ download: Download, didCreateTask _: URLSessionDownloadTask) {
        print("created task for url: \(download.url)")
    }

    func download(_: Download, didReconnectTask _: URLSessionDownloadTask) {}

    func download(_ download: Download, didCancelWithResumeData data: Data?) {
        if let data = data {
            print("saving \(data.count) bytes of resume data for download: \(download.id)")
        }

        resumeData[download.id] = data
    }

    func resumeDataForDownload(_ download: Download) -> Data? {
        resumeData[download.id]
    }

    func download(_: Download, didFinishDownloadingTo _: URL) {
        // TODO: move file from temporary location.
    }

    func downloadManagerDidFinishBackgroundDownloads() {
        // TODO: call background completion handler.
    }
}

extension Progress {
    static func download(
        fraction: Double,
        totalUnitCount: Int64 = 0,
        throughput: Int? = nil
    ) -> Progress {
        let progress = Progress()
        progress.kind = .file
        progress.fileOperationKind = .downloading
        progress.throughput = throughput
        progress.completedUnitCount = Int64(100.0 * fraction)
        progress.totalUnitCount = totalUnitCount
        return progress
    }
}
