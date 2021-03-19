//
//  DownloadState.swift
//  DownloadManager
//
//  Created by Lachlan Charlick on 26/2/21.
//

import Foundation

/// Represents the state of a queued download.
public struct DownloadState {
    public var status: Status
    public let progress: DownloadProgress

    public init(
        status: Status = .idle,
        progress: DownloadProgress = .init()
    ) {
        self.status = status
        self.progress = progress
    }

    public enum Status: Hashable {
        case idle
        case downloading
        case paused
        case finished
        case failed(Error)
    }

    public enum Error: Swift.Error, Hashable {
        case serverError(statusCode: Int)
        case transportError(URLError, localizedDescription: String)
        case unknown(code: Int, localizedDescription: String)
        case aggregate(errors: Set<Error>)
    }
}

extension DownloadState: CustomStringConvertible {
    public var description: String {
        "\(status) (\(progress.received) / \(progress.expected))"
    }
}

extension DownloadState: Equatable {
    public static func == (lhs: DownloadState, rhs: DownloadState) -> Bool {
        lhs.status == rhs.status
            && lhs.progress.received == rhs.progress.received
            && lhs.progress.expected == rhs.progress.expected
    }
}
