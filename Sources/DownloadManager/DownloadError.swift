//
//  DownloadError.swift
//  DownloadManager
//
//  Created by Lachlan Charlick on 10/8/2022.
//

import Foundation

public enum DownloadError: Swift.Error, Hashable {
    case serverError(statusCode: Int)
    case transportError(URLError, localizedDescription: String)
    case unknown(code: Int, localizedDescription: String)
    case aggregate(errors: Set<DownloadError>)

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .serverError(let statusCode):
            hasher.combine(0)
            hasher.combine(statusCode)
        case .transportError(let error, let localizedDescription):
            // Hash the code, not the error: Android's Foundation traps when it hashes an NSError,
            // which URLError wraps.
            hasher.combine(1)
            hasher.combine(error.code)
            hasher.combine(localizedDescription)
        case .unknown(let code, let localizedDescription):
            hasher.combine(2)
            hasher.combine(code)
            hasher.combine(localizedDescription)
        case .aggregate(let errors):
            hasher.combine(3)
            hasher.combine(errors)
        }
    }
}
