//
//  DownloadManagerTests.swift
//  DownloadManager
//
//  Created by Lachlan Charlick on 26/2/21.
//

import XCTest
import Combine
import Swifter
@testable import DownloadManager

private let testURL = URL(string: "http://test")!

final class DownloadManagerTests: XCTestCase {
    private var observation: NSKeyValueObservation?
    private var cancellables: Set<AnyCancellable> = []
    // swiftlint:disable:next weak_delegate
    private var delegate: DelegateSpy!
    private var manager: DownloadManager!

    override func setUpWithError() throws {
        self.cancellables = []
        self.delegate = DelegateSpy { _ in }
        self.manager = DownloadManager(
            sessionConfiguration: .default,
            delegate: delegate
        )
    }

    override func tearDownWithError() throws {
    }
}

// MARK: - Assertions.

extension DownloadManagerTests {
    struct EquatableDownload: Equatable {
        let url: URL
        let status: DownloadState.Status
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
        assertDownloadsEquals(manager.queue.downloads, expected, file: file, line: line)
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
    func testInitialStatus() {
        XCTAssertEqual(manager.state.status, .idle)
    }

    func testStatusChangesIfItemAddedToQueue() throws {
        try manager.append(testURL)
        XCTAssertEqual(manager.state.status, .downloading)
    }

    func testStatusChangesToIdleIfItemRemovedFromQueue() throws {
        let download = try manager.append(testURL)
        manager.remove(download)
        XCTAssertEqual(manager.state.status, .idle)
    }

    func testStatusChangesToPausedIfOnlyItemPaused() throws {
        let download = try manager.append(testURL)
        manager.pause(download)
        XCTAssertEqual(manager.state.status, .paused)
    }

    func testStatusIsIdleIfAnyItemHasIdleStatus() throws {
        let download = try manager.append(testURL)
        try manager.append(URL(string: "http://download2")!)
        manager.pause(download)
        XCTAssertEqual(manager.state.status, .downloading)
    }

    func testStatusChangesToFinishedIfOnlyItemFinished() throws {
        let download = try manager.append(testURL)
        download.status = .finished
        XCTAssertEqual(manager.state.status, .finished)
    }

    func testStatusChangesToPausedIfAllUnfinishedDownloadsArePaused() throws {
        let download1 = try manager.append(URL(string: "http://test1")!)
        let download2 = try manager.append(URL(string: "http://test2")!)
        download1.status = .finished
        manager.pause(download2)
        XCTAssertEqual(manager.state.status, .paused)
    }

    func testStatusChangesToFailedIfAllUnfinishedDownloadsAreFailed() throws {
        let download1 = try manager.append(URL(string: "http://test1")!)
        let download2 = try manager.append(URL(string: "http://test2")!)
        download1.status = .finished
        download2.status = .failed(.serverError(statusCode: 500))
        XCTAssertEqual(
            manager.state.status,
            .failed(.aggregate(errors: [.serverError(statusCode: 500)]))
        )
    }
}

// MARK: - Progress.

extension DownloadManagerTests {
    func testInitialProgress() {
        XCTAssertEqual(manager.state.progress.expected, 0)
        XCTAssertEqual(manager.state.progress.received, 0)
    }

    func testProgressUpdatedWhenItemAddedToQueue() throws {
        try manager.append(testURL, estimatedSize: 100)
        XCTAssertEqual(manager.state.progress.expected, 100)
        XCTAssertEqual(manager.state.progress.received, 0)
    }

    func testProgressUpdatedWhenDataIsDownloaded() throws {
        let download = try manager.append(testURL, estimatedSize: 100)
        try manager.append(URL(string: "http://download2")!, estimatedSize: 100)

        download.progress.received = 100

        XCTAssertEqual(manager.state.progress.received, 100)
        XCTAssertEqual(manager.state.progress.expected, 200)
        XCTAssertEqual(manager.state.progress.fractionCompleted, 0.5)
    }

    func testProgressUpdatedAfterCancellation() throws {
        let download1 = try manager.append(testURL, estimatedSize: 100)
        let download2 = try manager.append(URL(string: "http://download2")!, estimatedSize: 100)

        download1.progress.received = 100

        manager.remove(download1)

        XCTAssertEqual(manager.state.progress.received, 0)
        XCTAssertEqual(manager.state.progress.expected, 100)
        XCTAssertEqual(manager.state.progress.fractionCompleted, 0)

        manager.remove(download2)

        XCTAssertEqual(manager.state.progress.received, 0)
        XCTAssertEqual(manager.state.progress.expected, 0)
        XCTAssertEqual(manager.state.progress.fractionCompleted, 0)
    }
}

extension DownloadManagerTests {
    func testAggregateState() throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!

        let download1 = try manager.append(url1, estimatedSize: 100)
        let download2 = try manager.append(url2, estimatedSize: 100)

        download1.progress.received = 100

        let state = DownloadManager.state(of: [download1, download2])
        XCTAssertEqual(state.status, .downloading)
        XCTAssertEqual(state.progress.expected, 200)
        XCTAssertEqual(state.progress.received, 100)
    }

    func testAggregateStateUpdated() throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!

        let download1 = try manager.append(url1, estimatedSize: 100)
        let download2 = try manager.append(url2, estimatedSize: 100)

        let state = DownloadManager.state(of: [download1, download2])

        download1.progress.received = 100
        XCTAssertEqual(state.progress.received, 100)

        download2.progress.received = 100
        XCTAssertEqual(state.progress.received, 200)
    }
}

// MARK: - Queue.

extension DownloadManagerTests {
    func testEmptyQueue() throws {
        XCTAssertEqual(manager.queue.downloads, [])
    }

    func testDownloadAppendsQueue() throws {
        try manager.append(testURL)
        assertCurrentQueueEquals([
            Download(
                url: testURL,
                status: .downloading
            )
        ])
    }

    func testDownloadDuplicateURLReplacesFinishedDownload() throws {
        let download = try manager.append(testURL, estimatedSize: 100)
        manager.append(download)
        download.status = .finished

        let dupe = try manager.append(testURL, estimatedSize: 100)
        manager.append(dupe)
        XCTAssertEqual(dupe.status, .downloading)
    }

    func testFirstItemInQueueStartsDownloadingAutomatically() throws {
        let download = try manager.append(testURL)
        XCTAssertEqual(download.status, .downloading)
    }

    func testDownloadCreatesTask() throws {
        let download = try manager.append(testURL, estimatedSize: 100)
        XCTAssertEqual(delegate.requestedURLs, [testURL])
        XCTAssertEqual(delegate.tasks[download.id]?.countOfBytesClientExpectsToReceive, 100)
        XCTAssertEqual(delegate.tasks[download.id]?.state, .running)
    }

    func testBatchDownloadCreatesTasks() throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!
        let download1 = try manager.register(url1, estimatedSize: 0)
        let download2 = try manager.register(url2, estimatedSize: 0)

        manager.append(download1, download2)

        XCTAssertEqual(delegate.requestedURLs, [url1, url2])
        XCTAssertEqual(delegate.tasks[download1.id]?.state, .running)
        XCTAssertEqual(delegate.tasks[download2.id]?.state, .suspended)
    }

    func testConcurrentDownloads() throws {
        manager.maxConcurrentDownloads = 2
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!
        let url3 = URL(string: "http://test3")!
        let download1 = try manager.register(url1, estimatedSize: 0)
        let download2 = try manager.register(url2, estimatedSize: 0)
        let download3 = try manager.register(url3, estimatedSize: 0)

        manager.append(download1, download2, download3)

        XCTAssertEqual(delegate.requestedURLs, [url1, url2, url3])
        XCTAssertEqual(delegate.tasks[download1.id]?.state, .running)
        XCTAssertEqual(delegate.tasks[download2.id]?.state, .running)
        XCTAssertEqual(delegate.tasks[download3.id]?.state, .suspended)
    }

    func testPause() throws {
        let download = try manager.append(testURL)
        manager.pause(download)

        let task = delegate.tasks[download.id]!

        let expectation = self.expectation(description: "task state changes to `canceling`")
        expectation.assertForOverFulfill = false

        observation = task.observe(\.state, options: [.initial]) { task, _ in
            if task.state == .canceling || task.state == .completed {
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 0.5)

        XCTAssertEqual(download.status, .paused)
    }

    func testPauseFinishedDownloadHasNoEffect() throws {
        let download = try manager.append(testURL)
        download.status = .finished
        manager.pause(download)
        XCTAssertEqual(download.status, .finished)
    }

    func testResume() throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!
        let download1 = try manager.append(url1)
        let download2 = try manager.append(url2)

        manager.pause(download1)
        manager.pause(download2)

        manager.resume(download1)

        let task = delegate.tasks[download1.id]!

        assertCurrentQueueEquals([
            .init(url: url1, status: .downloading),
            .init(url: url2, status: .paused)
        ])
        XCTAssertEqual(task.state, .running)
        XCTAssertEqual(delegate.requestedURLs, [url1, url2, url1])
    }

    func testResumeFinishedDownloadHasNoEffect() throws {
        let download = try manager.append(testURL)
        let originalTask = delegate.tasks[download.id]
        manager.pause(download)
        download.status = .finished
        manager.resume(download)
        XCTAssertEqual(download.status, .finished)
        XCTAssertEqual(
            originalTask?.taskIdentifier,
            delegate.tasks[download.id]?.taskIdentifier
        )
    }

    func testCancel() throws {
        let download = try manager.append(testURL)
        manager.remove(download)

        let task = delegate.tasks[download.id]!

        let expectation = self.expectation(description: "task state changes to `canceling`")
        expectation.assertForOverFulfill = false

        observation = task.observe(\.state, options: [.initial]) { task, _ in
            if task.state == .canceling || task.state == .completed {
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 0.5)
    }

    func testCancelRemovesDownloadFromQueue() throws {
        let download = try manager.append(testURL)

        let task = delegate.tasks[download.id]!

        let expectation = self.expectation(description: "data task state changes to `canceling`")
        expectation.assertForOverFulfill = false

        observation = task.observe(\.state, options: [.initial]) { task, _ in
            if task.state == .canceling { expectation.fulfill() }
        }

        manager.remove(download)

        waitForExpectations(timeout: 0.1)

        XCTAssertEqual(manager.queue.downloads, [])
    }

    func testCancelStartsDownloadingNextItemInQueue() throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!

        let download1 = try manager.append(url1)
        try manager.append(url2)

        manager.remove(download1)
        assertCurrentQueueEquals([
            Download(url: url2, status: .downloading)
        ])
    }

    func testPauseStartsDownloadingNextItemInQueue() throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!

        let download1 = try manager.append(url1)
        try manager.append(url2)

        manager.pause(download1)

        assertCurrentQueueEquals([
            Download(url: url1, status: .paused),
            Download(url: url2, status: .downloading)
        ])
    }
}

// MARK: - Delegate.

extension DownloadManagerTests {
    func testAddDownloadPublishesNewQueue() throws {
        try manager.append(testURL)

        assertQueueChanges(
            [[Download(url: testURL, status: .downloading)]]
        )
    }

    func testBatchDownloadSingleTransaction() throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!
        let download1 = try manager.register(url1, estimatedSize: 0)
        let download2 = try manager.register(url2, estimatedSize: 0)

        manager.append(download1, download2)

        assertQueueChanges([
            [
                Download(id: download1.id, url: url1, status: .downloading),
                Download(id: download2.id, url: url2, status: .idle)
            ]
        ])
    }

    func testPauseDoesntPublishNewQueue() throws {
        let download = try manager.append(testURL)
        manager.pause(download)

        XCTAssertEqual(
            delegate.queueChanges.map { queue in queue.map { $0.status } },
            [
                [.downloading]
            ]
        )
    }

    func testCancelPublishesNewQueue() throws {
        let download = try manager.append(testURL)
        manager.remove(download)

        assertQueueChanges([
            [Download(url: testURL, status: .downloading)],
            []
        ])
    }

    func testBatchCancelSingleTransaction() throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!
        let download1 = try manager.register(url1, estimatedSize: 0)
        let download2 = try manager.register(url2, estimatedSize: 0)

        manager.append(download1, download2)
        manager.remove(download1, download2)

        assertQueueChanges([
            [
                Download(url: url1, status: .downloading),
                Download(url: url2, status: .idle)
            ],
            // All downloads were cancelled a single transaction.
            []
        ]
        )
    }

    func testCancelProducesResumeData() throws {
        let download = try manager.append(testURL)

        let expectation = self.expectation(description: "resume data should be produced")

        manager.remove(download)

        delegate.$resumeData.dropFirst().sink { _ in
            expectation.fulfill()
        }.store(in: &cancellables)

        waitForExpectations(timeout: 0.1)

        XCTAssertNotNil(delegate.resumeData[download.id])
    }

    func testStatusChanges() throws {
        let download = try manager.append(testURL)
        manager.pause(download)
        manager.remove(download)
        XCTAssertEqual(delegate.statusChanges, [
            .downloading,
            .paused,
            .idle
        ])
    }
}

extension DownloadManager {
    @discardableResult
    func register(_ url: URL, estimatedSize: Int = 0) throws -> Download {
        let request = URLRequest(url: url)
        let download = Download(
            request: request,
            progress: DownloadProgress(expected: estimatedSize)
        )
        return download
    }

    @discardableResult
    func append(_ url: URL, estimatedSize: Int = 0) throws -> Download {
        let download = try register(url, estimatedSize: estimatedSize)
        self.append(download)
        return download
    }
}

extension Download {
    convenience init(
        id: ID = .init(),
        url: URL,
        status: DownloadState.Status
    ) {
        self.init(
            id: id,
            url: url,
            status: status,
            progress: DownloadProgress()
        )
    }
}
