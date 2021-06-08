//
//  DownloadManager.swift
//  DownloadManager
//
//  Created by Lachlan Charlick on 26/2/21.
//

import Foundation

/// Manages a queue of http download tasks.
public class DownloadManager: NSObject {
    lazy var queue = DownloadQueue(
        delegate: self
    )

    private(set) public var state = DownloadState()

    private let sessionConfiguration: URLSessionConfiguration
    private lazy var session = URLSession(
        configuration: sessionConfiguration,
        delegate: self,
        delegateQueue: nil
    )

    public weak var delegate: DownloadManagerDelegate?

    /// The maximum number of downloads that can simultaneously have the `downloading` status.
    public var maxConcurrentDownloads: Int = 1 {
        didSet {
            queue.maxConcurrentDownloads = maxConcurrentDownloads
        }
    }

    /// The time the last throughput value was calculated.
    /// Used to calculate a rolling average.
    private var lastThroughputCalculationTime = Date()
    /// The progress`s unitCount value at the time the throughput value was last calculated.
    /// Used to calculate a rolling average.
    private var lastThroughputUnitCount: Double = 0

    @Atomic
    private var tasks = [Download.ID: URLSessionDownloadTask]()

    @Atomic
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

        self.downloadStatusChangedObservation = NotificationCenter.default.addObserver(
            forName: .downloadStatusChanged,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let download = notification.object as? Download else {
                return
            }
            self?.handleDownloadStatusChanged(download)
        }
    }

    /// Reattach any outstanding tasks from a previous launch.
    public func attachOutstandingDownloadTasks(
        queue: DispatchQueue = .main,
        completionHandler: @escaping (Int) -> Void
    ) {
        session.getAllTasks { [weak self] tasks in
            queue.async {
                let downloadTasks = tasks.compactMap {
                    $0 as? URLSessionDownloadTask
                }
                self?.registerTasks(downloadTasks)
                completionHandler(downloadTasks.count)
            }
        }
    }

    private func handleDownloadStatusChanged(_ download: Download) {
        queue.update()
        updateStatus()
        delegate?.downloadStatusDidChange(download)
    }

    /// Calculate the queue status and update if it has changed.
    private func updateStatus() {
        let newStatus = Self.calculateStatus(for: queue.downloads)
        if newStatus != state.status {
            if newStatus == .downloading {
                startMonitoringThroughput()
            } else if state.status == .downloading {
                stopMonitoringThroughput()
            }

            self.state.status = newStatus
            delegate?.downloadManagerStatusDidChange(state.status)
        }
    }

    /// Calculate the aggregate status for a subset of downloads in the queue.
    public static func calculateStatus(for downloads: [Download]) -> DownloadState.Status {
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

        let errors = downloadsByStatus.reduce(into: Set<DownloadState.Error>()) { errors, value in
            switch value.key {
            case .failed(let error):
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
    public static func progress(of downloads: [Download]) -> DownloadProgress {
        let progress = DownloadProgress(children: downloads.map {
            $0.progress
        })
        return progress
    }

    /// Calculate the state of a subset of downloads in the queue.
    public static func state(of downloads: [Download]) -> DownloadState {
        .init(
            status: Self.calculateStatus(for: downloads),
            progress: Self.progress(of: downloads)
        )
    }

    /// Adds one or more downloads to the end of the download queue.
    public func append(_ downloads: [Download]) {
        for download in downloads {
            let task = tasks[download.id] ?? createTask(for: download)
            tasks[download.id] = task
            delegate?.download(download, didCreateTask: task)
        }
        state.progress.addChildren(downloads.map { $0.progress })
        queue.append(downloads)
    }

    /// Adds one or more downloads to the end of the download queue.
    public func append(_ downloads: Download...) {
        append(downloads)
    }

    /// Fetch a download from the queue with the given id.
    /// - Parameter id: The id of the download to fetch.
    /// - Returns: A queued download, if one exists.
    public func download(with id: Download.ID) -> Download? {
        queue.download(with: id)
    }

    /// Remove one or more downloads from the queue. Any in-progress session tasks will be cancelled.
    public func remove(_ downloads: Set<Download>) {
        for download in downloads {
            cancelTask(for: download)
        }
        state.progress.removeChildren(downloads.map { $0.progress })
        queue.remove(downloads)
    }

    /// Remove one or more downloads from the queue. Any in-progress session tasks will be cancelled.
    public func remove(_ downloads: Download...) {
        remove(Set(downloads))
    }

    /// Pause a queued download. The underlying download task will be cancelled, but the download won't be removed from the queue,
    /// and can be resumed at a later time.
    /// If supported, the delegate will receive resume data via the `didCancelWithResumeData` method.
    /// See https://developer.apple.com/documentation/foundation/url_loading_system/pausing_and_resuming_downloads for more information.
    public func pause(_ download: Download) {
        guard download.status != .finished else { return }
        download.status = .paused
        cancelTask(for: download)
    }

    /// Resume a paused or failed download.
    public func resume(_ download: Download) {
        guard download.status != .finished else { return }
        let task = createTask(for: download)
        tasks[download.id] = task
        delegate?.download(download, didCreateTask: task)
        download.status = .idle
    }

    /// Updates a download with a new request object, e.g. if the URL has changed.
    /// Any existing download task will be cancelled and replaced with a fresh task using the new request.
    /// If supported, the delegate will receive resume data via the `didCancelWithResumeData` method.
    /// - Parameters:
    ///   - download: The download to update.
    ///   - request: The new request object.
    public func update(_ download: Download, with request: URLRequest) {
        if let task = tasks[download.id] {
            task.cancel()
            taskIdentifiers[task.taskIdentifier] = nil
        }
        download.request = request
        let newTask = createTask(for: download)
        tasks[download.id] = newTask
        taskIdentifiers[newTask.taskIdentifier] = download
        delegate?.download(download, didCreateTask: newTask)
    }

    enum Constants {
        static let acceptableStatusCodes = Set(200..<300)
    }
}

// MARK: - Task Management.

private extension DownloadManager {
    func registerTasks(_ tasks: [URLSessionDownloadTask]) {
        var downloads = [Download]()
        for task in tasks {
            guard let request = task.currentRequest else {
                continue
            }
            let download = Download(request: request, progress: .init())
            delegate?.download(download, didReconnectTask: task)
            downloads.append(download)
        }

        if !downloads.isEmpty {
            append(downloads)
        }
    }

    func createTask(for download: Download) -> URLSessionDownloadTask {
        let task: URLSessionDownloadTask
        // Check if the delegate has resume data for this download.
        if let resumeData = delegate?.resumeDataForDownload(download) {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: download.request)
            task.countOfBytesClientExpectsToReceive = Int64(download.progress.expected)
        }
        taskIdentifiers[task.taskIdentifier] = download
        return task
    }

    func cancelTask(for download: Download) {
        guard let task = tasks[download.id] else {
            return
        }
        task.cancel { [weak self] data in
            self?.delegate?.download(download, didCancelWithResumeData: data)
            self?.tasks[download.id] = nil
            self?.taskIdentifiers[task.taskIdentifier] = nil
        }
    }
}

// MARK: - Throughput.

private extension DownloadManager {
    func startMonitoringThroughput() {
        self.lastThroughputCalculationTime = Date()
        self.lastThroughputUnitCount = Double(state.progress.expected)*state.progress.fractionCompleted

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateThroughput()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopMonitoringThroughput() {
        timer?.invalidate()
        delegate?.downloadThroughputDidChange(0)
    }

    func updateThroughput() {
        let now = Date()
        let unitCount = Double(state.progress.expected)*state.progress.fractionCompleted
        let unitCountDelta = unitCount - lastThroughputUnitCount
        let timeDelta = now.timeIntervalSince(lastThroughputCalculationTime)
        let throughput = Int(Double(unitCountDelta)/timeDelta)
        delegate?.downloadThroughputDidChange(throughput)
        self.lastThroughputCalculationTime = now
        self.lastThroughputUnitCount = unitCount
    }
}

// MARK: - DownloadQueueDelegate.

extension DownloadManager: DownloadQueueDelegate {
    func queueDidChange() {
        updateStatus()
        delegate?.downloadQueueDidChange(queue.downloads)
    }

    func downloadShouldBeginDownloading(_ download: Download) {
        tasks[download.id]?.resume()
        download.status = .downloading
    }
}

// MARK: - URLSessionDownloadDelegate.

extension DownloadManager: URLSessionDownloadDelegate {
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let download = taskIdentifiers[task.taskIdentifier] else {
            return
        }

        if let error = error as NSError? {
            // Client error.
            if error.domain == NSURLErrorDomain {
                let urlError = URLError(URLError.Code(rawValue: error.code))
                // Don't consider cancellation a failure.
                if urlError.code != .cancelled {
                    DispatchQueue.main.async {
                        download.status = .failed(.transportError(urlError, localizedDescription: error.localizedDescription))
                    }
                }
            } else {
                DispatchQueue.main.async {
                    download.status = .failed(.unknown(code: error.code, localizedDescription: error.localizedDescription))
                }
            }
            return
        }

        guard let response = task.response as? HTTPURLResponse else {
            return
        }

        if !Constants.acceptableStatusCodes.contains(response.statusCode) {
            DispatchQueue.main.async {
                download.status = .failed(.serverError(statusCode: response.statusCode))
            }
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let download = taskIdentifiers[downloadTask.taskIdentifier] else {
            downloadTask.cancel()
            return
        }

        DispatchQueue.main.async {
            download.progress.received = Int(totalBytesWritten)
            download.progress.expected = Int(totalBytesExpectedToWrite)
            self.delegate?.downloadDidUpdateProgress(download)
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let download = taskIdentifiers[downloadTask.taskIdentifier] else {
//            assertionFailure("Download not found for url: \(url)")
            return
        }

        delegate?.download(download, didFinishDownloadingTo: location)

        DispatchQueue.main.async {
            download.status = .finished
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            for (id, task) in self.tasks {
                guard let download = self.queue.download(with: id) else {
                    return
                }
                download.progress.received = Int(task.countOfBytesReceived)
            }
            self.delegate?.downloadManagerDidFinishBackgroundDownloads()
        }
    }
}
