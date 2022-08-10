//
//  DownloadStatus.swift
//  DownloadManager
//
//  Created by Lachlan Charlick on 10/8/2022.
//

import Foundation

public enum DownloadStatus: Hashable {
    case idle
    case downloading
    case paused
    case finished
    case failed(DownloadError)
}
