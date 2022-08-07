//
//  DownloadQueue.swift
//  DownloadManager
//
//  Created by Lachlan Charlick on 26/2/21.
//

import Foundation

protocol DownloadQueueDelegate: Actor {
    var maxConcurrentDownloads: Int { get }
    func queueDidChange() async
    func downloadShouldBeginDownloading(_ download: Download) async
}

actor DownloadQueue {
    var cache = [Download.ID: Download]()

    private(set) var downloads = [Download]()

    private weak var delegate: DownloadQueueDelegate?

    init(delegate: DownloadQueueDelegate) {
        self.delegate = delegate
    }

    func update() async {
        let downloadsByStatus = Dictionary(grouping: downloads) { $0.status }
        let numberDownloading = downloadsByStatus[.downloading]?.count ?? 0
        let maxConcurrentDownloads = await delegate?.maxConcurrentDownloads ?? 1

        let slotsAvailable = maxConcurrentDownloads - numberDownloading

        guard numberDownloading <= maxConcurrentDownloads else {
            return
        }

        for download in downloadsByStatus[.idle]?.prefix(slotsAvailable) ?? [] {
            await delegate?.downloadShouldBeginDownloading(download)
        }
    }

    func download(with id: Download.ID) -> Download? {
        cache[id]
    }

    private func add(_ download: Download) {
        downloads.append(download)
        cache[download.id] = download
    }

    func append(_ download: Download) async {
        add(download)
        await update()
        await delegate?.queueDidChange()
    }

    func append(_ downloads: [Download]) async {
        for download in downloads {
            add(download)
        }
        await update()
        await delegate?.queueDidChange()
    }

    func remove(_ download: Download) async {
        cache[download.id] = nil
        if let index = downloads.firstIndex(where: { $0.id == download.id }) {
            downloads.remove(at: index)
            await delegate?.queueDidChange()
        }
        await update()
    }

    func remove(_ downloadsToRemove: Set<Download>) async {
        for download in downloadsToRemove {
            cache[download.id] = nil
        }

        downloads = downloads.filter { !downloadsToRemove.contains($0) }

        await delegate?.queueDidChange()
        await update()
    }
}
