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
}
