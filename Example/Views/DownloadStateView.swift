//
//  DownloadStateView.swift
//  DownloadManagerUI
//
//  Created by Lachlan Charlick on 1/3/21.
//

import DownloadManager
import SwiftUI

struct DownloadStateView: View {
    let status: DownloadStatus
    @ObservedObject private var progress: ObservableProgress

    init(
        status: DownloadStatus,
        progress: DownloadProgress
    ) {
        self.status = status
        self.progress = ObservableProgress(progress: progress)
    }

    var body: some View {
        VStack(alignment: .leading) {
            ProgressView(value: progress.fractionCompleted)
                .progressViewStyle(LinearProgressViewStyle())
            DownloadDescriptionView(
                status: status,
                totalUnitCount: progress.totalUnitCount,
                completedUnitCount: progress.completedUnitCount
            )
        }
    }
}

struct DownloadStateView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            DownloadStateView(
                status: .downloading,
                progress: .init(expected: 1000, received: 100)
            )
            DownloadStateView(
                status: .paused,
                progress: .init(expected: 1000, received: 300)
            )
            DownloadStateView(
                status: .idle,
                progress: .init(expected: 0, received: 0)
            )
            DownloadStateView(
                status: .finished,
                progress: .init(expected: 1000, received: 1000)
            )
            DownloadStateView(
                status: .failed(.serverError(statusCode: 500)),
                progress: .init(expected: 1000, received: 800)
            )
        }
        .previewLayout(.sizeThatFits)
    }
}
