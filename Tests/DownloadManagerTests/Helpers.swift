//
//  Helpers.swift
//  DownloadManager
//
//  Created by Lachlan Charlick on 26/2/21.
//

import XCTest
import Difference
import Swifter
@testable import DownloadManager

public func XCTAssertEqual<T: Equatable>(_ received: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do {
        let expected = try expected()
        let received = try received()
        XCTAssertTrue(expected == received, "Found difference for \n" + diff(expected, received).joined(separator: ", "), file: file, line: line)
    } catch {
        XCTFail("Caught error while testing: \(error)", file: file, line: line)
    }
}

extension URLSessionTask.State: CustomStringConvertible {
    public var description: String {
        switch self {
        case .canceling:
            return "canceling"
        case .running:
            return "running"
        case .suspended:
            return "suspended"
        case .completed:
            return "completed"
        @unknown default:
            return "unknown"
        }
    }
}

extension Data {
    init(randomOfLength length: Int) throws {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw SecError(code: status)
        }
        self.init(bytes)
    }

    struct SecError: Error {
        let code: Int32
    }
}

class DelegateSpy: DownloadManagerDelegate {
    var queueChanges = [[Download]]()
    var statusChanges = [DownloadState.Status]()

    var requestedURLs = [URL]()
    var tasks = [Download.ID: URLSessionDownloadTask]()

    @Published
    var resumeData = [Download.ID: Data]()

    private let downloadStatusDidChangeHandler: (Download) -> Void

    init(
        downloadStatusDidChangeHandler: @escaping (Download) -> Void
    ) {
        self.downloadStatusDidChangeHandler = downloadStatusDidChangeHandler
    }

    func downloadManagerStatusDidChange(_ status: DownloadState.Status) {
        statusChanges.append(status)
    }

    func downloadDidUpdateProgress(_ download: Download) {
    }

    func downloadThroughputDidChange(_ throughput: Int) {
    }

    func downloadStatusDidChange(_ download: Download) {
        downloadStatusDidChangeHandler(download)
    }

    func download(_ download: Download, didCreateTask task: URLSessionDownloadTask) {
        requestedURLs.append(download.url)
        tasks[download.id] = task
    }

    func download(_ download: Download, didReconnectTask: URLSessionDownloadTask) {
    }

    func downloadQueueDidChange(_ downloads: [Download]) {
        queueChanges.append(downloads.map {
            Download(
                url: $0.url,
                status: $0.status
            )
        })
    }

    func download(_ download: Download, didCancelWithResumeData data: Data?) {
        resumeData[download.id] = data ?? Data()
    }

    func download(_ download: Download, didFinishDownloadingTo location: URL) {
    }

    func resumeDataForDownload(_ download: Download) -> Data? {
        resumeData[download.id]
    }

    func downloadManagerDidFinishBackgroundDownloads() {
    }
}

extension HttpServer {
    static func serveData(
        _ data: Data,
        at path: String = "/",
        port: UInt16 = 8080
    ) throws -> HttpServer {
        let server = HttpServer()

        server[path] = { _ in
            .ok(.data(data, contentType: "audio/mpeg"))
        }

        try server.start(port)
        return server
    }

    static func serve(
        port: UInt16 = 8080,
        handler: @escaping (String) -> HttpResponse
    ) throws -> HttpServer {
        let server = HttpServer()

        server["/:path"] = { request in
            handler(request.path)
        }

        try server.start(port)
        return server
    }
}
