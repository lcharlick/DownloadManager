//
//  ViewModel.swift
//  Example
//
//  Created by Lachlan Charlick on 19/3/21.
//

import Foundation
import DownloadManager

protocol ViewModelType: ObservableObject {
    var status: DownloadState.Status { get }
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
    @Published var status: DownloadState.Status
    @Published var queue = [Download]()
    let progress: DownloadProgress

    @Published var throughput: Int = 0
    var estimatedTimeRemaining: TimeInterval?

    private let manager: DownloadManager

    private var observation: NSKeyValueObservation?

    private var resumeData = [Download.ID: Data]()

    init(manager: DownloadManager = .init(sessionConfiguration: .default)) {
        self.manager = manager
        self.status = manager.state.status
        self.progress = manager.state.progress
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

    /// Placeholder for Prism `Item`.
    struct Item {
        let id: Int
        let url: URL
        let estimatedSize: Int
    }
}

extension ViewModel: DownloadManagerDelegate {
    func downloadQueueDidChange(_ items: [Download]) {
        print("queue changed (\(items.count))")
        self.queue = items
    }

    func downloadManagerStatusDidChange(_ status: DownloadState.Status) {
        print("status changed: \(status)")
        self.status = status
    }

    func downloadDidUpdateProgress(_ download: Download) {
//        print("progress updated: \(download.progress.fractionCompleted)")
    }

    func downloadThroughputDidChange(_ throughput: Int) {
        self.throughput = throughput
        if throughput > 0 {
            self.estimatedTimeRemaining = Double(progress.expected - progress.received)/Double(throughput)
        } else {
            self.estimatedTimeRemaining = nil
        }
    }

    func downloadStatusDidChange(_ download: Download) {
        print("status changed for item: \(download.id)")
        download.objectWillChange.send()
    }

    func download(_ download: Download, didCreateTask: URLSessionDownloadTask) {
        print("created task for url: \(download.url)")
    }

    func download(_ download: Download, didReconnectTask: URLSessionDownloadTask) {

    }

    func download(_ download: Download, didCancelWithResumeData data: Data?) {
        if let data = data {
            print("saving \(data.count) bytes of resume data for download: \(download.id)")
        }

        resumeData[download.id] = data
    }

    func resumeDataForDownload(_ download: Download) -> Data? {
        resumeData[download.id]
    }

    func download(_ download: Download, didFinishDownloadingTo location: URL) {
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
        progress.completedUnitCount = Int64(100.0*fraction)
        progress.totalUnitCount = totalUnitCount
        return progress
    }
}
