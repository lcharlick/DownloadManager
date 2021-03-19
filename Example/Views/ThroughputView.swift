//
//  ThroughputView.swift
//  DownloadManagerUI
//
//  Created by Lachlan Charlick on 3/3/21.
//

import SwiftUI

struct ThroughputView: View {
    private let throughputProgress = Progress.download(fraction: 0)
    private let timeRemainingProgress = Progress.download(fraction: 0)

    init(throughput: Int, estimatedTimeRemaining: TimeInterval?) {
        throughputProgress.throughput = throughput
        timeRemainingProgress.estimatedTimeRemaining = estimatedTimeRemaining
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text(throughputProgress.localizedAdditionalDescription)
            Text(timeRemainingProgress.localizedAdditionalDescription)
        }
    }
}
