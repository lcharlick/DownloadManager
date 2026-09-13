//
//  DownloadQueueFile.swift
//  DownloadKit
//
//  Created by Lachlan Charlick on 13/9/2026.
//

import Foundation

/// Device-local queue persistence. Intentionally contains no requests, URLs or credentials.
public struct DownloadQueueFile: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public struct Entry: Codable, Sendable {
        public let id: UUID
        public let attempt: UUID
        public let context: [String: String]
        public let state: State
        public let expected: Int64
        public let received: Int64
        public let completionPath: String?
        public enum State: String, Codable, Sendable { case queued, paused, failed, finished }
    }

    private struct Document: Codable {
        let version: Int
        let entries: [Entry]
    }
    public enum Failure: Error { case unsupportedVersion, duplicateIdentity }

    public func load() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.version == 1 else { throw Failure.unsupportedVersion }
        guard Set(document.entries.map(\.id)).count == document.entries.count else { throw Failure.duplicateIdentity }
        return document.entries
    }

    @MainActor public func save(_ downloads: [Download]) throws {
        let entries = downloads.map { download in
            let state: Entry.State
            switch download.status {
            case .idle, .downloading: state = .queued
            case .paused: state = .paused
            case .failed: state = .failed
            case .finished: state = .finished
            }
            return Entry(id: download.id, attempt: download.attempt, context: download.context,
                state: state, expected: download.expected, received: download.received,
                completionPath: download.completionLocation?.path)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Document(version: 1, entries: entries)).write(to: url, options: .atomic)
    }
}
