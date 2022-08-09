//
//  DownloadManager.swift
//  DownloadManager
//
//  Created by Lachlan Charlick on 26/2/21.
//

import Foundation

/// Manages a queue of http download tasks.
public actor DownloadManager: NSObject {
    lazy var queue = DownloadQueue(delegate: self)

    private(set) public var progress: DownloadProgress

    public var status: DownloadStatus {
        get async {
            let downloads = await queue.downloads
            return await Self.calculateStatus(for: downloads)
        }
    }

    private let sessionConfiguration: URLSessionConfiguration
    private lazy var session = URLSession(
        configuration: sessionConfiguration,
        delegate: self,
        delegateQueue: nil
    )

    private(set) public weak var delegate: DownloadManagerDelegate?

    public func setDelegate(_ delegate: DownloadManagerDelegate?) {
        self.delegate = delegate
    }

    /// The maximum number of downloads that can simultaneously have the `downloading` status.
    private(set) public var maxConcurrentDownloads: Int = 1

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
    @MainActor public init(
        sessionConfiguration: URLSessionConfiguration,
        delegate: DownloadManagerDelegate? = nil
    ) {
        self.progress = .init()
        self.sessionConfiguration = sessionConfiguration
        self.delegate = delegate
        super.init()

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
            Task {
                let downloadTasks = tasks.compactMap {
                    $0 as? URLSessionDownloadTask
                }
                await self.registerTasks(downloadTasks)
                completionHandler(downloadTasks.count)
            }
        }
    }

    private func handleDownloadStatusChanged(_ download: Download) async {
        await queue.update()
        await delegate?.downloadStatusDidChange(download)

        if await self.status == .downloading {
            await startMonitoringThroughput()
        } else {
            await stopMonitoringThroughput()
        }
    }

    /// Calculate the queue status and update if it has changed.
//    private func updateStatus() async {
//        let newStatus = await Self.calculateStatus(for: queue.downloads)
//        if newStatus != state.status {
//            if newStatus == .downloading {
//                startMonitoringThroughput()
//            } else if state.status == .downloading {
//                stopMonitoringThroughput()
//            }
//
//            state.status = newStatus
//            delegate?.downloadManagerStatusDidChange(state.status)
//        }
//    }

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

    /// Calculate the progress of a subset of downloads in the queue.
    @MainActor public static func progress(of downloads: [Download]) -> DownloadProgress {
        let progress = DownloadProgress(children: downloads.map(\.progress))
        return progress
    }

    /// Calculate the state of a subset of downloads in the queue.
    @MainActor public static func state(of downloads: [Download]) -> (status: DownloadStatus, progress: DownloadProgress) {
        (
            status: Self.calculateStatus(for: downloads),
            progress: Self.progress(of: downloads)
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
        await progress.addChildren(downloads.map(\.progress))
        await queue.append(downloads)
    }

    /// Adds one or more downloads to the end of the download queue.
    public func append(_ downloads: Download...) async {
        await append(downloads)
    }

    /// Fetch a download from the queue with the given id.
    /// - Parameter id: The id of the download to fetch.
    /// - Returns: A queued download, if one exists.
    public func download(with id: Download.ID) async -> Download? {
        await queue.download(with: id)
    }

    /// Remove one or more downloads from the queue. Any in-progress session tasks will be cancelled.
    public func remove(_ downloads: Set<Download>) async {
        for download in downloads {
            await cancelTask(for: download)
        }
        await progress.removeChildren(downloads.map(\.progress))
        await queue.remove(downloads)
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
        guard await download.status != .finished else { return }
        await download.setStatus(.paused)
        await cancelTask(for: download)
    }

    /// Resume a paused or failed download.
    public func resume(_ download: Download) async {
        guard await download.status != .finished else { return }
        let task = await createTask(for: download)
        tasks[download.id] = task
        await delegate?.download(download, didCreateTask: task)
        await download.setStatus(.idle)
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
        await download.setRequest(request)
        let newTask = await createTask(for: download)
        tasks[download.id] = newTask
        taskIdentifiers[newTask.taskIdentifier] = download
        await delegate?.download(download, didCreateTask: newTask)
    }

    enum Constants {
        static let acceptableStatusCodes = Set(200 ..< 300)
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
            let download = await Download(request: request, progress: .init())
            await delegate?.download(download, didReconnectTask: task)
            downloads.append(download)
        }

        if !downloads.isEmpty {
            await self.append(downloads)
        }
    }

    func createTask(for download: Download) async -> URLSessionDownloadTask {
        let task: URLSessionDownloadTask
        // Check if the delegate has resume data for this download.
        if let resumeData = await delegate?.resumeDataForDownload(download) {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = await session.downloadTask(with: download.request)
            task.countOfBytesClientExpectsToReceive = await Int64(download.progress.expected)
        }
        taskIdentifiers[task.taskIdentifier] = download
        return task
    }

    func cancelTask(for download: Download) async {
        guard let task = tasks[download.id] else {
            return
        }

        let data = await task.cancelByProducingResumeData()

        await self.delegate?.download(download, didCancelWithResumeData: data)
        self.tasks[download.id] = nil
        self.taskIdentifiers[task.taskIdentifier] = nil
    }
}

// MARK: - Throughput.

private extension DownloadManager {
    func startMonitoringThroughput() async {
        guard timer == nil else { return }
        lastThroughputCalculationTime = Date()
        lastThroughputUnitCount = await Double(progress.expected) * progress.fractionCompleted

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                await self.updateThroughput()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopMonitoringThroughput() async {
        timer?.invalidate()
        timer = nil
        await delegate?.downloadThroughputDidChange(0)
    }

    func updateThroughput() async {
        let now = Date()
        let unitCount = await Double(progress.expected) * progress.fractionCompleted
        let unitCountDelta = unitCount - lastThroughputUnitCount
        let timeDelta = now.timeIntervalSince(lastThroughputCalculationTime)
        let throughput = Int(Double(unitCountDelta) / timeDelta)
        await delegate?.downloadThroughputDidChange(throughput)
        lastThroughputCalculationTime = now
        lastThroughputUnitCount = unitCount
    }
}

// MARK: - DownloadQueueDelegate.

extension DownloadManager: DownloadQueueDelegate {
    func queueDidChange() async {
        await delegate?.downloadQueueDidChange(queue.downloads)
    }

    func downloadShouldBeginDownloading(_ download: Download) async {
        tasks[download.id]?.resume()
        await download.setStatus(.downloading)
    }
}

// MARK: - URLSessionDownloadDelegate.

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated public func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        Task { @MainActor in
            guard let download = await self.taskIdentifiers[task.taskIdentifier] else {
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

    nonisolated public func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            guard let download = await self.taskIdentifiers[downloadTask.taskIdentifier] else {
                downloadTask.cancel()
                return
            }

            download.progress.received = Int(totalBytesWritten)
            download.progress.expected = Int(totalBytesExpectedToWrite)
            await self.delegate?.downloadDidUpdateProgress(download)
        }
    }

    nonisolated public func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        Task { @MainActor in
            guard let download = await self.taskIdentifiers[downloadTask.taskIdentifier],
                  let response = downloadTask.response as? HTTPURLResponse,
                  Constants.acceptableStatusCodes.contains(response.statusCode)
            else {
                return
            }

            await self.delegate?.download(download, didFinishDownloadingTo: location)

            download.setStatus(.finished)
        }
    }

    nonisolated public func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        Task { @MainActor in
            for (id, task) in await self.tasks {
                guard let download = await self.queue.download(with: id) else {
                    return
                }
                download.progress.received = Int(task.countOfBytesReceived)
            }
            await self.delegate?.downloadManagerDidFinishBackgroundDownloads()
        }
    }
}
