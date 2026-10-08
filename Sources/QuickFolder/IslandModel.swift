import AppKit
import Observation
import SwiftUI

enum IslandState: Equatable {
    case collapsed
    /// The notch grows small wings to show downloads and installs in progress.
    case activity
    case peek
    case expanded
}

/// Something in progress, shown in the notch's wings and as a tile.
struct Activity: Identifiable, Equatable {
    enum Kind { case download, extract, install }

    let id: String
    var name: String
    /// nil while the total isn't known yet.
    var fraction: Double?
    var kind: Kind
    var folderPath: String
}

/// Old installers that are safe to clear out of a folder.
struct Cleanup: Equatable {
    var files: [URL]
    var bytes: Int64
}

/// A short message that replaces the header title for a few seconds.
struct Toast: Equatable {
    var symbol: String
    var text: String
    /// Clicking the toast opens this.
    var url: URL?
    /// Orange instead of green, for things that need the user's attention.
    var isWarning = false
}

enum PeekContent: Equatable {
    /// A file that just landed in one of the folders. `label` reads
    /// "Downloaded" for Downloads and "Added to Desktop" elsewhere.
    case download(DownloadItem, pageID: String, label: String)
    case message(title: String, subtitle: String, symbol: String)
    /// A call about to start, clickable to join.
    case meeting(Meeting)

    /// Downloads and meetings are things to click or drag, so pointing at
    /// them holds them up instead of opening the island.
    var isInteractive: Bool {
        if case .message = self { return false }
        return true
    }
}

enum HoverTarget: Hashable {
    case tile(String)
    case tileAction(String)
    case deckKey(UUID)
    case addDeckKey
    case cleanup
    case toast
    case pageRail
    case arrangeRow(String)
    case arrangeDone
    case peek
    case openFolder
    case settings
    case accessButton
    case meeting(String)
    case calendarAccess
}

protocol IslandActions: AnyObject {
    func open(_ item: DownloadItem)
    func showMenu(for item: DownloadItem)
    func openFolder()
    func showSettingsMenu()
    func openPrivacySettings()
    func selectPage(_ index: Int)
    func perform(_ action: SmartAction, on item: DownloadItem)
    func cleanUp()
    func openToast()
    func run(_ key: DeckKey)
    func editKey(_ key: DeckKey?)
    func showMenu(for key: DeckKey)
    func setArranging(_ arranging: Bool)
    func dragRow(_ id: String, phase: PanPhase, translation: CGFloat)
    func join(_ meeting: Meeting, as account: String?)
    func showMenu(for meeting: Meeting)
    func requestCalendarAccess()
    func openCalendar()
}

/// One page of the island: a folder, the Shortcuts deck, or upcoming
/// meetings. The island pages through these vertically.
struct FolderPage: Identifiable, Equatable {
    enum Kind { case folder, shortcuts, meetings }

    let id: String
    let url: URL
    var kind: Kind = .folder
    var name: String
    var items: [DownloadItem] = []
    var access: FolderAccess = .ok
    var cleanup: Cleanup?

    init(url: URL, name: String) {
        id = url.path
        self.url = url
        self.name = name
    }

    private init(shortcuts: Void) {
        id = "shortcuts"
        url = URL(fileURLWithPath: NSHomeDirectory())
        kind = .shortcuts
        name = "Shortcuts"
    }

    static let shortcuts = FolderPage(shortcuts: ())

    private init(meetings: Void) {
        id = "meetings"
        url = URL(fileURLWithPath: NSHomeDirectory())
        kind = .meetings
        name = "Meetings"
    }

    static let meetings = FolderPage(meetings: ())

    var isDownloads: Bool {
        kind == .folder && url.standardizedFileURL == Preferences.downloadsFolder.standardizedFileURL
    }
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
    static let visibleTiles: CGFloat = 7
    /// Width of each wing beside the notch while something is in progress.
    static let activityWing: CGFloat = 50
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

    static let arrangeRowSpacing: CGFloat = 4

    /// Row height in Arrange mode, so every row fits below the header.
    func arrangeRowHeight(count: Int) -> CGFloat {
        let available = expandedBody.height - notchHeight - 14
        let rows = CGFloat(max(count, 1))
        return min(28, (available - Self.arrangeRowSpacing * (rows - 1)) / rows)
    }

    var activityBody: CGSize {
        CGSize(width: notchRect.width + Self.activityWing * 2, height: notchHeight)
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
        case .activity:
            return IslandShape(bodySize: activityBody, earRadius: 6, bottomRadius: 12)
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

    /// The display picked in Options › Show On, else the one with a notch,
    /// else the main display. Screens without a notch get a drawn one.
    static func preferredScreen() -> NSScreen? {
        if let id = Preferences.displayID, let chosen = NSScreen.screens.first(where: { $0.displayUUID == id }) {
            return chosen
        }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
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

        var hasHardwareNotch = screen.safeAreaInsets.top > 0
        #if DEBUG
        // QF_DEBUG_FAKE_NOTCH draws the island as on a display without a notch.
        if ProcessInfo.processInfo.environment["QF_DEBUG_FAKE_NOTCH"] != nil { hasHardwareNotch = false }
        #endif

        if hasHardwareNotch,
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

    var activities: [Activity] = []
    var toast: Toast?
    /// The cleanup pill asks "Trash 12 old installers?" before doing it.
    var isConfirmingCleanup = false

    /// Arrange mode: the rows become a list you drag to reorder.
    var isArranging = false
    /// The row being dragged and how far it has moved. The list itself only
    /// changes on drop; until then the other rows just slide aside.
    var draggingPageID: String?
    var dragOffset: CGFloat = 0
    /// Where the dragged row would land if dropped now.
    var dragTargetIndex = 0

    var deckKeys: [DeckKey] = []
    /// Briefly true or false after a key runs, for the checkmark or cross.
    var deckResults: [UUID: Bool] = [:]

    var meetings: [Meeting] = []
    var calendarAccess: CalendarAccess = .notDetermined

    let thumbnails = ThumbnailStore()
    @ObservationIgnored weak var actions: IslandActions?

    init(metrics: IslandMetrics) {
        self.metrics = metrics
    }

    var currentPage: FolderPage? { pages.indices.contains(pageIndex) ? pages[pageIndex] : nil }
    var items: [DownloadItem] { currentPage?.items ?? [] }
    var access: FolderAccess { currentPage?.access ?? .ok }
    var folderName: String { currentPage?.name ?? "" }

    /// How far a row in Arrange mode is drawn from its slot while another row
    /// is dragged past it.
    func arrangeOffset(for id: String) -> CGFloat {
        guard let dragged = draggingPageID,
              let from = pages.firstIndex(where: { $0.id == dragged }),
              let index = pages.firstIndex(where: { $0.id == id }) else { return 0 }
        if id == dragged { return dragOffset }
        let step = metrics.arrangeRowHeight(count: pages.count) + IslandMetrics.arrangeRowSpacing
        let to = dragTargetIndex
        if from < to, index > from, index <= to { return -step }
        if from > to, index >= to, index < from { return step }
        return 0
    }

    /// Downloads in progress that belong on the current page.
    var pageDownloads: [Activity] {
        guard let page = currentPage, page.kind == .folder else { return [] }
        return activities.filter { $0.kind == .download && $0.folderPath == page.url.path }
    }

    /// How many tiles the current page's row holds.
    var tileCount: Int {
        switch currentPage?.kind {
        case .shortcuts: deckKeys.count + 1
        case .meetings: calendarAccess == .granted ? meetings.count : 0
        default: pageDownloads.count + items.count
        }
    }

    var maxScrollOffset: CGFloat {
        let count = CGFloat(tileCount)
        let content = count * IslandMetrics.tileWidth + max(0, count - 1) * IslandMetrics.tileSpacing
        return max(0, content - metrics.rowWidth)
    }
}

extension NSScreen {
    /// Stays the same across restarts and reconnects, unlike the display number.
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
