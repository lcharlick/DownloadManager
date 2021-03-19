//
//  Download.swift
//  DownloadManager
//
// Created by Lachlan Charlick on 2/3/21.
//

import Foundation
import Combine

/// Represents a single download task that can be added to a `DownloadManager`.
public class Download: ObservableObject, Identifiable {
    public let id: ID
    var request: URLRequest
    public var url: URL {
        request.url!
    }

    @Published
    private var state: DownloadState

    public var userInfo = [String: Any]()

    public init(
        id: ID = .init(),
        request: URLRequest,
        status: DownloadState.Status = .idle,
        progress: DownloadProgress
    ) {
        self.id = id
        self.request = request
        self.state = .init(
            status: status,
            progress: progress
        )
    }

    public convenience init(
        id: ID = .init(),
        url: URL,
        status: DownloadState.Status = .idle,
        progress: DownloadProgress
    ) {
        self.init(
            id: id,
            request: URLRequest(url: url),
            status: status,
            progress: progress
        )
    }

    public typealias ID = UUID
}

public extension Download {
    var statusPublisher: AnyPublisher<DownloadState.Status, Never> {
        $state.map { $0.status }
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    var status: DownloadState.Status {
        get {
            state.status
        }
        set {
            state.status = newValue
            NotificationCenter.default.post(
                .init(name: .downloadStatusChanged, object: self, userInfo: nil)
            )
        }
    }

    var progress: DownloadProgress {
        state.progress
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
        "\(id) | \(state)"
    }
}

extension NSNotification.Name {
    static let downloadStatusChanged = Notification.Name(
        "me.charlick.download-manager.download-status-changed"
    )
}
