//
//  ObservableProgress.swift
//  DownloadManagerUI
//
//  Created by Lachlan Charlick on 3/3/21.
//

import DownloadManager
import Foundation

@Observable
class ObservableProgress {
    private let _progress: Progress = .download(fraction: 0)
    private let manager: DownloadManager

    var fractionCompleted: Double {
        manager.fractionCompleted
    }

    var totalUnitCount: Int64 {
        manager.totalExpected
    }

    var completedUnitCount: Int64 {
        manager.totalReceived
    }

    var localizedAdditionalDescription: String {
        _progress.localizedAdditionalDescription
    }

    init(manager: DownloadManager) {
        self.manager = manager
    }
}
