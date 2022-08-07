//
//  DownloadManagerIntegrationTests.swift
//  DownloadManager
//
//  Created by Lachlan Charlick on 1/3/21.
//

@testable import DownloadManager
import Swifter
import XCTest

final class DownloadManagerIntegrationTests: XCTestCase {
    func testDownloadSingleItem() throws {
        let data = try Data(randomOfLength: 1000)
        let url = URL(string: "http://localhost:8080/test1")!

        let server = try HttpServer.serve { path in
            assert(path == url.path)
            return .ok(.data(data, contentType: "audio/mpeg"))
        }

        let expectation = expectation(
            description: "a download should finish"
        )

        let delegate = DelegateSpy(downloadStatusDidChangeHandler: {
            if $0.url == url, $0.status == .finished {
                expectation.fulfill()
            }
        })

        let manager = DownloadManager(
            sessionConfiguration: .default,
            delegate: delegate
        )
        let download = try manager.append(url)

        waitForExpectations(timeout: 0.5)

        server.stop()

        XCTAssertEqual(download.status, .finished)
        XCTAssertEqual(download.progress.expected, data.count)
        XCTAssertEqual(download.progress.received, data.count)
        XCTAssertEqual(delegate.requestedURLs, [url])
        XCTAssertEqual(delegate.tasks[download.id]?.state, .completed)
    }

    func testDownloadMultipleItems() throws {
        let data1 = try Data(randomOfLength: 1000)
        let data2 = try Data(randomOfLength: 1500)

        let url1 = URL(string: "http://localhost:8080/test1")!
        let url2 = URL(string: "http://localhost:8080/test2")!

        let server = try HttpServer.serve { path in
            switch path {
            case url1.path:
                return .ok(.data(data1, contentType: "audio/mpeg"))
            case url2.path:
                return .ok(.data(data2, contentType: "audio/mpeg"))
            default:
                return .badRequest(nil)
            }
        }

        let expectation = expectation(
            description: "both downloads should finish"
        )

        let delegate = DelegateSpy(downloadStatusDidChangeHandler: {
            if $0.url == url2, $0.status == .finished {
                expectation.fulfill()
            }
        })

        let manager = DownloadManager(
            sessionConfiguration: .default,
            delegate: delegate
        )
        let download1 = try manager.append(url1)
        let download2 = try manager.append(url2)

        waitForExpectations(timeout: 0.5)

        server.stop()

        XCTAssertEqual(delegate.requestedURLs, [url1, url2])

        XCTAssertEqual(download1.status, .finished)
        XCTAssertEqual(download1.progress.expected, data1.count)
        XCTAssertEqual(download1.progress.received, data1.count)
        XCTAssertEqual(delegate.tasks[download1.id]?.state, .completed)

        XCTAssertEqual(download2.status, .finished)
        XCTAssertEqual(download2.progress.expected, data2.count)
        XCTAssertEqual(download2.progress.received, data2.count)
        XCTAssertEqual(delegate.tasks[download2.id]?.state, .completed)
    }

    func testDownloadFailure() throws {
        let url = URL(string: "http://localhost:8080/test1")!

        let server = try HttpServer.serve { path in
            assert(path == url.path)
            return .internalServerError
        }

        let expectation = expectation(
            description: "download status should change to `failed`"
        )

        let delegate = DelegateSpy(downloadStatusDidChangeHandler: { item in
            guard item.url == url else {
                return
            }

            switch item.status {
            case let .failed(error):
                switch error {
                case let .serverError(statusCode: code) where code == 500:
                    expectation.fulfill()
                default:
                    break
                }
            default:
                break
            }
        })

        let manager = DownloadManager(
            sessionConfiguration: .default,
            delegate: delegate
        )

        let download = try manager.append(url)

        waitForExpectations(timeout: 0.5)

        server.stop()

        XCTAssertEqual(download.status, .failed(.serverError(statusCode: 500)))
    }
}
