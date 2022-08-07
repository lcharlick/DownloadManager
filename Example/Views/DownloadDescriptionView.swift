//
//  DownloadDescriptionView.swift
//  DownloadManagerUI
//
//  Created by Lachlan Charlick on 1/3/21.
//

import DownloadManager
import SwiftUI

struct DownloadDescriptionView: View {
    let status: DownloadState.Status

    let totalUnitCount: Int
    let completedUnitCount: Int

    private let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.zeroPadsFractionDigits = true
        return formatter
    }()

    private var totalUnitDescription: String {
        formatter.string(fromByteCount: Int64(totalUnitCount))
    }

    private var completedUnitDescription: String {
        formatter.string(fromByteCount: Int64(completedUnitCount))
    }

    var body: some View {
        Group {
            switch status {
            case let .failed(error):
                Text("\(error.description)")
                    .foregroundColor(.red)
            default:
                HStack {
                    Text(completedUnitDescription)
                    Spacer()
                    if totalUnitCount == 0 {
                        Text("Unknown Size")
                            .font(Font.system(.subheadline).italic())
                    } else {
                        Text(totalUnitDescription)
                            .font(Font.system(.subheadline).monospacedDigit())
                    }
                }
                .foregroundColor(Color(UIColor.secondaryLabel))
            }
        }
        .font(.subheadline)
    }
}

struct DownloadDescriptionView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            DownloadDescriptionView(
                status: .downloading,
                totalUnitCount: 100_000,
                completedUnitCount: 50000
            )
            DownloadDescriptionView(
                status: .paused,
                totalUnitCount: 1_500_000,
                completedUnitCount: 350_000
            )
            DownloadDescriptionView(
                status: .idle,
                totalUnitCount: 100_000,
                completedUnitCount: 0
            )
            DownloadDescriptionView(
                status: .idle,
                totalUnitCount: 0,
                completedUnitCount: 0
            )
            DownloadDescriptionView(
                status: .finished,
                totalUnitCount: 135_000_000,
                completedUnitCount: 135_000_000
            )
            DownloadDescriptionView(
                status: .failed(.serverError(statusCode: 500)),
                totalUnitCount: 900_000,
                completedUnitCount: 870_000
            )
        }
        .previewLayout(.sizeThatFits)
    }
}
