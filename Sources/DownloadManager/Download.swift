//
//  Download.swift
//  DownloadManager
//
// Created by Lachlan Charlick on 2/3/21.
//

import Combine
import Foundation

/// Represents a single download task that can be added to a `DownloadManager`.
@MainActor public class Download: ObservableObject, Identifiable {
    public let id: ID

    private(set) var request: URLRequest

    public var url: URL {
        request.url!
    }

    @Published
    public private(set) var status: DownloadStatus {
        didSet {
            NotificationCenter.default.post(
                .init(name: .downloadStatusChanged, object: self, userInfo: nil)
            )
        }
    }

    public var progress: DownloadProgress
    public var userInfo = [String: Any]()

    public init(
        id: ID = .init(),
        request: URLRequest,
        status: DownloadStatus = .idle,
        progress: DownloadProgress
    ) {
        self.id = id
        self.request = request
        self.status = status
        self.progress = progress
    }

    public convenience init(
        id: ID = .init(),
        url: URL,
        status: DownloadStatus = .idle,
        progress: DownloadProgress
    ) {
        self.init(
            id: id,
            request: URLRequest(url: url),
            status: status,
            progress: progress
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

public extension Download {
    var statusPublisher: AnyPublisher<DownloadStatus, Never> {
        $status
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}

extension Download: Hashable {
    public static func == (lhs: Download, rhs: Download) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension Download: CustomStringConvertible {
    public var description: String {
        "\(id) | \(status) | \(progress)"
    }
}

extension NSNotification.Name {
    static let downloadStatusChanged = Notification.Name(
        "me.charlick.download-manager.download-status-changed"
    )
}
