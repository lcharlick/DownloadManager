//
//  ExampleApp.swift
//  Example
//
//  Created by Lachlan Charlick on 19/3/21.
//

import SwiftUI
import DownloadManager

private enum Constants {
    static let httpbin = URL(string: "http://httpbin.org")!
    static let downloadCount = 3
    /// Max httpbin file size (~100kb).
    static let maxFileSize = 102_400
}

@main
struct DownloadManagerUIApp: App {
    let viewModel = ViewModel()
    var body: some Scene {
        WindowGroup {
            DownloadManagerView(viewModel: viewModel)
                .onAppear {
                    viewModel.download((0..<Constants.downloadCount).map { index -> ViewModel.Item in
                        let size = Int.random(in: 1_000...Constants.maxFileSize)
                        return .init(
                            id: index,
                            url: Constants.httpbin.appendingPathComponent("/bytes/\(size)"),
                            estimatedSize: size
                        )
                    })
                }
        }
    }
}
