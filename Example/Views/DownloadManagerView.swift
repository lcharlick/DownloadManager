//
//  DownloadManagerView.swift
//  DownloadManagerUI
//
//  Created by Lachlan Charlick on 28/2/21.
//

import SwiftUI
import DownloadManager

struct DownloadManagerView<ViewModel: ViewModelType>: View {
    @ObservedObject var viewModel: ViewModel
    @State private var selection = Set<Download.ID>()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                VStack(alignment: .leading) {
                    ThroughputView(
                        throughput: viewModel.throughput,
                        estimatedTimeRemaining: viewModel.estimatedTimeRemaining
                    )
                    DownloadStateView(
                        status: viewModel.status,
                        progress: viewModel.progress
                    )
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                List(selection: $selection) {
                    ForEach(viewModel.queue) { download in
                        DownloadView(download: download, pauseHandler: {
                            viewModel.pause(download)
                        }, resumeHandler: {
                            viewModel.resume(download)
                        })
                        .padding([.top, .bottom])
                    }
                    .onDelete {
                        viewModel.cancel(at: $0)
                    }
                }
                .listStyle(PlainListStyle())
            }
            .navigationBarTitle("Downloads", displayMode: .inline)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    EditButton()
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Cancel (\(selection.count))") {
                        viewModel.cancel(selection)
                        selection = []
                    }
                }
            }
//            .navigationBarItems(trailing: EditButton())
        }
    }
}

struct DownloadManagerView_Previews: PreviewProvider {
    static let viewModel = PreviewViewModel(queue: [
        .init(
            url: URL(string: "http://test/1")!,
            status: .downloading,
            progress: .init(expected: 100_000, received: 50_000)
        ),
        .init(
            url: URL(string: "http://test/2")!,
            status: .idle,
            progress: .init(expected: 100_000, received: 30_000)
        ),
        .init(
            url: URL(string: "http://test/3")!,
            status: .failed(.serverError(statusCode: 500)),
            progress: .init(expected: 100_000, received: 80_000)
        )
    ])

    static var previews: some View {
        DownloadManagerView(viewModel: viewModel)
    }
}

class PreviewViewModel: ViewModelType {
    var throughput: Int = 1_000

    var estimatedTimeRemaining: TimeInterval? = 10

    var status = DownloadState.Status.downloading
    var progress = DownloadProgress(expected: 1_000, received: 500)

    let queue: [Download]

    init(queue: [Download]) {
        self.queue = queue
    }

    func pause(_ download: Download) {
    }

    func resume(_ download: Download) {
    }

    func cancel(_ downloads: Set<Download.ID>) {
    }

    func cancel(at offsets: IndexSet) {
    }
}

extension DownloadState.Error: CustomStringConvertible {
    public var description: String {
        switch self {
        case .serverError(statusCode: let code):
            return "Server error: \(code)"
        case .transportError(_, localizedDescription: let description):
            return description
        case .unknown(_, localizedDescription: let description):
            return description
        case .aggregate(errors: let errors):
            return "\(errors.count) errors occurred."
        }
    }
}
