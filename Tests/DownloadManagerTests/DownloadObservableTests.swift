import XCTest
@testable import DownloadManager

@MainActor
final class DownloadObservableTests: XCTestCase {

    func testDownloadCreation() {
        let download = Download(url: URL(string: "http://test.com")!)
        XCTAssertEqual(download.expected, 0)
        XCTAssertEqual(download.received, 0)
        XCTAssertEqual(download.fractionCompleted, 0)
    }

    func testDownloadProgress() {
        let download = Download(url: URL(string: "http://test.com")!, expected: 100)
        download.received = 50
        XCTAssertEqual(download.fractionCompleted, 0.5)
    }

    func testDownloadManagerCreation() {
        let manager = DownloadManager(sessionConfiguration: .default)
        XCTAssertEqual(manager.fractionCompleted, 0)
        XCTAssertEqual(manager.totalExpected, 0)
        XCTAssertEqual(manager.totalReceived, 0)
        XCTAssertEqual(manager.status, .idle)
    }
}