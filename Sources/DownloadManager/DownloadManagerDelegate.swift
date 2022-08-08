//
//  DownloadManagerDelegate.swift
//  DownloadManager
//
//  Created by Lachlan Charlick on 3/3/21.
//

import Foundation

public protocol DownloadManagerDelegate: AnyObject {
    /// Tells the delegate when the download queue has changed.
    @MainActor func downloadQueueDidChange(_ downloads: [Download]) async

    /// Periodically informs the delegate about the download manager’s throughput.
    @MainActor func downloadThroughputDidChange(_ throughput: Int) async

    /// Periodically informs the delegate about the download’s progress.
    @MainActor func downloadDidUpdateProgress(_ download: Download) async

    /// Tells the delegate when a download item’s status has changed.
    @MainActor func downloadStatusDidChange(_ download: Download) async

    /// Tells the delegate when a download task has been created.
    @MainActor func download(_ download: Download, didCreateTask: URLSessionDownloadTask) async

    /// Tells the delegate when a background download task reconnects.
    @MainActor func download(_ download: Download, didReconnectTask: URLSessionDownloadTask) async

    /// Tells the delegate that a download task has finished downloading.
    /// The file at `location` must be opened or moved before this method returns.
    @MainActor func download(_ download: Download, didFinishDownloadingTo location: URL) async

    /// Tells the delegate when a download task has been cancelled.
    /// When not `nil`, `resumeData` should be persisted for later use.
    @MainActor func download(_ download: Download, didCancelWithResumeData resumeData: Data?) async

    /// Asks the delegate for any persisted resume data for a particular download.
    @MainActor func resumeDataForDownload(_ download: Download) async -> Data?

    /// Tells the delegate that all background tasks have finished.
    /// This is where the system-provided completion handler should be called.
    @MainActor func downloadManagerDidFinishBackgroundDownloads() async
}
