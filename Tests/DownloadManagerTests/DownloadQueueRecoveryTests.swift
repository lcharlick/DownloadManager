//
//  DownloadQueueRecoveryTests.swift
//  DownloadKit
//
//  Created by Lachlan Charlick on 13/9/2026.
//

import Foundation
import XCTest
@testable import DownloadKit

@MainActor final class DownloadQueueRecoveryTests: XCTestCase {
    private final class Engine: DownloadBackend {
        weak var events: (any DownloadBackendEvents)?
        var started: [UUID] = []
        var paused: [UUID] = []
        var handlePause: ((Download) async -> Void)?
        func start(_ download: Download) async throws { started.append(download.id) }
        func pause(_ download: Download) async { paused.append(download.id); await handlePause?(download) }
        func remove(_ download: Download) async { paused.append(download.id) }
    }
    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("queue.json")
    }
    private func item() -> Download {
        let item = Download(url: URL(string: "https://example.invalid/book?token=do-not-persist")!, expected: 100)
        item.context["trackID"] = "42"
        return item
    }

    func testRestoresOrderIdentityAndUserPauseWithoutPersistingCredentials() async throws {
        let file = DownloadQueueFile(url: try location())
        let first = item(), second = item()
        let engine = Engine()
        let original = DownloadManager(backend: engine, queueFile: file, executionEnabled: false)
        await original.restore()
        await original.append(first, second)
        await original.pause(first)
        let restoredEngine = Engine()
        let restored = DownloadManager(backend: restoredEngine, queueFile: file, executionEnabled: false)
        await restored.restore()
        XCTAssertEqual(restored.downloads.map(\.id), [first.id, second.id])
        XCTAssertEqual(restored.downloads[0].context["trackID"], "42")
        XCTAssertEqual(restored.downloads[0].status, .paused)
        await restored.setExecutionEnabled(true)
        XCTAssertEqual(restoredEngine.started, [second.id])
        let text = try String(contentsOf: file.url, encoding: .utf8)
        XCTAssertFalse(text.contains("token"))
        XCTAssertFalse(text.contains("example.invalid"))
    }

    func testExecutionGateAndSlotsUseTheSameQueue() async throws {
        let engine = Engine()
        let manager = DownloadManager(backend: engine, executionEnabled: false)
        let first = item(), second = item()
        await manager.append(first, second)
        XCTAssertTrue(engine.started.isEmpty)
        await manager.setExecutionEnabled(true)
        XCTAssertEqual(engine.started, [first.id])
        await manager.pause(first)
        XCTAssertEqual(engine.started, [first.id, second.id])
        await manager.setExecutionEnabled(false)
        XCTAssertEqual(first.status, .paused)
        XCTAssertEqual(second.status, .idle)
        await manager.setExecutionEnabled(true)
        XCTAssertEqual(engine.started, [first.id, second.id, second.id])
    }

    func testOldAttemptAndRemovedDownloadCannotComplete() async throws {
        let manager = DownloadManager(backend: Engine())
        let download = item()
        await manager.append(download)
        let oldAttempt = download.attempt
        await manager.pause(download)
        await manager.resume(download)
        let file = try location()
        try Data([1, 2, 3]).write(to: file)
        let stale = await manager.completed(id: download.id, attempt: oldAttempt, location: file)
        XCTAssertFalse(stale)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        await manager.remove(download)
        let removed = await manager.completed(id: download.id, attempt: download.attempt, location: file)
        XCTAssertFalse(removed)
    }

    func testCorruptQueueIsPreservedAndCannotStartWork() async throws {
        let file = try location()
        let corrupt = Data("not valid JSON".utf8)
        try corrupt.write(to: file)
        let engine = Engine()
        let manager = DownloadManager(backend: engine, queueFile: DownloadQueueFile(url: file))
        await manager.restore()
        await manager.append(item())
        XCTAssertThrowsError(try manager.checkPersistence())
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        XCTAssertTrue(engine.started.isEmpty)
        XCTAssertTrue(manager.downloads.isEmpty)
    }

    func testFailedQueueWriteDoesNotEnqueueOrStartTransfer() async throws {
        let parent = try location()
        try Data().write(to: parent)
        let engine = Engine()
        let manager = DownloadManager(backend: engine,
            queueFile: DownloadQueueFile(url: parent.appendingPathComponent("queue.json")))
        await manager.restore()
        await manager.append(item())
        XCTAssertThrowsError(try manager.checkPersistence())
        XCTAssertTrue(engine.started.isEmpty)
        XCTAssertTrue(manager.downloads.isEmpty)
    }
    func testAppleStyleRestoreStartsQueuedTransfersWithoutAnExtraEnableCall() async throws {
        let file = DownloadQueueFile(url: try location())
        let first = DownloadManager(backend: Engine(), queueFile: file, executionEnabled: false)
        await first.restore()
        let download = item()
        await first.append(download)
        let engine = Engine()
        let restored = DownloadManager(backend: engine, queueFile: file)
        async let a = restored.restore()
        async let b = restored.restore()
        _ = await (a, b)
        XCTAssertEqual(engine.started, [download.id])
    }

    func testResumeFencesCompletionWhileCancellationIsSuspended() async throws {
        let engine = Engine()
        let manager = DownloadManager(backend: engine)
        let download = item()
        await manager.append(download)
        let oldAttempt = download.attempt
        let file = try location()
        try Data([1, 2, 3]).write(to: file)
        engine.handlePause = { download in
            let accepted = await manager.completed(id: download.id, attempt: oldAttempt, location: file)
            XCTAssertFalse(accepted)
        }
        await manager.resume(download)
        XCTAssertEqual(download.status, .downloading)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    private final class Finalizer: DownloadManagerDelegate {
        #if !os(Android) && !os(Linux)
        func download(_ download: Download, didCreateTask: URLSessionDownloadTask) async {}
        func download(_ download: Download, didReconnectTask: URLSessionDownloadTask) async {}
        #endif
        func download(_ download: Download, didFinishDownloadingTo location: URL) async {}
        func download(_ download: Download, didCancelWithResumeData resumeData: Data?) async {}
        func resumeDataForDownload(_ download: Download) async -> Data? { nil }
        func downloadManagerDidFinishBackgroundDownloads() async {}
        func downloadQueueDidChange(_ downloads: [Download]) async {}
        func downloadThroughputDidChange(_ bytesPerSecond: Int) async {}
        func downloadDidUpdateProgress(_ download: Download) async {}
        func downloadStatusDidChange(_ download: Download) async {}
        var requestCalls = 0
        var offline = false
        func requestForDownload(_ download: Download) async throws -> URLRequest {
            requestCalls += 1
            if offline { throw DownloadPreparationError.temporarilyUnavailable }
            return URLRequest(url: URL(string: "https://example.invalid/fresh")!)
        }
        var calls = 0
        var shouldFail = true
        func finalizeDownload(_ download: Download, location: URL) async throws {
            calls += 1
            await Task.yield()
            if shouldFail { throw CocoaError(.fileWriteNoPermission) }
        }
    }

    func testConcurrentCompletionIsSharedAndFailedHandoffCanRetry() async throws {
        let delegate = Finalizer()
        let manager = DownloadManager(backend: Engine(), delegate: delegate)
        let download = item()
        await manager.append(download)
        let file = try location()
        try Data([1, 2, 3]).write(to: file)
        async let first = manager.completed(id: download.id, attempt: download.attempt, location: file)
        async let second = manager.completed(id: download.id, attempt: download.attempt, location: file)
        let rejected = await (first, second)
        XCTAssertFalse(rejected.0)
        XCTAssertFalse(rejected.1)
        XCTAssertEqual(delegate.calls, 1)
        XCTAssertEqual(download.completionLocation, file)
        delegate.shouldFail = false
        let accepted = await manager.completed(id: download.id, attempt: download.attempt, location: file)
        XCTAssertTrue(accepted)
        XCTAssertEqual(delegate.calls, 2)
        XCTAssertEqual(download.status, .finished)
    }

    func testOfflinePreparationStaysQueuedAndAutomaticallyEligibleForRetry() async throws {
        let file = DownloadQueueFile(url: try location())
        let original = DownloadManager(backend: Engine(), queueFile: file, executionEnabled: false)
        await original.restore()
        let first = item(), second = item()
        await original.append(first, second)
        let delegate = Finalizer()
        delegate.offline = true
        let engine = Engine()
        let restored = DownloadManager(backend: engine, delegate: delegate, queueFile: file)
        await restored.restore()
        XCTAssertEqual(restored.downloads.map(\.status), [.idle, .idle])
        XCTAssertEqual(try file.load().map(\.state), [.queued, .queued])
        XCTAssertTrue(engine.started.isEmpty)
        XCTAssertEqual(delegate.requestCalls, 2, "An offline queue must not spin on the first item")
        await restored.pause(restored.downloads[1])
        delegate.offline = false
        await restored.retryPendingDownloads()
        XCTAssertEqual(engine.started, [first.id])
        XCTAssertEqual(restored.downloads[1].status, .paused)
    }

}
