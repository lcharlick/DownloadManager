//
//  Download.swift
//  DownloadManager
//
// Created by Lachlan Charlick on 2/3/21.
//

import Foundation

/// Represents a single download task that can be added to a `DownloadManager`.
@Observable
@MainActor public class Download: Identifiable {
    public let id: ID

    private(set) var request: URLRequest

    public var url: URL {
        request.url!
    }

    public private(set) var status: DownloadStatus {
        didSet {
            NotificationCenter.default.post(
                .init(name: .downloadStatusChanged, object: self, userInfo: nil)
            )
        }
    }

    public var expected: Int64 = 0
    public var received: Int64 = 0

    public var fractionCompleted: Double {
        expected > 0 ? Double(received) / Double(expected) : 0
    }

    public var userInfo = [String: Any]()

    public init(
        id: ID = .init(),
        request: URLRequest,
        status: DownloadStatus = .idle,
        expected: Int64 = 0,
        received: Int64 = 0
    ) {
        self.id = id
        self.request = request
        self.status = status
        self.expected = expected
        self.received = received
    }

    public convenience init(
        id: ID = .init(),
        url: URL,
        status: DownloadStatus = .idle,
        expected: Int64 = 0,
        received: Int64 = 0
    ) {
        self.init(
            id: id,
            request: URLRequest(url: url),
            status: status,
            expected: expected,
            received: received
        )
    }

    func setStatus(_ status: DownloadStatus) {
        self.status = status
    }

    func setRequest(_ request: URLRequest) {
        self.request = request
    }

    public typealias ID = UUID
}

extension Download: Hashable {
    nonisolated public static func == (lhs: Download, rhs: Download) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension Download: @MainActor CustomStringConvertible {
    public var description: String {
        "\(id) | \(status) | \(received)/\(expected) (\(String(format: "%.1f", fractionCompleted * 100))%)"
    }
}

extension NSNotification.Name {
    static let downloadStatusChanged = Notification.Name(
        "me.charlick.download-manager.download-status-changed"
    )
}
