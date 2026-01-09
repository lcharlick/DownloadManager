//
//  DownloadManager.swift
//  DownloadManager
//
//  Created by Lachlan Charlick on 26/2/21.
//

import Foundation
import OSLog

let logger = Logger(subsystem: "me.charlick.download-manager", category: "default")

/// Manages a queue of http download tasks.
@Observable
@MainActor public class DownloadManager: NSObject {
    private var _downloads: [Download] = []
    private var cache = [Download.ID: Download]()

    public var downloads: [Download] {
        _downloads
    }

    public var fractionCompleted: Double {
        let totalExpected = _downloads.reduce(0) { $0 + $1.expected }
        let totalReceived = _downloads.reduce(0) { $0 + $1.received }
        return totalExpected > 0 ? Double(totalReceived) / Double(totalExpected) : 0
    }

    public var totalExpected: Int64 {
        _downloads.reduce(0) { $0 + $1.expected }
    }

    public var totalReceived: Int64 {
        _downloads.reduce(0) { $0 + $1.received }
    }

    public var status: DownloadStatus {
        return Self.calculateStatus(for: _downloads)
    }

    /// Current download throughput in bytes per second.
    /// Automatically updated during active downloads and reset to 0 when downloads complete.
    public private(set) var throughput: Int = 0

    private let sessionConfiguration: URLSessionConfiguration
    private var session: URLSession!

    public private(set) weak var delegate: DownloadManagerDelegate?

    public func setDelegate(_ delegate: DownloadManagerDelegate?) {
        self.delegate = delegate
    }

    /// The maximum number of downloads that can simultaneously have the `downloading` status.
    public private(set) var maxConcurrentDownloads: Int = 1

    public func setMaxConcurrentDownloads(_ value: Int) {
        maxConcurrentDownloads = value
    }

    /// The time the last throughput value was calculated.
    /// Used to calculate a rolling average.
    private var lastThroughputCalculationTime = Date()
    /// The progress`s unitCount value at the time the throughput value was last calculated.
    /// Used to calculate a rolling average.
    private var lastThroughputUnitCount: Double = 0

    private var tasks = [Download.ID: URLSessionDownloadTask]()

    private var taskIdentifiers = [Int: Download]()

    private var downloadStatusChangedObservation: NSObjectProtocol?

    private var timer: Timer?

    /// Creates a new download manager.
    /// - Parameters:
    ///   - sessionConfiguration: The `URLSession` configuration to use.
    ///   - delegate: The delegate instance for this download manager.
    public init(
        sessionConfiguration: URLSessionConfiguration,
        delegate: DownloadManagerDelegate? = nil
    ) {
        self.sessionConfiguration = sessionConfiguration
        self.delegate = delegate
        super.init()

        session = URLSession(
            configuration: sessionConfiguration,
            delegate: self,
            delegateQueue: nil
        )

        downloadStatusChangedObservation = NotificationCenter.default.addObserver(
            forName: .downloadStatusChanged,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self = self, let download = notification.object as? Download else {
                return
            }
            Task {
                await self.handleDownloadStatusChanged(download)
            }
        }
    }

    /// Reattach any outstanding tasks from a previous launch.
    public func attachOutstandingDownloadTasks(completionHandler: @escaping (Int) -> Void) {
        session.getAllTasks { tasks in
            Task { @MainActor in
                let downloadTasks = tasks.compactMap {
                    $0 as? URLSessionDownloadTask
                }
                await self.registerTasks(downloadTasks)
                completionHandler(downloadTasks.count)
            }
        }
    }

    private func handleDownloadStatusChanged(_ download: Download) async {
        updateQueue()
        await delegate?.downloadStatusDidChange(download)

        if status == .downloading {
            startMonitoringThroughput()
        } else {
            stopMonitoringThroughput()
        }
    }

    /// Calculate the aggregate status for a subset of downloads in the queue.
    @MainActor public static func calculateStatus(for downloads: [Download]) -> DownloadStatus {
        guard !downloads.isEmpty else {
            return .idle
        }

        let downloadsByStatus = Dictionary(grouping: downloads) {
            $0.status
        }

        if downloadsByStatus.count == 1 {
            return downloadsByStatus.first!.key
        }

        if downloadsByStatus[.downloading] != nil {
            return .downloading
        }

        if downloadsByStatus[.paused] != nil {
            return .paused
        }

        let errors = downloadsByStatus.reduce(into: Set<DownloadError>()) { errors, value in
            switch value.key {
            case let .failed(error):
                errors.insert(error)
            default:
                break
            }
        }

        if !errors.isEmpty {
            return .failed(.aggregate(errors: errors))
        }

        return .idle
    }

    /// Calculate the progress fraction of a subset of downloads.
    @MainActor public static func fractionCompleted(of downloads: [Download]) -> Double {
        let totalExpected = downloads.reduce(0) { $0 + $1.expected }
        let totalReceived = downloads.reduce(0) { $0 + $1.received }
        return totalExpected > 0 ? Double(totalReceived) / Double(totalExpected) : 0
    }

    /// Calculate the state of a subset of downloads in the queue.
    @MainActor public static func state(of downloads: [Download]) -> (status: DownloadStatus, fractionCompleted: Double, totalExpected: Int64, totalReceived: Int64) {
        let totalExpected = downloads.reduce(0) { $0 + $1.expected }
        let totalReceived = downloads.reduce(0) { $0 + $1.received }
        return (
            status: Self.calculateStatus(for: downloads),
            fractionCompleted: totalExpected > 0 ? Double(totalReceived) / Double(totalExpected) : 0,
            totalExpected: totalExpected,
            totalReceived: totalReceived
        )
    }

    /// Adds one or more downloads to the end of the download queue.
    public func append(_ downloads: [Download]) async {
        for download in downloads {
            let task: URLSessionDownloadTask
            if let cachedTask = tasks[download.id] {
                task = cachedTask
            } else {
                task = await createTask(for: download)
            }
            tasks[download.id] = task
            await delegate?.download(download, didCreateTask: task)
        }
        appendToQueue(downloads)
    }

    /// Adds one or more downloads to the end of the download queue.
    public func append(_ downloads: Download...) async {
        await append(Array(downloads))
    }

    /// Fetch a download from the queue with the given id.
    /// - Parameter id: The id of the download to fetch.
    /// - Returns: A queued download, if one exists.
    public func download(with id: Download.ID) -> Download? {
        cache[id]
    }

    /// Remove one or more downloads from the queue. Any in-progress session tasks will be cancelled.
    public func remove(_ downloads: Set<Download>) async {
        for download in downloads {
            await cancelTask(for: download)
        }
        removeFromQueue(downloads)
    }

    /// Remove one or more downloads from the queue. Any in-progress session tasks will be cancelled.
    public func remove(_ downloads: Download...) async {
        await remove(Set(downloads))
    }

    /// Pause a queued download. The underlying download task will be cancelled, but the download won't be removed from the queue,
    /// and can be resumed at a later time.
    /// If supported, the delegate will receive resume data via the `didCancelWithResumeData` method.
    /// See https://developer.apple.com/documentation/foundation/url_loading_system/pausing_and_resuming_downloads for more information.
    public func pause(_ download: Download) async {
        guard download.status != .finished else { return }
        download.setStatus(.paused)
        await cancelTask(for: download)
    }

    /// Resume a paused or failed download.
    public func resume(_ download: Download) async {
        guard download.status != .finished else { return }
        let task = await createTask(for: download)
        tasks[download.id] = task
        await delegate?.download(download, didCreateTask: task)
        download.setStatus(.idle)
    }

    /// Updates a download with a new request object, e.g. if the URL has changed.
    /// Any existing download task will be cancelled and replaced with a fresh task using the new request.
    /// If supported, the delegate will receive resume data via the `didCancelWithResumeData` method.
    /// - Parameters:
    ///   - download: The download to update.
    ///   - request: The new request object.
    public func update(_ download: Download, with request: URLRequest) async {
        if let task = tasks[download.id] {
            task.cancel()
            taskIdentifiers[task.taskIdentifier] = nil
        }
        download.setRequest(request)
        let newTask = await createTask(for: download)
        tasks[download.id] = newTask
        taskIdentifiers[newTask.taskIdentifier] = download
        await delegate?.download(download, didCreateTask: newTask)
    }

    enum Constants {
        static let acceptableStatusCodes = 200 ..< 300
    }
}

// MARK: - Queue Management

private extension DownloadManager {
    func appendToQueue(_ downloads: [Download]) {
        for download in downloads {
            _downloads.append(download)
            cache[download.id] = download
        }
        updateQueue()
        Task {
            await delegate?.downloadQueueDidChange(_downloads)
        }
    }

    func removeFromQueue(_ downloads: Set<Download>) {
        for download in downloads {
            cache[download.id] = nil
        }
        _downloads = _downloads.filter { !downloads.contains($0) }
        updateQueue()
        Task {
            await delegate?.downloadQueueDidChange(_downloads)
        }
    }

    func updateQueue() {
        var downloading = [Download]()
        var idle = [Download]()

        for download in _downloads {
            if download.status == .downloading {
                downloading.append(download)
            }
            if download.status == .idle {
                idle.append(download)
            }
        }

        let slotsAvailable = maxConcurrentDownloads - downloading.count

        guard downloading.count < maxConcurrentDownloads else {
            return
        }

        for download in idle.prefix(slotsAvailable) {
            tasks[download.id]?.resume()
            download.setStatus(.downloading)
        }
    }
}

// MARK: - Task Management.

private extension DownloadManager {
    func registerTasks(_ tasks: [URLSessionDownloadTask]) async {
        var downloads = [Download]()
        for task in tasks {
            guard let request = task.currentRequest else {
                continue
            }
            let download = Download(request: request)
            await delegate?.download(download, didReconnectTask: task)
            downloads.append(download)
        }

        if !downloads.isEmpty {
            await append(downloads)
        }
    }

    func createTask(for download: Download) async -> URLSessionDownloadTask {
        let task: URLSessionDownloadTask
        // Check if the delegate has resume data for this download.
        if let resumeData = await delegate?.resumeDataForDownload(download) {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: download.request)
            task.countOfBytesClientExpectsToReceive = download.expected
        }
        taskIdentifiers[task.taskIdentifier] = download
        return task
    }

    func cancelTask(for download: Download) async {
        guard let task = tasks[download.id] else {
            return
        }

        let data = await task.cancelByProducingResumeData()

        await delegate?.download(download, didCancelWithResumeData: data)
        tasks[download.id] = nil
        taskIdentifiers[task.taskIdentifier] = nil
    }
}

// MARK: - Throughput.

private extension DownloadManager {
    func startMonitoringThroughput() {
        guard timer == nil else { return }
        lastThroughputCalculationTime = Date()
        lastThroughputUnitCount = Double(totalExpected) * fractionCompleted

        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.updateThroughput()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopMonitoringThroughput() {
        timer?.invalidate()
        timer = nil

        // Reset throughput to 0 when monitoring stops
        throughput = 0

        // Notify delegate of the reset
        Task {
            await delegate?.downloadThroughputDidChange(0)
        }
    }

    func updateThroughput() {
        let now = Date()
        let unitCount = Double(totalExpected) * fractionCompleted
        let unitCountDelta = unitCount - lastThroughputUnitCount
        let timeDelta = now.timeIntervalSince(lastThroughputCalculationTime)
        let calculatedThroughput = Int(Double(unitCountDelta) / timeDelta)

        // Update the throughput property
        throughput = calculatedThroughput

        Task {
            await delegate?.downloadThroughputDidChange(calculatedThroughput)
        }
        lastThroughputCalculationTime = now
        lastThroughputUnitCount = unitCount
    }
}

// MARK: - URLSessionDownloadDelegate.

extension DownloadManager: URLSessionDownloadDelegate {
    public nonisolated func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        Task { @MainActor in
            guard let download = self.taskIdentifiers[task.taskIdentifier] else {
                return
            }

            if let error = error as NSError? {
                // Client error.
                if error.domain == NSURLErrorDomain {
                    let urlError = URLError(URLError.Code(rawValue: error.code))
                    // Don't consider cancellation a failure.
                    if urlError.code != .cancelled {
                        download.setStatus(.failed(.transportError(urlError, localizedDescription: error.localizedDescription)))
                    }
                } else {
                    download.setStatus(.failed(.unknown(code: error.code, localizedDescription: error.localizedDescription)))
                }
                return
            }

            guard let response = task.response as? HTTPURLResponse else {
                return
            }

            if !Constants.acceptableStatusCodes.contains(response.statusCode) {
                download.setStatus(.failed(.serverError(statusCode: response.statusCode)))
            }
        }
    }

    public nonisolated func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            guard let download = self.taskIdentifiers[downloadTask.taskIdentifier] else {
                downloadTask.cancel()
                return
            }

            download.received = totalBytesWritten
            download.expected = totalBytesExpectedToWrite
            await self.delegate?.downloadDidUpdateProgress(download)
        }
    }

    public nonisolated func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The file at `location` will be removed once this method exits, but we won't have told the delegate about it
        // by then since we need to jump threads.
        let tempLocation = FileManager.default.temporaryDirectory.appendingPathComponent(location.lastPathComponent)

        if FileManager.default.fileExists(atPath: location.path) {
            do {
                try FileManager.default.moveItem(at: location, to: tempLocation)
            } catch {
                logger.error("Failed to move download to temp directory: \(error.localizedDescription)")
                return
            }
        }

        Task { @MainActor in
            guard let download = self.taskIdentifiers[downloadTask.taskIdentifier],
                  let response = downloadTask.response as? HTTPURLResponse,
                  Constants.acceptableStatusCodes.contains(response.statusCode)
            else {
                return
            }

            await self.delegate?.download(download, didFinishDownloadingTo: tempLocation)

            // If the temporary file exists at this point, the delegate didn't move it.
            if FileManager.default.fileExists(atPath: tempLocation.path) {
                try? FileManager.default.removeItem(at: tempLocation)
            }

            download.setStatus(.finished)
        }
    }

    public nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        Task { @MainActor in
            for (id, task) in self.tasks {
                guard let download = self.cache[id] else {
                    return
                }
                download.received = task.countOfBytesReceived
            }
            await self.delegate?.downloadManagerDidFinishBackgroundDownloads()
        }
    }
}
