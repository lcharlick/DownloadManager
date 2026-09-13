//
//  DownloadManagerDelegate.swift
//  DownloadManager
//
//  Created by Lachlan Charlick on 3/3/21.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol DownloadManagerDelegate: AnyObject {
    #if !os(Android) && !os(Linux)
    /// Tells the delegate when a download task has been created.
    @MainActor func download(_ download: Download, didCreateTask: URLSessionDownloadTask) async

    /// Tells the delegate when a background download task reconnects.
    @MainActor func download(_ download: Download, didReconnectTask: URLSessionDownloadTask) async

    #endif

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

    /// Tells the delegate when the download queue changes.
    @MainActor func downloadQueueDidChange(_ downloads: [Download]) async

    /// Tells the delegate when download throughput changes.
    @MainActor func downloadThroughputDidChange(_ bytesPerSecond: Int) async

    /// Tells the delegate when a download's progress is updated.
    @MainActor func downloadDidUpdateProgress(_ download: Download) async

    /// Tells the delegate when a download's status changes.
    @MainActor func downloadStatusDidChange(_ download: Download) async
    /// Re-resolve credentials immediately before an execution attempt.
    @MainActor func requestForDownload(_ download: Download) async throws -> URLRequest
    /// Completion is acknowledged only after durable storage succeeds.
    @MainActor func finalizeDownload(_ download: Download, location: URL) async throws
}

public extension DownloadManagerDelegate {
    @MainActor func requestForDownload(_ download: Download) async throws -> URLRequest { download.request }
    @MainActor func finalizeDownload(_ download: Download, location: URL) async throws {
        await self.download(download, didFinishDownloadingTo: location)
    }
}