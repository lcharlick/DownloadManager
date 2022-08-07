//
//  DownloadActionButton.swift
//  DownloadManagerUI
//
//  Created by Lachlan Charlick on 1/3/21.
//

import DownloadManager
import SwiftUI

struct DownloadActionButton: View {
    let action: DownloadState.Status.Action
    let pauseHandler: () -> Void
    let resumeHandler: () -> Void

    var body: some View {
        Button(action: {
            switch action {
            case .pause:
                pauseHandler()
            case .resume:
                resumeHandler()
            case .none:
                break
            }
        }) {
            Image(
                systemName: action.imageName
            ).font(.system(size: 16, weight: .bold))
        }
    }
}

extension DownloadState.Status {
    var action: Action {
        switch self {
        case .downloading, .idle:
            return .pause
        case .finished:
            return .none
        default:
            return .resume
        }
    }

    enum Action {
        case pause
        case resume
        case none

        var imageName: String {
            switch self {
            case .pause:
                return "pause.circle.fill"
            case .resume:
                return "arrow.clockwise.circle.fill"
            case .none:
                return "checkmark.circle.fill"
            }
        }
    }
}

struct DownloadActionButton_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            DownloadActionButton(
                action: .pause,
                pauseHandler: {},
                resumeHandler: {}
            )
            DownloadActionButton(
                action: .resume,
                pauseHandler: {},
                resumeHandler: {}
            )
            DownloadActionButton(
                action: .none,
                pauseHandler: {},
                resumeHandler: {}
            )
        }
        .previewLayout(.sizeThatFits)
    }
}
