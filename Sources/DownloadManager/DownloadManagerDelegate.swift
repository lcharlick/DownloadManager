//
//  DownloadManagerDelegate.swift
//  DownloadManager
//
//  Created by Lachlan Charlick on 3/3/21.
//

import Foundation

public protocol DownloadManagerDelegate: AnyObject {
    /// Tells the delegate when the download manager status has changed.
    func downloadManagerStatusDidChange(_ status: DownloadState.Status)

    /// Tells the delegate when the download queue has changed.
    func downloadQueueDidChange(_ downloads: [Download])

    /// Periodically informs the delegate about the download manager’s throughput.
    func downloadThroughputDidChange(_ throughput: Int)

    /// Periodically informs the delegate about the download’s progress.
    func downloadDidUpdateProgress(_ download: Download)

    /// Tells the delegate when a download item’s status has changed.
    func downloadStatusDidChange(_ download: Download)

    /// Tells the delegate when a download task has been created.
    func download(_ download: Download, didCreateTask: URLSessionDownloadTask)

    /// Tells the delegate when a background download task reconnects.
    func download(_ download: Download, didReconnectTask: URLSessionDownloadTask)

    /// Tells the delegate that a download task has been finished downloading.
    /// The file at `location` must be opened or moved before this method returns.
    func download(_ download: Download, didFinishDownloadingTo location: URL)

    /// Tells the delegate when a download task has been cancelled.
    /// When not `nil`, `resumeData` should be persisted for later use.
    func download(_ download: Download, didCancelWithResumeData resumeData: Data?)

    /// Asks the delegate for any persisted resume data for a particular download.
    func resumeDataForDownload(_ download: Download) -> Data?

    /// Tells the delegate that all background tasks have finished.
    /// This is where the system-provided completion handler should be called.
    func downloadManagerDidFinishBackgroundDownloads()
}
