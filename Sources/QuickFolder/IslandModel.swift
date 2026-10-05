import AppKit
import Observation
import SwiftUI

enum IslandState: Equatable {
    case collapsed
    case peek
    case expanded
}

enum PeekContent: Equatable {
    /// A file that just landed in one of the folders. `label` reads
    /// "Downloaded" for Downloads and "Added to Desktop" elsewhere.
    case download(DownloadItem, pageID: String, label: String)
    case message(title: String, subtitle: String, symbol: String)
}

enum HoverTarget: Hashable {
    case tile(String)
    case tileAction(String)
    case peek
    case openFolder
    case settings
    case accessButton
}

protocol IslandActions: AnyObject {
    func open(_ item: DownloadItem)
    func showMenu(for item: DownloadItem)
    func openFolder()
    func showSettingsMenu()
    func openPrivacySettings()
    func selectPage(_ index: Int)
    func extract(_ item: DownloadItem)
}

/// One folder the island can show. The island pages through these vertically.
struct FolderPage: Identifiable, Equatable {
    let url: URL
    var name: String
    var items: [DownloadItem] = []
    var access: FolderAccess = .ok

    var id: String { url.path }
    var isDownloads: Bool { url.standardizedFileURL == Preferences.downloadsFolder.standardizedFileURL }
}

/// The size of the black shape for one state. `bodySize` excludes the
/// concave "ears" that blend the top corners into the screen edge.
struct IslandShape: Equatable {
    var bodySize: CGSize
    var earRadius: CGFloat
    var bottomRadius: CGFloat

    var size: CGSize { CGSize(width: bodySize.width + earRadius * 2, height: bodySize.height) }
}

/// All geometry, derived from the screen that holds the island.
struct IslandMetrics: Equatable {
    var screenFrame: CGRect
    /// The hardware notch, or a fake one on screens without it. Screen coordinates.
    var notchRect: CGRect
    var hasNotch: Bool

    static let tileWidth: CGFloat = 84
    static let tileHeight: CGFloat = 116
    static let tileSpacing: CGFloat = 4
    static let visibleTiles: CGFloat = 6
    static let rowInset: CGFloat = 14
    static let shadowPadding: CGFloat = 80

    var notchHeight: CGFloat { notchRect.height }

    var rowWidth: CGFloat {
        Self.visibleTiles * Self.tileWidth + (Self.visibleTiles - 1) * Self.tileSpacing
    }

    var expandedBody: CGSize {
        CGSize(
            width: max(rowWidth + Self.rowInset * 2, notchRect.width + 340),
            height: notchHeight + Self.tileHeight + 12
        )
    }

    var peekBody: CGSize {
        CGSize(width: max(notchRect.width + 170, 360), height: notchHeight + 54)
    }

    func shape(for state: IslandState) -> IslandShape {
        switch state {
        case .collapsed:
            // Sits just inside the hardware notch so it is never visible on its own.
            let size = hasNotch
                ? CGSize(width: notchRect.width - 4, height: notchRect.height - 1)
                : notchRect.size
            return IslandShape(bodySize: size, earRadius: hasNotch ? 0 : 5, bottomRadius: hasNotch ? 8 : 9)
        case .peek:
            return IslandShape(bodySize: peekBody, earRadius: 10, bottomRadius: 22)
        case .expanded:
            return IslandShape(bodySize: expandedBody, earRadius: 14, bottomRadius: 28)
        }
    }

    var windowFrame: CGRect {
        let largest = shape(for: .expanded).size
        let width = largest.width + Self.shadowPadding * 2
        let height = largest.height + Self.shadowPadding
        return CGRect(x: notchRect.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
    }

    /// Where the shape for `state` is on screen.
    func screenRect(for state: IslandState) -> CGRect {
        let size = shape(for: state).size
        return CGRect(x: notchRect.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height + 1)
    }

    /// Hovering here opens the island.
    var hotZone: CGRect {
        CGRect(x: notchRect.minX - 8, y: notchRect.minY, width: notchRect.width + 16, height: notchRect.height + 1)
    }

    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    /// Used only if no screen is attached at launch; replaced on the next screen change.
    static let fallback = IslandMetrics(
        screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        notchRect: CGRect(x: 630, y: 876, width: 180, height: 24),
        hasNotch: false
    )

    init(screenFrame: CGRect, notchRect: CGRect, hasNotch: Bool) {
        self.screenFrame = screenFrame
        self.notchRect = notchRect
        self.hasNotch = hasNotch
    }

    init?(screen: NSScreen?) {
        guard let screen else { return nil }
        let frame = screen.frame
        screenFrame = frame

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let height = screen.safeAreaInsets.top
            let width = frame.width - left.width - right.width
            notchRect = CGRect(x: frame.minX + left.width, y: frame.maxY - height, width: width, height: height)
            hasNotch = true
        } else {
            let menuBar = frame.maxY - screen.visibleFrame.maxY
            let height = menuBar > 0 ? menuBar : 24
            let width: CGFloat = 180
            notchRect = CGRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height)
            hasNotch = false
        }
    }
}

@Observable
final class IslandModel {
    var state: IslandState = .collapsed
    var metrics: IslandMetrics
    var pages: [FolderPage] = []
    var pageIndex = 0
    /// Which way the next page slides in.
    var pageEdge: Edge = .bottom
    /// How far the shelf has been pulled up (positive) or down during a
    /// vertical swipe, after resistance.
    var pagePull: CGFloat = 0
    var peek: PeekContent?
    var hovered: HoverTarget?
    var pressed: HoverTarget?
    var scrollOffset: CGFloat = 0
    var isDraggingFile = false

    /// Files with a smart action running on them.
    var busyItems: Set<String> = []
    /// The tile whose action button is under the pointer.
    var hoveredAction: String?
    /// A file that just appeared because of something QuickFolder did; it glows briefly.
    var highlightedID: String?
    /// Short messages shown in place of a tile's date, like "Couldn't extract".
    var tileNotes: [String: String] = [:]

    let thumbnails = ThumbnailStore()
    @ObservationIgnored weak var actions: IslandActions?

    init(metrics: IslandMetrics) {
        self.metrics = metrics
    }

    var currentPage: FolderPage? { pages.indices.contains(pageIndex) ? pages[pageIndex] : nil }
    var items: [DownloadItem] { currentPage?.items ?? [] }
    var access: FolderAccess { currentPage?.access ?? .ok }
    var folderName: String { currentPage?.name ?? "" }

    var maxScrollOffset: CGFloat {
        let count = CGFloat(items.count)
        let content = count * IslandMetrics.tileWidth + max(0, count - 1) * IslandMetrics.tileSpacing
        return max(0, content - metrics.rowWidth)
    }
}
