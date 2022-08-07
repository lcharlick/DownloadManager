//
//  DownloadManagerTests.swift
//  DownloadManager
//
//  Created by Lachlan Charlick on 26/2/21.
//

import Combine
@testable import DownloadManager
import Swifter
import XCTest

private let testURL = URL(string: "http://test")!

final class DownloadManagerTests: XCTestCase {
    private var observation: NSKeyValueObservation?
    private var cancellables: Set<AnyCancellable> = []
    // swiftlint:disable:next weak_delegate
    private var delegate: DelegateSpy!
    private var manager: DownloadManager!

    override func setUpWithError() throws {
        cancellables = []
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
    ) async {
        assertDownloadsEquals(await manager.queue.downloads, expected, file: file, line: line)
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
        let status = await manager.state.status
        XCTAssertEqual(status, .idle)
    }

    func testStatusChangesIfItemAddedToQueue() async throws {
        try await manager.append(testURL)
        let status = await manager.state.status
        XCTAssertEqual(status, .downloading)
    }

    func testStatusChangesToIdleIfItemRemovedFromQueue() async throws {
        let download = try await manager.append(testURL)
        await manager.remove(download)
        let status = await manager.state.status
        XCTAssertEqual(status, .idle)
    }

    func testStatusChangesToPausedIfOnlyItemPaused() async throws {
        let download = try await manager.append(testURL)
        await manager.pause(download)
        let status = await manager.state.status
        XCTAssertEqual(status, .paused)
    }

    func testStatusIsIdleIfAnyItemHasIdleStatus() async throws {
        let download = try await manager.append(testURL)
        try await manager.append(URL(string: "http://download2")!)
        await manager.pause(download)
        let status = await manager.state.status
        XCTAssertEqual(status, .downloading)
    }

    func testStatusChangesToFinishedIfOnlyItemFinished() async throws {
        let download = try await manager.append(testURL)
        download.status = .finished
        let status = await manager.state.status
        XCTAssertEqual(status, .finished)
    }

    func testStatusChangesToPausedIfAllUnfinishedDownloadsArePaused() async throws {
        let download1 = try await manager.append(URL(string: "http://test1")!)
        let download2 = try await manager.append(URL(string: "http://test2")!)
        download1.status = .finished
        await manager.pause(download2)
        let status = await manager.state.status
        XCTAssertEqual(status, .paused)
    }

    func testStatusChangesToFailedIfAllUnfinishedDownloadsAreFailed() async throws {
        let download1 = try await manager.append(URL(string: "http://test1")!)
        let download2 = try await manager.append(URL(string: "http://test2")!)
        download1.status = .finished
        download2.status = .failed(.serverError(statusCode: 500))
        let status = await manager.state.status
        XCTAssertEqual(status, .failed(.aggregate(errors: [.serverError(statusCode: 500)]))
        )
    }
}

// MARK: - Progress.

extension DownloadManagerTests {
    func testInitialProgress() async {
        let progress = await manager.state.progress

        XCTAssertEqual(progress.expected, 0)
        XCTAssertEqual(progress.received, 0)
    }

    func testProgressUpdatedWhenItemAddedToQueue() async throws {
        try await manager.append(testURL, estimatedSize: 100)
        let progress = await manager.state.progress

        XCTAssertEqual(progress.expected, 100)
        XCTAssertEqual(progress.received, 0)
    }

    func testProgressUpdatedWhenDataIsDownloaded() async throws {
        let download = try await manager.append(testURL, estimatedSize: 100)
        try await manager.append(URL(string: "http://download2")!, estimatedSize: 100)

        download.progress.received = 100

        let progress = await manager.state.progress

        XCTAssertEqual(progress.received, 100)
        XCTAssertEqual(progress.expected, 200)
        XCTAssertEqual(progress.fractionCompleted, 0.5)
    }

    func testProgressUpdatedAfterCancellation() async throws {
        let download1 = try await manager.append(testURL, estimatedSize: 100)
        let download2 = try await manager.append(URL(string: "http://download2")!, estimatedSize: 100)

        download1.progress.received = 100

        await manager.remove(download1)

        let progress1 = await manager.state.progress

        XCTAssertEqual(progress1.received, 0)
        XCTAssertEqual(progress1.expected, 100)
        XCTAssertEqual(progress1.fractionCompleted, 0)

        await manager.remove(download2)

        let progress2 = await manager.state.progress

        XCTAssertEqual(progress2.received, 0)
        XCTAssertEqual(progress2.expected, 0)
        XCTAssertEqual(progress2.fractionCompleted, 0)
    }
}

extension DownloadManagerTests {
    func testAggregateState() async throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!

        let download1 = try await manager.append(url1, estimatedSize: 100)
        let download2 = try await manager.append(url2, estimatedSize: 100)

        download1.progress.received = 100

        let state = DownloadManager.state(of: [download1, download2])
        XCTAssertEqual(state.status, .downloading)
        XCTAssertEqual(state.progress.expected, 200)
        XCTAssertEqual(state.progress.received, 100)
    }

    func testAggregateStateUpdated() async throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!

        let download1 = try await manager.append(url1, estimatedSize: 100)
        let download2 = try await manager.append(url2, estimatedSize: 100)

        let state = DownloadManager.state(of: [download1, download2])

        download1.progress.received = 100
        XCTAssertEqual(state.progress.received, 100)

        download2.progress.received = 100
        XCTAssertEqual(state.progress.received, 200)
    }
}

// MARK: - Queue.

extension DownloadManagerTests {
    func testEmptyQueue() async throws {
        await assertCurrentQueueEquals([])
    }

    func testDownloadAppendsQueue() async throws {
        try await manager.append(testURL)
        await assertCurrentQueueEquals([
            Download(
                url: testURL,
                status: .downloading
            ),
        ])
    }

    func testDownloadDuplicateURLReplacesFinishedDownload() async throws {
        let download = try await manager.append(testURL, estimatedSize: 100)
        await manager.append(download)
        download.status = .finished

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
        let download1 = try await manager.register(url1, estimatedSize: 0)
        let download2 = try await manager.register(url2, estimatedSize: 0)

        await manager.append(download1, download2)

        XCTAssertEqual(delegate.requestedURLs, [url1, url2])
        XCTAssertEqual(delegate.tasks[download1.id]?.state, .running)
        XCTAssertEqual(delegate.tasks[download2.id]?.state, .suspended)
    }

    func testConcurrentDownloads() async throws {
        await manager.setMaxConcurrentDownloads(2)
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!
        let url3 = URL(string: "http://test3")!
        let download1 = try await manager.register(url1, estimatedSize: 0)
        let download2 = try await manager.register(url2, estimatedSize: 0)
        let download3 = try await manager.register(url3, estimatedSize: 0)

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

        await waitForExpectations(timeout: 0.5)

        XCTAssertEqual(download.status, .paused)
    }

    func testPauseFinishedDownloadHasNoEffect() async throws {
        let download = try await manager.append(testURL)
        download.status = .finished
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

        await assertCurrentQueueEquals([
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
        download.status = .finished
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

        await waitForExpectations(timeout: 0.5)
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

        await waitForExpectations(timeout: 0.1)

        await assertCurrentQueueEquals([])
    }

    func testCancelStartsDownloadingNextItemInQueue() async throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!

        let download1 = try await manager.append(url1)
        try await manager.append(url2)

        await manager.remove(download1)
        await assertCurrentQueueEquals([
            Download(url: url2, status: .downloading),
        ])
    }

    func testPauseStartsDownloadingNextItemInQueue() async throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!

        let download1 = try await manager.append(url1)
        try await manager.append(url2)

        await manager.pause(download1)

        await assertCurrentQueueEquals([
            Download(url: url1, status: .paused),
            Download(url: url2, status: .downloading),
        ])
    }
}

// MARK: - Delegate.

extension DownloadManagerTests {
    func testAddDownloadPublishesNewQueue() async throws {
        try await manager.append(testURL)

        assertQueueChanges(
            [[Download(url: testURL, status: .downloading)]]
        )
    }

    func testBatchDownloadSingleTransaction() async throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!
        let download1 = try await manager.register(url1, estimatedSize: 0)
        let download2 = try await manager.register(url2, estimatedSize: 0)

        await manager.append(download1, download2)

        assertQueueChanges([
            [
                Download(id: download1.id, url: url1, status: .downloading),
                Download(id: download2.id, url: url2, status: .idle),
            ],
        ])
    }

    func testPauseDoesntPublishNewQueue() async throws {
        let download = try await manager.append(testURL)
        await manager.pause(download)

        XCTAssertEqual(
            delegate.queueChanges.map { queue in queue.map(\.status) },
            [
                [.downloading],
            ]
        )
    }

    func testCancelPublishesNewQueue() async throws {
        let download = try await manager.append(testURL)
        await manager.remove(download)

        assertQueueChanges([
            [Download(url: testURL, status: .downloading)],
            [],
        ])
    }

    func testBatchCancelSingleTransaction() async throws {
        let url1 = URL(string: "http://test1")!
        let url2 = URL(string: "http://test2")!
        let download1 = try await manager.register(url1, estimatedSize: 0)
        let download2 = try await manager.register(url2, estimatedSize: 0)

        await manager.append(download1, download2)
        await manager.remove(download1, download2)

        assertQueueChanges([
            [
                Download(url: url1, status: .downloading),
                Download(url: url2, status: .idle),
            ],
            // All downloads were cancelled a single transaction.
            [],
        ]
        )
    }

    func testCancelProducesResumeData() async throws {
        let download = try await manager.append(testURL)

        let expectation = expectation(description: "resume data should be produced")

        await manager.remove(download)

        delegate.$resumeData.dropFirst().sink { _ in
            expectation.fulfill()
        }.store(in: &cancellables)

        await waitForExpectations(timeout: 0.1)

        XCTAssertNotNil(delegate.resumeData[download.id])
    }

    func testStatusChanges() async throws {
        let download = try await manager.append(testURL)
        await manager.pause(download)
        await manager.remove(download)
        XCTAssertEqual(delegate.statusChanges, [
            .downloading,
            .paused,
            .idle,
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
    func append(_ url: URL, estimatedSize: Int = 0) async throws -> Download {
        let download = try register(url, estimatedSize: estimatedSize)
        await append(download)
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
