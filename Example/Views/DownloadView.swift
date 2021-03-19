//
//  DownloadView.swift
//  DownloadManagerUI
//
//  Created by Lachlan Charlick on 1/3/21.
//

import SwiftUI
import DownloadManager

struct DownloadView: View {
    @ObservedObject var download: Download
    let pauseHandler: () -> Void
    let resumeHandler: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(download.url.absoluteString)
                DownloadStateView(status: download.status, progress: download.progress)
            }
            DownloadActionButton(
                action: download.status.action,
                pauseHandler: pauseHandler,
                resumeHandler: resumeHandler
            )
        }
    }
}

struct DownloadItemView_Previews: PreviewProvider {
    static var previews: some View {
        DownloadView(
            download: Download(
                url: URL(string: "http://test")!,
                status: .downloading,
                progress: .init(expected: 1_000, received: 300)
            ),
            pauseHandler: {},
            resumeHandler: {}
        )
        .previewLayout(.sizeThatFits)
    }
}
