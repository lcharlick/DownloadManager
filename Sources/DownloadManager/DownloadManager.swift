//
//  DownloadManager.swift
//  DownloadKit
//
//  Created by Lachlan Charlick on 26/2/21.
//

import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared queue policy. The backend performs transfers only while execution is permitted.
@Observable @MainActor public class DownloadManager: NSObject, DownloadBackendEvents {
    public private(set) var downloads: [Download] = []
    private var cache: [UUID: Download] = [:]
    private let backend: any DownloadBackend
    private let queueFile: DownloadQueueFile?
    public private(set) weak var delegate: DownloadManagerDelegate?
    public private(set) var maxConcurrentDownloads = 1
    public private(set) var throughput = 0
    public private(set) var persistenceError: Error?
    public var didChange: (@MainActor () -> Void)?
    private var executionEnabled: Bool
    private var pumping = false
    private var preparationRetry: Task<Void, Never>?
    private var preparing = 0
    private var statusObservation: DownloadStatusObservation?
    private var restored: Bool
    private var restoring = false
    private var restoreTask: Task<Int, Never>?
    private var restorationError: Error?
    private var finalizations: [UUID: Task<Bool, Never>] = [:]
    private var lastProgressSave = Date.distantPast
    private var lastThroughputTime = Date()
    private var lastReceived: Int64 = 0

    public var totalExpected: Int64 { downloads.reduce(0) { $0 + max(0, $1.expected) } }
    public var totalReceived: Int64 { downloads.reduce(0) { $0 + max(0, $1.received) } }
    public var fractionCompleted: Double { Self.fractionCompleted(of: downloads) }
    public var status: DownloadStatus { Self.calculateStatus(for: downloads) }

    public init(backend: any DownloadBackend, delegate: DownloadManagerDelegate? = nil,
                queueFile: DownloadQueueFile? = nil, executionEnabled: Bool = true) {
        self.backend = backend
        self.delegate = delegate
        self.queueFile = queueFile
        self.executionEnabled = executionEnabled
        self.restored = queueFile == nil
        super.init()
        backend.events = self
        statusObservation = DownloadStatusObservation { [weak self] notification in
            guard let download = notification.object as? Download else { return }
            Task { @MainActor [weak self] in
                guard let self, self.cache[download.id] === download else { return }
                if self.status != .downloading {
                    self.throughput = 0
                    await self.delegate?.downloadThroughputDidChange(0)
                }
            }
        }
        do {
            for entry in try queueFile?.load() ?? [] {
                let status: DownloadStatus
                switch entry.state {
                case .queued: status = .idle
                case .paused: status = .paused
                case .finished: status = .finished
                case .failed: status = .failed(.unknown(code: 0, localizedDescription: "Previous transfer failed"))
                }
                let download = Download(id: entry.id, url: URL(string: "about:blank")!, status: status,
                    expected: entry.expected, received: entry.received)
                download.attempt = entry.attempt
                download.context = entry.context
                download.completionLocation = entry.completionPath.map { URL(fileURLWithPath: $0) }
                downloads.append(download)
                cache[download.id] = download
            }
        } catch { persistenceError = error; restorationError = error }
    }

    #if !os(Android) && !os(Linux)
    public convenience init(sessionConfiguration: URLSessionConfiguration,
                            delegate: DownloadManagerDelegate? = nil, queueFile: DownloadQueueFile? = nil) {
        let backend = URLSessionDownloadBackend(configuration: sessionConfiguration)
        self.init(backend: backend, delegate: delegate, queueFile: queueFile)
        backend.legacyDelegate = delegate
    }
    #endif

    public func setDelegate(_ delegate: DownloadManagerDelegate?) {
        self.delegate = delegate
        #if !os(Android) && !os(Linux)
        (backend as? URLSessionDownloadBackend)?.legacyDelegate = delegate
        #endif
    }
    public func setMaxConcurrentDownloads(_ value: Int) {
        maxConcurrentDownloads = max(1, value)
        Task { await pump() }
    }
    public func download(with id: UUID) -> Download? { cache[id] }

    public func recover(_ download: Download) async -> Bool {
        if let existing = cache[download.id] { return existing === download }
        downloads.append(download)
        cache[download.id] = download
        guard save() else {
            downloads.removeAll { $0 === download }
            cache[download.id] = nil
            return false
        }
        await changed(queue: true)
        return true
    }

    /// Legacy Apple entry point; also restores file-backed queued and paused work.
    public func attachOutstandingDownloadTasks(completionHandler: @escaping @Sendable (Int) -> Void) {
        Task { completionHandler(await restore()) }
    }
    @discardableResult public func restore() async -> Int {
        if let restoreTask { return await restoreTask.value }
        let task = Task { await performRestore() }
        restoreTask = task
        return await task.value
    }
    private func performRestore() async -> Int {
        guard !restoring, restorationError == nil else { return 0 }
        restoring = true
        defer { restoring = false }
        let recovered = await backend.restore(downloads)
        for download in recovered where cache[download.id] == nil {
            downloads.append(download)
            cache[download.id] = download
        }
        restored = true
        guard save() else { return recovered.count }
        for download in downloads where download.completionLocation != nil && download.status != .paused {
            _ = await completed(id: download.id, attempt: download.attempt, location: download.completionLocation!)
        }
        await changed(queue: true)
        restoring = false
        await pump()
        return recovered.count
    }

    public func setExecutionEnabled(_ enabled: Bool) async {
        executionEnabled = enabled
        if enabled { await pump(); return }
        for download in downloads where download.status == .downloading {
            if let task = finalizations[download.id] { _ = await task.value }
            guard download.status == .downloading else { continue }
            download.setStatus(.idle)
            _ = save()
            await backend.pause(download)
        }
        throughput = 0
        await changed()
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


    public func append(_ additions: [Download]) async {
        let old = downloads
        for download in additions where cache[download.id] == nil {
            downloads.append(download)
            cache[download.id] = download
        }
        guard save() else { downloads = old; rebuildCache(); return }
        preparing += 1
        for download in additions where cache[download.id] != nil {
            do { try await backend.prepare(download) }
            catch { download.setStatus(.failed(.unknown(code: (error as NSError).code, localizedDescription: "Transfer unavailable"))) }
            if cache[download.id] == nil { await backend.remove(download) }
        }
        preparing -= 1
        _ = save()
        await changed(queue: true)
        await pump()
    }
    public func append(_ downloads: Download...) async { await append(downloads) }

    public func remove(_ removals: Set<Download>) async {
        for download in removals {
            if let task = finalizations[download.id] { _ = await task.value }
        }
        let old = downloads
        downloads.removeAll { removals.contains($0) }
        rebuildCache()
        guard save() else { downloads = old; rebuildCache(); return }
        for download in removals {
            await backend.remove(download)
            if let location = download.completionLocation { try? FileManager.default.removeItem(at: location) }
        }
        await changed(queue: true)
        await pump()
    }
    public func remove(_ downloads: Download...) async { await remove(Set(downloads)) }

    public func pause(_ download: Download) async {
        if let task = finalizations[download.id] { _ = await task.value }
        guard cache[download.id] != nil, download.status != .finished else { return }
        let old = download.status
        download.setStatus(.paused)
        guard save() else { download.setStatus(old); return }
        await backend.pause(download)
        await changed(download: download)
        await pump()
    }
    public func resume(_ download: Download) async {
        if let task = finalizations[download.id] { _ = await task.value }
        guard cache[download.id] != nil, download.status != .finished else { return }
        let old = download.status
        let attempt = download.attempt
        // Fence the previous engine before awaiting cancellation.
        download.attempt = UUID()
        download.setStatus(.paused)
        guard save() else { download.attempt = attempt; download.setStatus(old); return }
        let resumedAttempt = download.attempt
        await backend.pause(download)
        guard cache[download.id] != nil, download.attempt == resumedAttempt else { return }
        download.setStatus(.idle)
        _ = save()
        await changed(download: download)
        await pump()
    }
    public func update(_ download: Download, with request: URLRequest) async {
        if let task = finalizations[download.id] { _ = await task.value }
        guard cache[download.id] != nil, download.status != .finished else { return }
        let oldStatus = download.status
        let oldAttempt = download.attempt
        let oldRequest = download.request
        download.attempt = UUID()
        download.setRequest(request)
        download.setStatus(.paused)
        guard save() else {
            download.attempt = oldAttempt
            download.setRequest(oldRequest)
            download.setStatus(oldStatus)
            return
        }
        let updatedAttempt = download.attempt
        await backend.pause(download)
        guard cache[download.id] != nil, download.attempt == updatedAttempt else { return }
        if oldStatus != .downloading { download.setStatus(oldStatus) }
        else { download.setStatus(.idle) }
        _ = save()
    }

    private func rebuildCache() { cache = Dictionary(uniqueKeysWithValues: downloads.map { ($0.id, $0) }) }
    @discardableResult private func save() -> Bool {
        if let restorationError { persistenceError = restorationError; return false }
        do { try queueFile?.save(downloads); persistenceError = nil; return true }
        catch { persistenceError = error; didChange?(); return false }
    }
    public func checkPersistence() throws { if let persistenceError { throw persistenceError } }

    private func changed(download: Download? = nil, queue: Bool = false) async {
        if status != .downloading {
            throughput = 0
            await delegate?.downloadThroughputDidChange(0)
        }
        didChange?()
        if let download { await delegate?.downloadStatusDidChange(download) }
        if queue { await delegate?.downloadQueueDidChange(downloads) }
    }

    private func pump() async {
        guard !pumping, preparing == 0, restored, !restoring, executionEnabled, persistenceError == nil else { return }
        pumping = true
        defer { pumping = false }
        var waiting = Set<UUID>()
        while executionEnabled && persistenceError == nil,
              downloads.filter({ $0.status == .downloading }).count < maxConcurrentDownloads,
              let download = downloads.first(where: { $0.status == .idle && !waiting.contains($0.id) }) {
            download.setStatus(.downloading)
            guard save() else { download.setStatus(.idle); return }
            var attempt = download.attempt
            do {
                if let location = download.completionLocation {
                    _ = await completed(id: download.id, attempt: attempt, location: location)
                    continue
                }
                if let delegate, backend.requiresRequestRefresh(download) {
                    let request = try await delegate.requestForDownload(download)
                    guard isCurrent(download.id, attempt: attempt), executionEnabled else { continue }
                    if request != download.request {
                        download.attempt = UUID()
                        attempt = download.attempt
                        await backend.pause(download)
                        download.setRequest(request)
                        guard save() else { download.setStatus(.idle); return }
                    }
                }
                guard isCurrent(download.id, attempt: attempt), executionEnabled else { continue }
                try await backend.prepare(download)
                guard save() else { download.setStatus(.idle); return }
                guard isCurrent(download.id, attempt: attempt), executionEnabled else { continue }
                try await backend.start(download)
                await changed(download: download)
            } catch DownloadPreparationError.temporarilyUnavailable {
                guard isCurrent(download.id, attempt: attempt) else { continue }
                download.setStatus(.idle)
                waiting.insert(download.id)
                _ = save()
                await changed(download: download)
                schedulePreparationRetry()
            } catch {
                await failed(id: download.id, attempt: attempt, error: (error as? DownloadError) ??
                    .unknown(code: (error as NSError).code, localizedDescription: "Transfer unavailable"))
            }
        }
    }
    /// Also usable by the host when connectivity becomes available.
    public func retryPendingDownloads() async {
        preparationRetry?.cancel()
        preparationRetry = nil
        await pump()
    }

    private func schedulePreparationRetry() {
        guard preparationRetry == nil else { return }
        preparationRetry = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self else { return }
            self.preparationRetry = nil
            await self.pump()
        }
    }

    private func isCurrent(_ id: UUID, attempt: UUID) -> Bool {
        guard let download = cache[id] else { return false }
        return download.attempt == attempt && download.status == .downloading
    }

    public func progress(id: UUID, attempt: UUID, received: Int64, expected: Int64) async {
        guard isCurrent(id, attempt: attempt), let download = cache[id] else { return }
        download.received = max(0, received)
        download.expected = max(0, expected)
        let now = Date()
        if now.timeIntervalSince(lastProgressSave) >= 1 { _ = save(); lastProgressSave = now }
        if now.timeIntervalSince(lastThroughputTime) >= 1 {
            throughput = max(0, Int(Double(totalReceived - lastReceived) / now.timeIntervalSince(lastThroughputTime)))
            lastReceived = totalReceived
            lastThroughputTime = now
            await delegate?.downloadThroughputDidChange(throughput)
        }
        didChange?()
        await delegate?.downloadDidUpdateProgress(download)
    }
    public func failed(id: UUID, attempt: UUID, error: DownloadError) async {
        guard isCurrent(id, attempt: attempt), let download = cache[id] else { return }
        download.setStatus(.failed(error))
        _ = save()
        await changed(download: download)
        await pump()
    }
    public func completed(id: UUID, attempt: UUID, location: URL) async -> Bool {
        guard let download = cache[id], download.attempt == attempt else { return false }
        if let task = finalizations[id] { return await task.value }
        if download.status == .finished { return save() }
        guard download.status != .paused else { return false }
        let task = Task { @MainActor in
            download.completionLocation = location
            guard self.save() else {
                download.setStatus(.failed(.unknown(code: 0, localizedDescription: "Unable to store download queue")))
                await self.changed(download: download)
                return false
            }
            do {
                try await self.delegate?.finalizeDownload(download, location: location)
                // A caller without a delegate explicitly accepts and discards the file.
                if self.delegate == nil { try? FileManager.default.removeItem(at: location) }
                download.setStatus(.finished)
                download.completionLocation = nil
                guard self.save() else { return false }
                await self.changed(download: download)
                return true
            } catch {
                download.setStatus(.failed(.unknown(code: (error as NSError).code, localizedDescription: "Unable to store download")))
                _ = self.save()
                await self.changed(download: download)
                return false
            }
        }
        finalizations[id] = task
        let result = await task.value
        finalizations[id] = nil
        await pump()
        return result
    }
    public func backgroundEventsFinished() async { await delegate?.downloadManagerDidFinishBackgroundDownloads() }
}

private final class DownloadStatusObservation: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ handler: @escaping @Sendable (Notification) -> Void) {
        token = NotificationCenter.default.addObserver(forName: .downloadStatusChanged, object: nil, queue: nil, using: handler)
    }
    deinit { NotificationCenter.default.removeObserver(token) }
}
