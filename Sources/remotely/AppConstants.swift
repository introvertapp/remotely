import AppKit
import SwiftUI

enum AppConstants {
    static let panelWidth: CGFloat = 360
    static let panelHeight: CGFloat = 720
    static let remoteWithoutNowPlayingHeight: CGFloat = 510
    static let keyboardExtraHeight: CGFloat = 50
    static let keyboardPanelHeight: CGFloat = 770
    static let remoteWithoutNowPlayingKeyboardHeight: CGFloat = remoteWithoutNowPlayingHeight + keyboardExtraHeight
    static let miniRemoteWidth: CGFloat = 360
    static let panelContentWidth: CGFloat = panelWidth - 24
    static let windowDragHandleHeight: CGFloat = 12
    static let navigationBarHeight: CGFloat = 50
    static let miniRemoteHeight: CGFloat = 190
    static let panelGap: CGFloat = 1
    static let cornerRadius: CGFloat = 34
    static let miniRemoteCornerRadius: CGFloat = 24
    static let longPressSeconds: Double = 0.65
    static let fetchAppArtworkDefaultsKey = "fetchAppArtworkFromAppStore"

    static let remoteBackground = Color(white: 0.018)
    static let controlBackground = Color(white: 0.095)
    static let controlHighlight = Color(white: 0.19)
    static let controlBorder = Color(white: 0.30).opacity(0.42)

    static func remotePanelHeight(showNowPlaying: Bool, keyboardVisible: Bool) -> CGFloat {
        let base = showNowPlaying ? panelHeight : remoteWithoutNowPlayingHeight
        return base + (keyboardVisible ? keyboardExtraHeight : 0)
    }
}
