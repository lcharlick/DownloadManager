//
//  ViewModel.swift
//  Example
//
//  Created by Lachlan Charlick on 19/3/21.
//

import DownloadManager
import Foundation

protocol ViewModelType: ObservableObject {
    var status: DownloadStatus { get }
    var queue: [Download] { get }

    var progress: DownloadProgress { get }
    var throughput: Int { get }
    var estimatedTimeRemaining: TimeInterval? { get }

    func pause(_ download: Download)
    func resume(_ download: Download)
    func cancel(_ downloads: Set<Download.ID>)
    func cancel(at offsets: IndexSet)
}

class ViewModel: ViewModelType, ObservableObject {
    @Published var status: DownloadStatus
    @Published var queue = [Download]()
    let progress: DownloadProgress

    @Published var throughput: Int = 0
    var estimatedTimeRemaining: TimeInterval?

    private let manager: DownloadManager

    private var observation: NSKeyValueObservation?

    private var resumeData = [Download.ID: Data]()

    init(manager: DownloadManager = .init(sessionConfiguration: .default)) {
        self.manager = manager
        status = manager.state.status
        progress = manager.state.progress
        manager.delegate = self

        /*
         self.observation = _progress.observe(\.fractionCompleted) { [weak self] progress, _ in
             guard let self = self else { return }
             DispatchQueue.main.async {
                 self.progress.totalUnitCount = progress.totalUnitCount
                 self.progress.completedUnitCount = min(
                     Int64(Double(progress.totalUnitCount)*progress.fractionCompleted),
                     progress.totalUnitCount
                 )
             }
         }
         */
    }

    func download(_ items: [Item]) {
        let downloads = items.map {
            Download(url: $0.url, progress: DownloadProgress(expected: $0.estimatedSize))
        }
        manager.append(downloads)
    }

    func pause(_ download: Download) {
        manager.pause(download)
    }

    func resume(_ download: Download) {
        manager.resume(download)
    }

    func cancel(_ ids: Set<Download.ID>) {
        let downloads = ids.compactMap(manager.download(with:))
        manager.remove(Set(downloads))
    }

    func cancel(at offsets: IndexSet) {
        let downloads = offsets.map { queue[$0] }
        manager.remove(Set(downloads))
    }

    struct Item {
        let id: Int
        let url: URL
        let estimatedSize: Int
    }
}

extension ViewModel: DownloadManagerDelegate {
    func downloadQueueDidChange(_ items: [Download]) {
        print("queue changed (\(items.count))")
        queue = items
    }

    func downloadManagerStatusDidChange(_ status: DownloadStatus) {
        print("status changed: \(status)")
        self.status = status
    }

    func downloadDidUpdateProgress(_: Download) {
        // print("progress updated: \(download.progress.fractionCompleted)")
    }

    func downloadThroughputDidChange(_ throughput: Int) {
        self.throughput = throughput
        if throughput > 0 {
            estimatedTimeRemaining = Double(progress.expected - progress.received) / Double(throughput)
        } else {
            estimatedTimeRemaining = nil
        }
    }

    func downloadStatusDidChange(_ download: Download) {
        print("status changed for item: \(download.id)")
        download.objectWillChange.send()
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
