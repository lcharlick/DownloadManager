//
//  DownloadQueue.swift
//  DownloadManager
//
//  Created by Lachlan Charlick on 26/2/21.
//

import Foundation

protocol DownloadQueueDelegate: AnyObject {
    func queueDidChange()
    func downloadShouldBeginDownloading(_ download: Download)
}

class DownloadQueue {
    @Atomic
    var cache = [Download.ID: Download]()

    private(set) var downloads = [Download]()

    private weak var delegate: DownloadQueueDelegate?

    var maxConcurrentDownloads: Int = 1 {
        didSet {
            update()
        }
    }

    init(delegate: DownloadQueueDelegate) {
        self.delegate = delegate
    }

    func update() {
        let downloadsByStatus = Dictionary(grouping: downloads) { $0.status }
        let numberDownloading = downloadsByStatus[.downloading]?.count ?? 0
        let slotsAvailable = maxConcurrentDownloads - numberDownloading

        guard numberDownloading <= maxConcurrentDownloads else {
            return
        }

        for download in downloadsByStatus[.idle]?.prefix(slotsAvailable) ?? [] {
            delegate?.downloadShouldBeginDownloading(download)
        }
    }

    func download(with id: Download.ID) -> Download? {
        cache[id]
    }

    private func add(_ download: Download) {
        downloads.append(download)
        cache[download.id] = download
    }

    func append(_ download: Download) {
        add(download)
        update()
        delegate?.queueDidChange()
    }

    func append(_ downloads: [Download]) {
        for download in downloads {
            add(download)
        }
        update()
        delegate?.queueDidChange()
    }

    func remove(_ download: Download) {
        cache[download.id] = nil
        if let index = downloads.firstIndex(where: { $0.id == download.id }) {
            downloads.remove(at: index)
            delegate?.queueDidChange()
        }
        update()
    }

    func remove(_ downloadsToRemove: Set<Download>) {
        for download in downloadsToRemove {
            cache[download.id] = nil
        }

        self.downloads = downloads.filter { !downloadsToRemove.contains($0) }

        delegate?.queueDidChange()
        update()
    }
}
