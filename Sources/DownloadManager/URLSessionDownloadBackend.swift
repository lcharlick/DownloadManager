//
//  URLSessionDownloadBackend.swift
//  DownloadKit
//
//  Created by Lachlan Charlick on 13/9/2026.
//

#if !os(Android) && !os(Linux)
import Foundation
import CryptoKit

/// Apple transport, retaining the existing background session and delegate API.
@MainActor public final class URLSessionDownloadBackend: NSObject, DownloadBackend {
    public weak var events: (any DownloadBackendEvents)?
    weak var legacyDelegate: DownloadManagerDelegate?
    private var session: URLSession!
    private struct Transfer {
        let download: Download
        let attempt: UUID
        let task: URLSessionDownloadTask
    }
    private var transfers: [UUID: Transfer] = [:]
    private var identifiers: [Int: UUID] = [:]
    private var completions: [Task<Void, Never>] = []
    private var registrations: [Int: Task<Transfer?, Never>] = [:]
    private nonisolated let legacyStagingPrefix: String
    private nonisolated let stagingDirectory: URL

    public init(configuration: URLSessionConfiguration, stagingDirectory: URL? = nil) {
        let sessionIdentity = configuration.identifier ?? UUID().uuidString
        self.legacyStagingPrefix = "legacy-" + SHA256.hash(data: Data(sessionIdentity.utf8)).map { String(format: "%02x", $0) }.joined()
        self.stagingDirectory = stagingDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("DownloadKit/Completed", isDirectory: true)
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func requiresRequestRefresh(_ download: Download) -> Bool {
        // URLSession persists requests for running and suspended background tasks.
        // Reconnecting those tasks must not require a successful server probe.
        download.url.scheme == "about"
    }

    public func prepare(_ download: Download) async throws {
        if let transfer = transfers[download.id], transfer.attempt == download.attempt { return }
        await pause(download)
        let fields = (download.request.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }
        let requestBytes = try JSONEncoder().encode([download.url.absoluteString] + fields.flatMap { [$0.key, $0.value] })
        let fingerprint = SHA256.hash(data: requestBytes).map { String(format: "%02x", $0) }.joined()
        let previous = download.context["appleRequestFingerprint"]
        download.context["appleRequestFingerprint"] = fingerprint
        let task: URLSessionDownloadTask
        if (previous == nil || previous == fingerprint), let data = await legacyDelegate?.resumeDataForDownload(download) {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: download.request)
            task.countOfBytesClientExpectsToReceive = download.expected
        }
        task.taskDescription = "\(download.id.uuidString)_\(download.attempt.uuidString)"
        transfers[download.id] = Transfer(download: download, attempt: download.attempt, task: task)
        identifiers[task.taskIdentifier] = download.id
        await legacyDelegate?.download(download, didCreateTask: task)
    }

    public func start(_ download: Download) async throws { transfers[download.id]?.task.resume() }

    public func pause(_ download: Download) async {
        guard let transfer = transfers.removeValue(forKey: download.id) else { return }
        identifiers[transfer.task.taskIdentifier] = nil
        let data = await transfer.task.cancelByProducingResumeData()
        await legacyDelegate?.download(download, didCancelWithResumeData: data)
    }

    public func remove(_ download: Download) async {
        await pause(download)
        let location = stagingDirectory.appendingPathComponent("\(download.id)_\(download.attempt)")
        try? FileManager.default.removeItem(at: location)
    }

    public func restore(_ downloads: [Download]) async -> [Download] {
        await restore(downloads, tasks: session.allTasks)
    }

    // Kept separate so upgrade/relaunch tests can supply real suspended URLSession tasks.
    func restore(_ downloads: [Download], tasks: [URLSessionTask]) async -> [Download] {
        let known = Set(downloads.map(\.id))
        var recovered: [Download] = []
        for task in tasks.compactMap({ $0 as? URLSessionDownloadTask }) {
            if let transfer = await transfer(for: task), !known.contains(transfer.download.id) {
                recovered.append(transfer.download)
            }
        }
        for download in downloads {
            let location = stagingDirectory.appendingPathComponent("\(download.id)_\(download.attempt)")
            if FileManager.default.fileExists(atPath: location.path) { download.completionLocation = location }
        }
        return recovered
    }

    private func transfer(for task: URLSessionDownloadTask) async -> Transfer? {
        if let id = identifiers[task.taskIdentifier], let transfer = transfers[id], transfer.task === task { return transfer }
        if let registration = registrations[task.taskIdentifier] { return await registration.value }
        let registration = Task { await register(task) }
        registrations[task.taskIdentifier] = registration
        let transfer = await registration.value
        registrations[task.taskIdentifier] = nil
        return transfer
    }

    private func register(_ task: URLSessionDownloadTask) async -> Transfer? {
        guard let request = task.originalRequest ?? task.currentRequest else { task.cancel(); return nil }
        let parts = task.taskDescription?.split(separator: "_") ?? []
        let id = parts.first.flatMap { UUID(uuidString: String($0)) }
        let download: Download
        if let id {
            // Never recreate an identified task removed from the logical queue.
            guard let existing = events?.download(with: id), parts.count == 2,
                  String(parts[1]) == existing.attempt.uuidString,
                  existing.status != .paused, existing.status != .finished else { task.cancel(); return nil }
            download = existing
            download.setRequest(request)
        } else {
            download = Download(request: request)
            await legacyDelegate?.download(download, didReconnectTask: task)
            guard task.state != .canceling, (task.error as? URLError)?.code != .cancelled else { return nil }
            guard await events?.recover(download) == true else { return nil }
        }
        if task.state == .running || task.state == .completed { download.setStatus(.downloading) }
        download.received = task.countOfBytesReceived
        if task.countOfBytesExpectedToReceive > 0 { download.expected = task.countOfBytesExpectedToReceive }
        task.taskDescription = "\(download.id)_\(download.attempt)"
        let transfer = Transfer(download: download, attempt: download.attempt, task: task)
        transfers[download.id] = transfer
        identifiers[task.taskIdentifier] = download.id
        return transfer
    }

}

extension URLSessionDownloadBackend: URLSessionDownloadDelegate {
    public nonisolated func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            guard let transfer = await self.transfer(for: downloadTask) else { return }
            await self.events?.progress(id: transfer.download.id, attempt: transfer.attempt, received: totalBytesWritten,
                expected: totalBytesExpectedToWrite)
        }
    }

    public nonisolated func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            guard let task = task as? URLSessionDownloadTask, let transfer = await self.transfer(for: task) else { return }
            let error = error as NSError
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
            let failure: DownloadError = error.domain == NSURLErrorDomain
                ? .transportError(URLError(URLError.Code(rawValue: error.code)), localizedDescription: error.localizedDescription)
                : .unknown(code: error.code, localizedDescription: error.localizedDescription)
            await self.events?.failed(id: transfer.download.id, attempt: transfer.attempt, error: failure)
        }
    }

    public nonisolated func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask,
                                       didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse else { return }
        guard (200..<300).contains(response.statusCode) else {
            Task { @MainActor in
                guard let transfer = await self.transfer(for: downloadTask) else { return }
                await self.events?.failed(id: transfer.download.id, attempt: transfer.attempt, error: .serverError(statusCode: response.statusCode))
            }
            return
        }
        // Capture the temporary file synchronously; URLSession removes it when this callback returns.
        let description = downloadTask.taskDescription
        let parts = description?.split(separator: "_") ?? []
        let name = parts.count == 2 && parts.allSatisfy({ UUID(uuidString: String($0)) != nil })
            ? description! : "\(legacyStagingPrefix)-\(downloadTask.taskIdentifier)"
        let durableLocation = stagingDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: durableLocation.path) {
                try FileManager.default.moveItem(at: location, to: durableLocation)
            }
        } catch {
            Task { @MainActor in
                guard let transfer = await self.transfer(for: downloadTask) else { return }
                await self.events?.failed(id: transfer.download.id, attempt: transfer.attempt,
                    error: .unknown(code: (error as NSError).code, localizedDescription: "Unable to stage download"))
            }
            return
        }
        Task { @MainActor in
            let completion = Task { @MainActor in
                guard let transfer = await self.transfer(for: downloadTask) else {
                    // Cancellation can win after URLSession delivered its temporary file.
                    try? FileManager.default.removeItem(at: durableLocation)
                    return
                }
                let id = transfer.download.id
                if await self.events?.completed(id: id, attempt: transfer.attempt, location: durableLocation) == true {
                    try? FileManager.default.removeItem(at: durableLocation)
                    self.identifiers[downloadTask.taskIdentifier] = nil
                    if self.transfers[id]?.attempt == transfer.attempt { self.transfers[id] = nil }
                }
            }
            self.completions.append(completion)
        }
    }

    public nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        Task { @MainActor in
            let pending = self.completions
            self.completions.removeAll()
            for completion in pending { await completion.value }
            await self.events?.backgroundEventsFinished()
        }
    }
}
#endif
