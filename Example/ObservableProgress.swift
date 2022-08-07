//
//  ObservableProgress.swift
//  DownloadManagerUI
//
//  Created by Lachlan Charlick on 3/3/21.
//

import Combine
import DownloadManager
import Foundation

class ObservableProgress: ObservableObject {
    private let _progress: Progress = .download(fraction: 0)
    private let progress: DownloadProgress

    @Published var fractionCompleted: Double = 0

    var totalUnitCount: Int {
        progress.expected
    }

    var completedUnitCount: Int {
        progress.received
    }

    var localizedAdditionalDescription: String {
        _progress.localizedAdditionalDescription
    }

    init(progress: DownloadProgress) {
        self.progress = progress
        progress.$fractionCompleted
            .receive(on: DispatchQueue.main)
            .assign(to: &$fractionCompleted)
    }
}
