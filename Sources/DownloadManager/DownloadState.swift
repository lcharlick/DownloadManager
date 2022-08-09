//
//  DownloadState.swift
//  DownloadManager
//
//  Created by Lachlan Charlick on 26/2/21.
//

import Foundation

public enum DownloadStatus: Hashable {
    case idle
    case downloading
    case paused
    case finished
    case failed(DownloadError)
}

public enum DownloadError: Swift.Error, Hashable {
    case serverError(statusCode: Int)
    case transportError(URLError, localizedDescription: String)
    case unknown(code: Int, localizedDescription: String)
    case aggregate(errors: Set<DownloadError>)
}

//extension DownloadState: CustomStringConvertible {
//    public var description: String {
//        "\(status) (\(progress.received) / \(progress.expected))"
//    }
//}
//
//extension DownloadState: Equatable {
//    public static func == (lhs: DownloadState, rhs: DownloadState) -> Bool {
//        lhs.status == rhs.status
//            && lhs.progress == rhs.progress
////            && lhs.progress.expected == rhs.progress.expected
//    }
//}
