//
//  AppleDownloadRestoreTests.swift
//  DownloadKit
//
//  Created by Lachlan Charlick on 13/9/2026.
//

import Foundation
import XCTest
import Swifter
@testable import DownloadKit

private final class WaitingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

@MainActor final class AppleDownloadRestoreTests: XCTestCase {
    private final class OfflineDelegate: DownloadManagerDelegate {
        var probes = 0
        var reconnected = 0
        var rejectLegacy = false
        var completedData: Data?
        var handleCompletion: (() -> Void)?
        func requestForDownload(_ download: Download) async throws -> URLRequest {
            probes += 1
            throw DownloadPreparationError.temporarilyUnavailable
        }
        func download(_ download: Download, didReconnectTask task: URLSessionDownloadTask) async {
            reconnected += 1
            if rejectLegacy { task.cancel() }
            else { download.context["trackID"] = "42" }
        }
        func download(_ download: Download, didCreateTask task: URLSessionDownloadTask) async {}
        func download(_ download: Download, didFinishDownloadingTo location: URL) async {
            completedData = try? Data(contentsOf: location)
            handleCompletion?()
        }
        func download(_ download: Download, didCancelWithResumeData data: Data?) async {}
        func resumeDataForDownload(_ download: Download) async -> Data? { nil }
        func downloadManagerDidFinishBackgroundDownloads() async {}
        func downloadQueueDidChange(_ downloads: [Download]) async {}
        func downloadThroughputDidChange(_ bytesPerSecond: Int) async {}
        func downloadDidUpdateProgress(_ download: Download) async {}
        func downloadStatusDidChange(_ download: Download) async {}
    }
    private final class RestoredEngine: DownloadBackend {
        weak var events: (any DownloadBackendEvents)? { didSet { apple.events = events } }
        let apple: URLSessionDownloadBackend
        let tasks: [URLSessionTask]
        init(apple: URLSessionDownloadBackend, tasks: [URLSessionTask]) { self.apple = apple; self.tasks = tasks }
        func requiresRequestRefresh(_ download: Download) -> Bool { apple.requiresRequestRefresh(download) }
        func prepare(_ download: Download) async throws { try await apple.prepare(download) }
        func start(_ download: Download) async throws { try await apple.start(download) }
        func pause(_ download: Download) async { await apple.pause(download) }
        func remove(_ download: Download) async { await apple.remove(download) }
        func restore(_ downloads: [Download]) async -> [Download] { await apple.restore(downloads, tasks: tasks) }
    }
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WaitingProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func queueFile() throws -> DownloadQueueFile {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return DownloadQueueFile(url: directory.appendingPathComponent("queue.json"))
    }

    func testOfflineRelaunchResumesTheOriginalSuspendedTaskWithoutProbing() async throws {
        let file = try queueFile()
        var request = URLRequest(url: URL(string: "https://fixture.invalid/audio?token=existing")!)
        request.setValue("existing-header", forHTTPHeaderField: "Authorization")
        let original = Download(request: request)
        original.context["trackID"] = "42"
        try file.save([original])
        let session = session()
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: request)
        task.taskDescription = "\(original.id)_\(original.attempt)"
        let identifier = task.taskIdentifier
        let delegate = OfflineDelegate()
        let apple = URLSessionDownloadBackend(configuration: .ephemeral)
        apple.legacyDelegate = delegate
        let engine = RestoredEngine(apple: apple, tasks: [task])
        let manager = DownloadManager(backend: engine, delegate: delegate, queueFile: file)
        await manager.restore()
        XCTAssertEqual(delegate.probes, 0)
        XCTAssertEqual(delegate.reconnected, 0)
        XCTAssertEqual(manager.downloads.first?.status, .downloading)
        XCTAssertEqual(manager.downloads.first?.requestValue, request)
        XCTAssertEqual(task.taskIdentifier, identifier)
        XCTAssertEqual(task.state, .running)
        XCTAssertEqual(try file.load().first?.state, .queued)
    }

    func testFirstUpgradeReconnectsLegacyTaskWithoutChangingItsRequest() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://fixture.invalid/legacy")!)
        let task = session.downloadTask(with: request)
        XCTAssertNil(task.taskDescription)
        let delegate = OfflineDelegate()
        let apple = URLSessionDownloadBackend(configuration: .ephemeral)
        apple.legacyDelegate = delegate
        let manager = DownloadManager(backend: RestoredEngine(apple: apple, tasks: [task]),
            delegate: delegate, queueFile: try queueFile())
        await manager.restore()
        XCTAssertEqual(delegate.probes, 0)
        XCTAssertEqual(delegate.reconnected, 1)
        XCTAssertEqual(manager.downloads.first?.context["trackID"], "42")
        XCTAssertEqual(manager.downloads.first?.requestValue, request)
        XCTAssertEqual(task.state, .running)
    }

    func testRejectedLegacyTaskIsNotRequeuedOrResumed() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://fixture.invalid/removed-book")!)
        let delegate = OfflineDelegate()
        delegate.rejectLegacy = true
        let apple = URLSessionDownloadBackend(configuration: .ephemeral)
        apple.legacyDelegate = delegate
        let manager = DownloadManager(backend: RestoredEngine(apple: apple, tasks: [task]),
            delegate: delegate, queueFile: try queueFile())
        await manager.restore()
        XCTAssertTrue(manager.downloads.isEmpty)
        XCTAssertEqual(delegate.probes, 0)
        XCTAssertTrue(task.state == .canceling || task.state == .completed)
    }
    func testLegacyCompletionDeliveredBeforeRestoreKeepsTheDownloadedBytes() async throws {
        let expected = Data("finished while the app was relaunching".utf8)
        let server = HttpServer()
        server["/audio"] = { _ in .ok(.data(expected, contentType: "audio/mpeg")) }
        try server.start(0)
        defer { server.stop() }
        let file = try queueFile()
        let delegate = OfflineDelegate()
        let finished = expectation(description: "Legacy completion is handed to durable app storage")
        delegate.handleCompletion = { finished.fulfill() }
        let apple = URLSessionDownloadBackend(configuration: .ephemeral,
            stagingDirectory: file.url.deletingLastPathComponent().appendingPathComponent("completed"))
        apple.legacyDelegate = delegate
        let manager = DownloadManager(backend: apple, delegate: delegate, queueFile: file)
        // Simulate URLSession delivering an old, unlabelled task before the app calls restore.
        let session = URLSession(configuration: .ephemeral, delegate: apple, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "http://127.0.0.1:\(try server.port())/audio")!)
        task.resume()
        await fulfillment(of: [finished], timeout: 5)
        // The completion acknowledgment finishes just after the delegate callback.
        for _ in 0..<100 where manager.downloads.first?.status != .finished {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(delegate.completedData, expected)
        XCTAssertEqual(delegate.probes, 0)
        XCTAssertEqual(delegate.reconnected, 1)
        XCTAssertEqual(manager.downloads.first?.status, .finished)
        XCTAssertEqual(try file.load().first?.context["trackID"], "42")
        await manager.restore()
        XCTAssertEqual(manager.downloads.count, 1)
        XCTAssertEqual(manager.downloads.first?.status, .finished)
    }

}
