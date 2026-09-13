//
//  DownloadBackend.swift
//  DownloadKit
//
//  Created by Lachlan Charlick on 13/9/2026.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A transfer engine. Queue policy and user intent remain in DownloadManager.
/// Implementations must fence callbacks by attempt, and retain completed files until
/// `completed` returns true. Requests are transient and must not be used as identities.
@MainActor public protocol DownloadBackend: AnyObject {
    var events: (any DownloadBackendEvents)? { get set }
    /// Native engines may already own a usable request after restoring an OS task.
    func requiresRequestRefresh(_ download: Download) -> Bool
    func prepare(_ download: Download) async throws
    func start(_ download: Download) async throws
    func pause(_ download: Download) async
    func remove(_ download: Download) async
    func restore(_ downloads: [Download]) async -> [Download]
}

@MainActor public protocol DownloadBackendEvents: AnyObject {
    /// Allows an Apple background callback delivered during launch to reconnect safely.
    func download(with id: UUID) -> Download?
    func recover(_ download: Download) async -> Bool
    func progress(id: UUID, attempt: UUID, received: Int64, expected: Int64) async
    func failed(id: UUID, attempt: UUID, error: DownloadError) async
    func completed(id: UUID, attempt: UUID, location: URL) async -> Bool
    func backgroundEventsFinished() async
}

public extension DownloadBackend {
    func requiresRequestRefresh(_ download: Download) -> Bool { true }
    func prepare(_ download: Download) async throws {}
    func restore(_ downloads: [Download]) async -> [Download] { [] }
}

/// A request cannot currently be resolved, but user intent must remain queued.
public enum DownloadPreparationError: Error {
    case temporarilyUnavailable
}
