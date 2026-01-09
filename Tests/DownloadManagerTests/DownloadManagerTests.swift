//
//  DownloadManagerTests.swift
//  DownloadManager
//
//  Created by Lachlan Charlick on 26/2/21.
//

@testable import DownloadManager
import Swifter
import XCTest

private let testURL = URL(string: "http://test")!

@MainActor final class DownloadManagerTests: XCTestCase {
    private var observation: NSKeyValueObservation?
    // swiftlint:disable:next weak_delegate
    private var delegate: DelegateSpy!
    private var manager: DownloadManager!

    override func setUpWithError() throws {
        delegate = DelegateSpy { _ in }
        manager = DownloadManager(
            sessionConfiguration: .default,
            delegate: delegate
        )
    }

    override func tearDownWithError() throws {}
}

// MARK: - Assertions.

extension DownloadManagerTests {
    struct EquatableDownload: Equatable {
        let url: URL
        let status: DownloadStatus
    }

    func assertDownloadsEquals(
        _ received: [Download],
        _ expected: [Download],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            received.map { EquatableDownload(url: $0.url, status: $0.status) },
            expected.map { EquatableDownload(url: $0.url, status: $0.status) },
            file: file, line: line
        )
    }

    func assertCurrentQueueEquals(
        _ expected: [Download],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertDownloadsEquals(manager.downloads, expected, file: file, line: line)
    }

    func assertQueueChanges(
        _ expected: [[Download]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reducer = { (results: inout [[EquatableDownload]], downloads: [Download]) in
            results.append(
                downloads.map { EquatableDownload(url: $0.url, status: $0.status) }
            )
        }

        let received = delegate.queueChanges.reduce(into: [[EquatableDownload]](), reducer)
        let expected = expected.reduce(into: [[EquatableDownload]](), reducer)
        XCTAssertEqual(received, expected, file: file, line: line)
    }

}

// MARK: - Status.

extension DownloadManagerTests {
    func testInitialStatus() async {
        XCTAssertEqual(manager.status, .idle)
    }

    func testStatusChangesIfItemAddedToQueue() async throws {
        try await manager.append(testURL)
        XCTAssertEqual(manager.status, .downloading)
    }

    func testStatusChangesToIdleIfItemRemovedFromQueue() async throws {
        let download = try await manager.append(testURL)
        await manager.remove(download)
        XCTAssertEqual(manager.status, .idle)
    }

    func testStatusChangesToPausedIfOnlyItemPaused() async throws {
        let download = try await manager.append(testURL)
        await manager.pause(download)
        XCTAssertEqual(manager.status, .paused)
    }

    func testStatusChangesToFinishedIfOnlyItemFinished() async throws {
        let download = try await manager.append(testURL)
        download.setStatus(.finished)
        XCTAssertEqual(manager.status, .finished)
    }

    func testStatusChangesToPausedIfAllUnfinishedDownloadsArePaused() async throws {
        let download1 = try await manager.append(URL(string: "http://test1")!)
        let download2 = try await manager.append(URL(string: "http://test2")!)
        download1.setStatus(.finished)
        await manager.pause(download2)
        XCTAssertEqual(manager.status, .paused)
    }

    func testStatusChangesToFailedIfAllUnfinishedDownloadsAreFailed() async throws {
        let download1 = try await manager.append(URL(string: "http://test1")!)
        let download2 = try await manager.append(URL(string: "http://test2")!)
        download1.setStatus(.finished)
        download2.setStatus(.failed(.serverError(statusCode: 500)))
        XCTAssertEqual(manager.status, .failed(.aggregate(errors: [.serverError(statusCode: 500)])))
    }
}

// MARK: - Progress.

extension DownloadManagerTests {
    func testInitialProgress() {
        XCTAssertEqual(manager.totalExpected, 0)
        XCTAssertEqual(manager.totalReceived, 0)
        XCTAssertEqual(manager.fractionCompleted, 0)
    }

    func testProgressUpdatedWhenItemAddedToQueue() async throws {
        try await manager.append(testURL, estimatedSize: 100)

        XCTAssertEqual(manager.totalExpected, 100)
        XCTAssertEqual(manager.totalReceived, 0)
        XCTAssertEqual(manager.fractionCompleted, 0)
    }

    func testProgressUpdatedWhenDataIsDownloaded() async throws {
        let download = try await manager.append(testURL, estimatedSize: 100)
        try await manager.append(URL(string: "http://download2")!, estimatedSize: 100)

        download.received = 100

        XCTAssertEqual(manager.totalReceived, 100)
        XCTAssertEqual(manager.totalExpected, 200)
        XCTAssertEqual(manager.fractionCompleted, 0.5)
    }

    func testProgressUpdatedAfterCancellation() async throws {
        let download1 = try await manager.append(testURL, estimatedSize: 100)
        let download2 = try await manager.append(URL(string: "http://download2")!, estimatedSize: 100)

        download1.received = 100

        await manager.remove(download1)

        XCTAssertEqual(manager.totalReceived, 0)
        XCTAssertEqual(manager.totalExpected, 100)
        XCTAssertEqual(manager.fractionCompleted, 0)

        await manager.remove(download2)

        XCTAssertEqual(manager.totalReceived, 0)
        XCTAssertEqual(manager.totalExpected, 0)
        XCTAssertEqual(manager.fractionCompleted, 0)
    }
}

extension DownloadManagerTests {
    func testAggregateState() async throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!

        let download1 = try await manager.append(url1, estimatedSize: 100)
        let download2 = try await manager.append(url2, estimatedSize: 100)

        download1.received = 100

        let state = DownloadManager.state(of: [download1, download2])
        XCTAssertEqual(state.status, .downloading)
        XCTAssertEqual(state.totalExpected, 200)
        XCTAssertEqual(state.totalReceived, 100)
        XCTAssertEqual(state.fractionCompleted, 0.5)
    }

    func testAggregateStateUpdated() async throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!

        let download1 = try await manager.append(url1, estimatedSize: 100)
        let download2 = try await manager.append(url2, estimatedSize: 100)

        download1.received = 100
        let state1 = DownloadManager.state(of: [download1, download2])
        XCTAssertEqual(state1.totalReceived, 100)
        XCTAssertEqual(state1.fractionCompleted, 0.5)

        download2.received = 100
        let state2 = DownloadManager.state(of: [download1, download2])
        XCTAssertEqual(state2.totalReceived, 200)
        XCTAssertEqual(state2.fractionCompleted, 1.0)
    }
}

// MARK: - Queue.

extension DownloadManagerTests {
    func testEmptyQueue() throws {
        assertCurrentQueueEquals([])
    }

    func testDownloadAppendsQueue() async throws {
        try await manager.append(testURL)
        assertCurrentQueueEquals([
            Download(
                url: testURL,
                status: .downloading
            ),
        ])
    }

    func testDownloadDuplicateURLReplacesFinishedDownload() async throws {
        let download = try await manager.append(testURL, estimatedSize: 100)
        await manager.append(download)
        download.setStatus(.finished)

        let dupe = try await manager.append(testURL, estimatedSize: 100)
        await manager.append(dupe)
        XCTAssertEqual(dupe.status, .downloading)
    }

    func testFirstItemInQueueStartsDownloadingAutomatically() async throws {
        let download = try await manager.append(testURL)
        XCTAssertEqual(download.status, .downloading)
    }

    func testDownloadCreatesTask() async throws {
        let download = try await manager.append(testURL, estimatedSize: 100)
        XCTAssertEqual(delegate.requestedURLs, [testURL])
        XCTAssertEqual(delegate.tasks[download.id]?.countOfBytesClientExpectsToReceive, 100)
        XCTAssertEqual(delegate.tasks[download.id]?.state, .running)
    }

    func testBatchDownloadCreatesTasks() async throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!
        let download1 = manager.register(url1, estimatedSize: 0)
        let download2 = manager.register(url2, estimatedSize: 0)

        await manager.append(download1, download2)

        XCTAssertEqual(delegate.requestedURLs, [url1, url2])
        XCTAssertEqual(delegate.tasks[download1.id]?.state, .running)
        XCTAssertEqual(delegate.tasks[download2.id]?.state, .suspended)
    }

    func testConcurrentDownloads() async throws {
        manager.setMaxConcurrentDownloads(2)
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!
        let url3 = URL(string: "http://test3")!
        let download1 = manager.register(url1, estimatedSize: 0)
        let download2 = manager.register(url2, estimatedSize: 0)
        let download3 = manager.register(url3, estimatedSize: 0)

        await manager.append(download1, download2, download3)

        XCTAssertEqual(delegate.requestedURLs, [url1, url2, url3])
        XCTAssertEqual(delegate.tasks[download1.id]?.state, .running)
        XCTAssertEqual(delegate.tasks[download2.id]?.state, .running)
        XCTAssertEqual(delegate.tasks[download3.id]?.state, .suspended)
    }

    func testPause() async throws {
        let download = try await manager.append(testURL)
        await manager.pause(download)

        let task = delegate.tasks[download.id]!

        let expectation = expectation(description: "task state changes to `canceling`")
        expectation.assertForOverFulfill = false

        observation = task.observe(\.state, options: [.initial]) { task, _ in
            if task.state == .canceling || task.state == .completed {
                expectation.fulfill()
            }
        }

        await fulfillment(of: [expectation], timeout: 0.5)

        XCTAssertEqual(download.status, .paused)
    }

    func testPauseFinishedDownloadHasNoEffect() async throws {
        let download = try await manager.append(testURL)
        download.setStatus(.finished)
        await manager.pause(download)
        XCTAssertEqual(download.status, .finished)
    }

    func testResume() async throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!
        let download1 = try await manager.append(url1)
        let download2 = try await manager.append(url2)

        await manager.pause(download1)
        await manager.pause(download2)

        await manager.resume(download1)

        let task = delegate.tasks[download1.id]!

        assertCurrentQueueEquals([
            .init(url: url1, status: .downloading),
            .init(url: url2, status: .paused),
        ])
        XCTAssertEqual(task.state, .running)
        XCTAssertEqual(delegate.requestedURLs, [url1, url2, url1])
    }

    func testResumeFinishedDownloadHasNoEffect() async throws {
        let download = try await manager.append(testURL)
        let originalTask = delegate.tasks[download.id]
        await manager.pause(download)
        download.setStatus(.finished)
        await manager.resume(download)
        XCTAssertEqual(download.status, .finished)
        XCTAssertEqual(
            originalTask?.taskIdentifier,
            delegate.tasks[download.id]?.taskIdentifier
        )
    }

    func testCancel() async throws {
        let download = try await manager.append(testURL)
        await manager.remove(download)

        let task = delegate.tasks[download.id]!

        let expectation = expectation(description: "task state changes to `canceling`")
        expectation.assertForOverFulfill = false

        observation = task.observe(\.state, options: [.initial]) { task, _ in
            if task.state == .canceling || task.state == .completed {
                expectation.fulfill()
            }
        }

        await fulfillment(of: [expectation], timeout: 0.5)
    }

    func testCancelRemovesDownloadFromQueue() async throws {
        let download = try await manager.append(testURL)

        let task = delegate.tasks[download.id]!

        let expectation = expectation(description: "data task state changes to `canceling`")
        expectation.assertForOverFulfill = false

        observation = task.observe(\.state, options: [.initial]) { task, _ in
            if task.state == .canceling { expectation.fulfill() }
        }

        await manager.remove(download)

        await fulfillment(of: [expectation], timeout: 0.5)

        assertCurrentQueueEquals([])
    }

    func testCancelStartsDownloadingNextItemInQueue() async throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!

        let download1 = try await manager.append(url1)
        try await manager.append(url2)

        await manager.remove(download1)
        assertCurrentQueueEquals([
            Download(url: url2, status: .downloading),
        ])
    }

    func testPauseStartsDownloadingNextItemInQueue() async throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!

        let download1 = try await manager.append(url1)
        try await manager.append(url2)

        await manager.pause(download1)

        assertCurrentQueueEquals([
            Download(url: url1, status: .paused),
            Download(url: url2, status: .downloading),
        ])
    }
}

// MARK: - Delegate.

extension DownloadManagerTests {
    func testAddDownloadUpdatesQueue() async throws {
        try await manager.append(testURL)

        assertCurrentQueueEquals([
            Download(url: testURL, status: .downloading)
        ])
    }

    func testBatchDownloadUpdatesQueue() async throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!
        let download1 = manager.register(url1, estimatedSize: 0)
        let download2 = manager.register(url2, estimatedSize: 0)

        await manager.append(download1, download2)

        assertCurrentQueueEquals([
            Download(id: download1.id, url: url1, status: .downloading),
            Download(id: download2.id, url: url2, status: .idle),
        ])
    }

    func testPauseUpdatesDownloadStatus() async throws {
        let download = try await manager.append(testURL)
        await manager.pause(download)

        XCTAssertEqual(download.status, .paused)
        assertCurrentQueueEquals([
            Download(url: testURL, status: .paused)
        ])
    }

    func testCancelRemovesFromQueue() async throws {
        let download = try await manager.append(testURL)
        await manager.remove(download)

        assertCurrentQueueEquals([])
    }

    func testBatchCancelRemovesAllFromQueue() async throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!
        let download1 = manager.register(url1, estimatedSize: 0)
        let download2 = manager.register(url2, estimatedSize: 0)

        await manager.append(download1, download2)
        await manager.remove(download1, download2)

        assertCurrentQueueEquals([])
    }

    func testCancelProducesResumeData() async throws {
        let download = try await manager.append(testURL)
        await manager.remove(download)
        XCTAssertNotNil(delegate.resumeData[download.id])
    }

    /*
     func testStatusChanges() async throws {
         var statusChanges = [DownloadStatus]()

         let delegate = DelegateSpy { _ in
             self.manager.status
         }

         await manager.setDelegate(delegate)

         let download = try await manager.append(testURL)
         await manager.pause(download)
         await manager.remove(download)

         let manager = DownloadManager(
             sessionConfiguration: .default,
             delegate: delegate
         )

         XCTAssertEqual(delegate.statusChanges, [
             .downloading,
             .paused,
             .idle,
         ])
     }
     */
}

// MARK: - Throughput.

extension DownloadManagerTests {
    func testThroughputResetWhenDownloadsComplete() async throws {
        var throughputChanges: [Int] = []

        let delegate = DelegateSpy(downloadStatusDidChangeHandler: { _ in })
        delegate.throughputHandler = { throughput in
            throughputChanges.append(throughput)
        }

        let manager = DownloadManager(
            sessionConfiguration: .default,
            delegate: delegate
        )

        // Initially, throughput should be 0
        XCTAssertEqual(manager.throughput, 0)

        // Start a download to trigger throughput monitoring
        let download = try await manager.append(testURL, estimatedSize: 1000)

        // Simulate some progress to generate throughput
        download.received = 500

        // Wait for a throughput calculation cycle
        try await Task.sleep(for: .milliseconds(1100))

        // Complete the download
        download.setStatus(.finished)

        // Wait a moment for the status change to propagate
        try await Task.sleep(for: .milliseconds(100))

        // Throughput should be reset to 0
        XCTAssertEqual(manager.throughput, 0)

        // Delegate should have been notified of the reset
        XCTAssertTrue(throughputChanges.contains(0), "Delegate should receive throughput reset to 0")
    }
}

extension DownloadManager {
    @discardableResult
    func register(_ url: URL, estimatedSize: Int64 = 0) -> Download {
        let request = URLRequest(url: url)
        let download = Download(
            request: request,
            expected: estimatedSize
        )
        return download
    }

    @discardableResult
    func append(_ url: URL, estimatedSize: Int64 = 0) async throws -> Download {
        let download = register(url, estimatedSize: estimatedSize)
        await append(download)
        return download
    }
}

