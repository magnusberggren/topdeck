import AppKit
import SwiftUI

/// Owns the island window and decides when it opens, peeks and closes.
final class IslandController: NSObject, IslandActions {
    let model: IslandModel

    private let panel = IslandPanel()
    /// One watcher per folder, keyed by path, so every page stays live.
    private var monitors: [String: DownloadsMonitor] = [:]
    private var eventMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    private var expandTimer: Timer?
    private var collapseTimer: Timer?
    private var peekTimer: Timer?

    private var isMenuOpen = false
    /// After the island closes because of a click, the pointer must leave the
    /// notch before hovering opens it again.
    private var waitsForPointerToLeave = false

    private var rawScrollOffset: CGFloat = 0
    private var ignoresMomentum = false

    // One trackpad gesture moves either the shelf or the page, never both.
    private enum ScrollAxis { case horizontal, vertical }
    private var scrollAxis: ScrollAxis?
    private var axisProbe = CGSize.zero
    private var rawPagePull: CGFloat = 0
    private var gestureSwitchedPage = false
    private var gestureHitEdge = false

    private var wheelPull: CGFloat = 0
    private var lastWheelTime: TimeInterval = 0
    private var wheelLockedUntil: TimeInterval = 0
    private var wheelRelease: DispatchWorkItem?

    private var collapsedAt = Date.distantPast
    private var openWithMenu: OpenWithMenu?

    /// While QuickFolder itself is adding files (extracting), they shouldn't
    /// pop up as new downloads.
    private var runningExtractions = 0
    private var quietUntil = Date.distantPast

    #if DEBUG
    private var pinnedState: IslandState?
    #endif

    private enum Timing {
        static let hoverDelay: TimeInterval = 0.09
        static let peekHoverDelay: TimeInterval = 0.03
        static let leaveDelay: TimeInterval = 0.12
        static let peekDuration: TimeInterval = 4.2
        /// Reopening after this long starts back on the first folder.
        static let pageMemory: TimeInterval = 30
    }

    private enum Paging {
        /// Finger travel needed to switch folders. Until then the shelf
        /// resists and springs back, so a sloppy swipe doesn't switch.
        static let threshold: CGFloat = 64
        /// Mouse wheel lines needed to switch folders.
        static let wheelThreshold: CGFloat = 3
    }

    override init() {
        model = IslandModel(metrics: IslandMetrics(screen: IslandMetrics.preferredScreen()) ?? .fallback)
        super.init()
        model.actions = self
    }

    func start() {
        let hosting = IslandHostingView(rootView: IslandView(model: model))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        updateScreen()
        panel.orderFrontRegardless()

        reloadFolders()

        installEventMonitors()
        installObservers()
        installDragHandlers()

        #if DEBUG
        applyDebugState()
        #endif
    }

    func showWelcomeHint() {
        let place = model.metrics.hasNotch ? "the notch" : "the top of the screen"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.showPeek(.message(
                title: "QuickFolder is ready",
                subtitle: "Point at \(place) to see your downloads",
                symbol: "tray.and.arrow.down.fill"
            ), duration: 5)
        }
    }

    // MARK: - Folders

    /// Syncs pages and watchers with `Preferences.folders`.
    private func reloadFolders() {
        let urls = Preferences.folders
        let paths = Set(urls.map(\.path))
        let currentID = model.currentPage?.id

        for (path, monitor) in monitors where !paths.contains(path) {
            monitor.stop()
            monitors[path] = nil
        }

        model.pages = urls.map { url in
            model.pages.first { $0.id == url.path }
                ?? FolderPage(url: url, name: FileManager.default.displayName(atPath: url.path))
        }
        model.pageIndex = model.pages.firstIndex { $0.id == currentID } ?? min(model.pageIndex, max(0, model.pages.count - 1))

        for url in urls where monitors[url.path] == nil {
            let id = url.path
            let monitor = DownloadsMonitor(folder: url)
            monitor.onChange = { [weak self] items, access in self?.apply(items: items, access: access, to: id) }
            monitor.onNewDownload = { [weak self] item in self?.announce(item, in: id) }
            monitors[id] = monitor
            monitor.start()
        }
    }

    private func apply(items: [DownloadItem], access: FolderAccess, to pageID: String) {
        guard let index = model.pages.firstIndex(where: { $0.id == pageID }) else { return }
        let isVisible = model.state == .expanded && index == model.pageIndex
        withAnimation(isVisible ? .spring(response: 0.42, dampingFraction: 0.84) : nil) {
            model.pages[index].items = items
            model.pages[index].access = access
            if isVisible && model.scrollOffset > model.maxScrollOffset {
                model.scrollOffset = model.maxScrollOffset
                rawScrollOffset = model.scrollOffset
            }
        }
        model.thumbnails.sync(with: model.pages.flatMap(\.items))
    }

    private func announce(_ item: DownloadItem, in pageID: String) {
        guard Preferences.showsNewDownloadPreview, model.state != .expanded, !model.isDraggingFile,
              runningExtractions == 0, Date() > quietUntil,
              let page = model.pages.first(where: { $0.id == pageID }) else { return }
        let label = page.isDownloads ? "Downloaded" : "Added to \(page.name)"
        showPeek(.download(item, pageID: pageID, label: label), duration: Timing.peekDuration)
    }

    func extract(_ item: DownloadItem) {
        guard !model.busyItems.contains(item.id) else { return }
        model.busyItems.insert(item.id)
        runningExtractions += 1

        Archive.extractAndTrash(item.url) { [weak self] result in
            guard let self else { return }
            self.runningExtractions -= 1
            self.quietUntil = Date().addingTimeInterval(2)
            self.model.busyItems.remove(item.id)

            switch result {
            case .success(let url):
                FileActions.playTrashSound()
                Haptics.perform(.levelChange)
                withAnimation(.smooth(duration: 0.3)) { self.model.highlightedID = url.path }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    guard self.model.highlightedID == url.path else { return }
                    withAnimation(.smooth(duration: 0.6)) { self.model.highlightedID = nil }
                }
                // Finished after the island closed: say so from the notch.
                if self.model.state != .expanded {
                    let folder = url.deletingLastPathComponent().path
                    let pageID = self.model.pages.first { $0.url.path == folder }?.id ?? folder
                    self.showPeek(.download(DownloadItem(url: url), pageID: pageID, label: "Extracted"), duration: Timing.peekDuration)
                }
            case .failure:
                NSSound.beep()
                self.model.tileNotes[item.id] = "Couldn’t extract"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.model.tileNotes[item.id] = nil
                }
            }
        }
    }

    func selectPage(_ index: Int) {
        guard model.pages.indices.contains(index), index != model.pageIndex else { return }
        // Set the direction first so the outgoing page picks it up before it leaves.
        model.pageEdge = index > model.pageIndex ? .bottom : .top
        DispatchQueue.main.async { [self] in
            rawScrollOffset = 0
            withAnimation(.spring(response: 0.44, dampingFraction: 0.82)) {
                model.pageIndex = index
                model.pagePull = 0
                model.scrollOffset = 0
                model.hovered = nil
                model.hoveredAction = nil
            }
            if let page = model.currentPage, page.access != .ok { monitors[page.id]?.refresh() }
        }
    }

    // MARK: - State

    private func setState(_ state: IslandState) {
        guard model.state != state else { return }
        cancelTimers()

        let animation: Animation
        switch state {
        case .expanded:
            animation = .spring(response: 0.44, dampingFraction: 0.74)
            model.scrollOffset = 0
            rawScrollOffset = 0
            model.pagePull = 0
            if model.state == .peek, case .download(_, let pageID, _) = model.peek,
               let index = model.pages.firstIndex(where: { $0.id == pageID }) {
                // Open on the folder the preview was about.
                model.pageIndex = index
            } else if Date().timeIntervalSince(collapsedAt) > Timing.pageMemory {
                model.pageIndex = 0
            }
            if let page = model.currentPage, page.access != .ok { monitors[page.id]?.refresh() }
            Haptics.perform(.levelChange)
        case .peek:
            animation = .spring(response: 0.46, dampingFraction: 0.7)
        case .collapsed:
            animation = .spring(response: 0.36, dampingFraction: 0.9)
            collapsedAt = Date()
            model.hovered = nil
            model.hoveredAction = nil
            model.pressed = nil
        }

        panel.ignoresMouseEvents = (state == .collapsed && !model.isDraggingFile)
        withAnimation(animation) { model.state = state }
    }

    private func expand() { setState(.expanded) }

    private func collapse(waitForPointerToLeave: Bool = false) {
        #if DEBUG
        if pinnedState != nil { return }
        #endif
        if waitForPointerToLeave { waitsForPointerToLeave = true }
        setState(.collapsed)
    }

    private func showPeek(_ content: PeekContent, duration: TimeInterval) {
        guard model.state != .expanded else { return }
        model.peek = content
        setState(.peek)
        peekTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            guard let self, self.model.state == .peek else { return }
            self.collapse()
        }
    }

    private func cancelTimers() {
        expandTimer?.invalidate(); expandTimer = nil
        collapseTimer?.invalidate(); collapseTimer = nil
        peekTimer?.invalidate(); peekTimer = nil
    }

    // MARK: - Pointer

    private func installEventMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.pointerMoved(dragging: event.type != .mouseMoved)
        }) {
            eventMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.pointerMoved(dragging: event.type != .mouseMoved)
            return event
        }) {
            eventMonitors.append(local)
        }
        if let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self, event.window === self.panel, self.model.state == .expanded else { return event }
            self.scroll(with: event)
            return nil
        }) {
            eventMonitors.append(scroll)
        }
    }

    private func pointerMoved(dragging: Bool) {
        #if DEBUG
        if pinnedState != nil { return }
        #endif
        let point = NSEvent.mouseLocation
        let metrics = model.metrics

        switch model.state {
        case .collapsed:
            let inZone = metrics.hotZone.contains(point)
            if waitsForPointerToLeave {
                if !inZone { waitsForPointerToLeave = false }
                return
            }
            if inZone && !dragging {
                scheduleExpand(after: Timing.hoverDelay)
            } else {
                expandTimer?.invalidate(); expandTimer = nil
            }

        case .peek:
            let rect = metrics.screenRect(for: .peek).union(metrics.hotZone)
            if rect.contains(point) && !dragging {
                scheduleExpand(after: Timing.peekHoverDelay)
            } else {
                expandTimer?.invalidate(); expandTimer = nil
            }

        case .expanded:
            if isMenuOpen || model.isDraggingFile { return }
            let rect = metrics.screenRect(for: .expanded).insetBy(dx: -10, dy: -10)
            if rect.contains(point) {
                collapseTimer?.invalidate(); collapseTimer = nil
            } else if collapseTimer == nil {
                collapseTimer = Timer.scheduledTimer(withTimeInterval: Timing.leaveDelay, repeats: false) { [weak self] _ in
                    self?.collapseTimer = nil
                    self?.collapse()
                }
            }
        }
    }

    private func scheduleExpand(after delay: TimeInterval) {
        guard expandTimer == nil else { return }
        expandTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.expandTimer = nil
            self?.expand()
        }
    }

    // MARK: - Scrolling

    /// Trackpad: sideways moves the shelf, up and down switches folders. The
    /// first few points of a gesture decide which, and it sticks for the rest
    /// of that gesture. Mouse: the wheel switches folders, Shift-wheel scrolls.
    private func scroll(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else {
            wheel(event)
            return
        }

        if event.phase == .began || event.phase == .mayBegin {
            scrollAxis = nil
            axisProbe = .zero
            rawPagePull = 0
            gestureSwitchedPage = false
            gestureHitEdge = false
            rawScrollOffset = model.scrollOffset
            ignoresMomentum = false
        }

        if scrollAxis == nil {
            guard event.momentumPhase.isEmpty else { return }
            axisProbe.width += abs(event.scrollingDeltaX)
            axisProbe.height += abs(event.scrollingDeltaY)
            if event.phase == .ended || event.phase == .cancelled { return }
            guard axisProbe.width + axisProbe.height > 5 else { return }
            // Vertical has to clearly win, so a sideways swipe never switches folders.
            scrollAxis = axisProbe.height > axisProbe.width * 1.5 ? .vertical : .horizontal
        }

        switch scrollAxis {
        case .vertical: pullPage(with: event)
        default: scrollShelf(with: event, delta: -event.scrollingDeltaX)
        }
    }

    private func pullPage(with event: NSEvent) {
        // Page switches come from the finger, never from momentum.
        guard event.momentumPhase.isEmpty, !gestureSwitchedPage, model.pages.count > 1 else { return }

        rawPagePull += -event.scrollingDeltaY
        let target = model.pageIndex + (rawPagePull > 0 ? 1 : -1)
        let canSwitch = model.pages.indices.contains(target)

        if canSwitch && abs(rawPagePull) >= Paging.threshold {
            gestureSwitchedPage = true
            Haptics.perform(.levelChange)
            selectPage(target)
            return
        }
        if !canSwitch && abs(rawPagePull) >= Paging.threshold * 0.6 && !gestureHitEdge {
            gestureHitEdge = true
            Haptics.perform(.alignment)
        }

        // Heavy resistance while pulling, heavier still when there's nowhere to go.
        let dimension: CGFloat = canSwitch ? 110 : 40
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.pagePull = Self.band(abs(rawPagePull), dimension: dimension) * (rawPagePull > 0 ? 1 : -1)
        }

        if event.phase == .ended || event.phase == .cancelled {
            releasePagePull()
        }
    }

    private func releasePagePull() {
        rawPagePull = 0
        withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) { model.pagePull = 0 }
    }

    /// Mouse wheels have no gesture phases, so lines are collected over a short
    /// window and a switch needs a few of them in a row.
    private func wheel(_ event: NSEvent) {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        if abs(dx) > abs(dy) {
            let maxOffset = model.maxScrollOffset
            guard maxOffset > 0 else { return }
            rawScrollOffset = min(max(rawScrollOffset - dx * 12, 0), maxOffset)
            withAnimation(.smooth(duration: 0.28)) { model.scrollOffset = rawScrollOffset }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard model.pages.count > 1, now >= wheelLockedUntil else { return }
        if now - lastWheelTime > 0.35 { wheelPull = 0 }
        lastWheelTime = now
        wheelPull += -dy

        let target = model.pageIndex + (wheelPull > 0 ? 1 : -1)
        if abs(wheelPull) >= Paging.wheelThreshold, model.pages.indices.contains(target) {
            wheelPull = 0
            wheelLockedUntil = now + 0.45
            wheelRelease?.cancel()
            Haptics.perform(.levelChange)
            selectPage(target)
            return
        }

        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            model.pagePull = min(abs(wheelPull) * 7, 22) * (wheelPull > 0 ? 1 : -1)
        }
        wheelRelease?.cancel()
        let release = DispatchWorkItem { [weak self] in
            self?.wheelPull = 0
            self?.releasePagePull()
        }
        wheelRelease = release
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: release)
    }

    /// Horizontal scrolling with trackpad momentum and a rubber band at both ends.
    private func scrollShelf(with event: NSEvent, delta: CGFloat) {
        let maxOffset = model.maxScrollOffset
        guard maxOffset > 0 else { return }

        let isMomentum = !event.momentumPhase.isEmpty
        if isMomentum && ignoresMomentum { return }

        let overshoot = rawScrollOffset < 0 ? -rawScrollOffset : max(0, rawScrollOffset - maxOffset)
        if overshoot > 0 && !gestureHitEdge {
            gestureHitEdge = true
            Haptics.perform(.alignment)
        }
        if isMomentum && overshoot > 0 {
            // Momentum running into an edge: let it squash briefly, then bounce back.
            rawScrollOffset += delta * 0.25
            if overshoot > 30 {
                ignoresMomentum = true
                snapScrollBack()
                return
            }
        } else {
            rawScrollOffset += delta
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.scrollOffset = Self.rubberBand(rawScrollOffset, max: maxOffset, dimension: model.metrics.rowWidth)
        }

        let ended = event.phase == .ended || event.phase == .cancelled
            || event.momentumPhase == .ended || event.momentumPhase == .cancelled
        if ended && (rawScrollOffset < 0 || rawScrollOffset > maxOffset) {
            snapScrollBack()
        }
    }

    private func snapScrollBack() {
        rawScrollOffset = min(max(rawScrollOffset, 0), model.maxScrollOffset)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            model.scrollOffset = rawScrollOffset
        }
    }

    /// UIScrollView's rubber band curve: follows the finger at first, then
    /// approaches `dimension` and never passes it.
    private static func band(_ x: CGFloat, dimension: CGFloat) -> CGFloat {
        (1 - 1 / (x * 0.55 / dimension + 1)) * dimension
    }

    private static func rubberBand(_ offset: CGFloat, max maxOffset: CGFloat, dimension: CGFloat) -> CGFloat {
        if offset < 0 { return -band(-offset, dimension: dimension) }
        if offset > maxOffset { return maxOffset + band(offset - maxOffset, dimension: dimension) }
        return offset
    }

    // MARK: - Dragging files out

    private func installDragHandlers() {
        let source = FileDragSource.shared
        source.onBegin = { [weak self] in
            Haptics.perform(.generic)
            self?.model.isDraggingFile = true
            self?.model.hovered = nil
        }
        source.onMove = { [weak self] point in
            guard let self, self.model.state != .collapsed else { return }
            let rect = self.model.metrics.screenRect(for: self.model.state).insetBy(dx: -6, dy: -6)
            // Get out of the way as soon as the file leaves the island.
            if !rect.contains(point) { self.setState(.collapsed) }
        }
        source.onEnd = { [weak self] _ in
            guard let self else { return }
            self.model.isDraggingFile = false
            if self.model.state == .collapsed {
                self.panel.ignoresMouseEvents = true
                self.waitsForPointerToLeave = self.model.metrics.hotZone.contains(NSEvent.mouseLocation)
            } else {
                self.pointerMoved(dragging: false)
            }
        }
    }

    // MARK: - System events

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateScreen() })

        observers.append(center.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.isMenuOpen = true })

        observers.append(center.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.isMenuOpen = false
            self?.pointerMoved(dragging: false)
        })

        // Keep the window above everything after Spaces and full screen changes.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.panel.orderFrontRegardless() })
    }

    private func updateScreen() {
        guard let metrics = IslandMetrics(screen: IslandMetrics.preferredScreen()) else { return }
        if metrics != model.metrics { model.metrics = metrics }
        panel.setFrame(metrics.windowFrame, display: true)
    }

    // MARK: - IslandActions

    func open(_ item: DownloadItem) {
        collapse(waitForPointerToLeave: true)
        FileActions.open(item.url)
    }

    func openFolder() {
        collapse(waitForPointerToLeave: true)
        if let page = model.currentPage { FinderWindow.openNewestFirst(page.url) }
    }

    func openPrivacySettings() {
        collapse(waitForPointerToLeave: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    func showMenu(for item: DownloadItem) {
        if model.state == .peek { expand() }
        let menu = NSMenu()
        menu.addItem(menuItem("Open", symbol: "arrow.up.forward.app", action: #selector(menuOpen(_:)), file: item.url))

        // Finding every app that opens a file is slow, so the submenu fills
        // itself in only when it's about to appear.
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        openWith.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
        let submenu = NSMenu()
        submenu.addItem(NSMenuItem(title: "Loading…", action: nil, keyEquivalent: ""))
        let delegate = OpenWithMenu(file: item.url, target: self, action: #selector(menuOpenWith(_:)))
        openWithMenu = delegate
        submenu.delegate = delegate
        openWith.submenu = submenu
        menu.addItem(openWith)

        if Archive.canExtract(item) {
            let extract = menuItem("Extract & Move Archive to Trash", symbol: "archivebox", action: #selector(menuExtract(_:)))
            extract.representedObject = item.id
            menu.addItem(extract)
        }
        menu.addItem(menuItem("Show in Finder", symbol: "folder", action: #selector(menuReveal(_:)), file: item.url))
        menu.addItem(menuItem("Quick Look", symbol: "eye", action: #selector(menuQuickLook(_:)), file: item.url))
        menu.addItem(.separator())
        menu.addItem(menuItem("Copy", symbol: "doc.on.doc", action: #selector(menuCopy(_:)), file: item.url))
        menu.addItem(.separator())
        menu.addItem(menuItem("Move to Trash", symbol: "trash", action: #selector(menuTrash(_:)), file: item.url))

        present(menu)
    }

    func showSettingsMenu() {
        let menu = NSMenu()

        menu.addItem(.sectionHeader(title: "Folders"))
        for (index, page) in model.pages.enumerated() {
            let item = menuItem(page.name, action: #selector(menuSelectPage(_:)))
            item.representedObject = index
            item.state = index == model.pageIndex ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(menuItem("Add Folder…", symbol: "plus", action: #selector(menuAddFolder)))
        if model.pages.count > 1 {
            menu.addItem(menuItem("Remove “\(model.folderName)”", symbol: "minus", action: #selector(menuRemoveFolder)))
        }
        menu.addItem(.separator())

        let preview = menuItem("Preview New Files", action: #selector(menuTogglePreview))
        preview.state = Preferences.showsNewDownloadPreview ? .on : .off
        menu.addItem(preview)

        let haptics = menuItem("Haptic Feedback", action: #selector(menuToggleHaptics))
        haptics.state = Preferences.hapticsEnabled ? .on : .off
        menu.addItem(haptics)

        let login = menuItem("Open at Login", action: #selector(menuToggleLogin))
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = menuItem("Quit QuickFolder", action: #selector(menuQuit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)

        present(menu)
    }

    /// Menus from an inactive app get mouse-moved events at a trickle, so
    /// highlighting lags behind the pointer. QuickFolder activates just for
    /// the menu and hands focus back afterwards, unless an action opened a
    /// window of ours (Quick Look, the folder picker).
    private func present(_ menu: NSMenu) {
        let wasActive = NSApp.isActive
        NSApp.activate()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        DispatchQueue.main.async {
            if !wasActive && NSApp.isActive && NSApp.keyWindow == nil && NSApp.modalWindow == nil {
                NSApp.deactivate()
            }
        }
    }

    private func menuItem(_ title: String, symbol: String? = nil, action: Selector, file: URL? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = file
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    @objc private func menuOpen(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        collapse(waitForPointerToLeave: true)
        FileActions.open(url)
    }

    @objc private func menuOpenWith(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [URL], pair.count == 2 else { return }
        collapse(waitForPointerToLeave: true)
        FileActions.open(pair[0], with: pair[1])
    }

    @objc private func menuExtract(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = model.items.first(where: { $0.id == id }) else { return }
        extract(item)
    }

    @objc private func menuReveal(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        collapse(waitForPointerToLeave: true)
        FileActions.reveal(url)
    }

    @objc private func menuQuickLook(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        collapse(waitForPointerToLeave: true)
        QuickLook.shared.show(url)
    }

    @objc private func menuCopy(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        FileActions.copy(url)
    }

    @objc private func menuTrash(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        FileActions.moveToTrash(url)
    }

    @objc private func menuSelectPage(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        selectPage(index)
    }

    @objc private func menuAddFolder() {
        collapse(waitForPointerToLeave: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.prompt = "Add Folder"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            var folders = Preferences.folders
            if !folders.contains(where: { $0.path == url.path }) {
                folders.append(url)
                Preferences.folders = folders
                reloadFolders()
            }
            if let index = model.pages.firstIndex(where: { $0.id == url.path }) {
                model.pageIndex = index
                collapsedAt = Date()
            }
        }
        NSApp.deactivate()
    }

    @objc private func menuRemoveFolder() {
        guard model.pages.count > 1, let page = model.currentPage else { return }
        Preferences.folders = Preferences.folders.filter { $0.path != page.id }
        withAnimation(.spring(response: 0.44, dampingFraction: 0.82)) {
            model.pageEdge = .top
            reloadFolders()
        }
    }

    @objc private func menuToggleHaptics() {
        Preferences.hapticsEnabled.toggle()
        Haptics.perform(.levelChange)
    }

    @objc private func menuTogglePreview() {
        Preferences.showsNewDownloadPreview.toggle()
    }

    @objc private func menuToggleLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Debug

    #if DEBUG
    /// `QF_DEBUG_STATE=expanded|peek` pins the island open for screenshots.
    private func applyDebugState() {
        guard let value = ProcessInfo.processInfo.environment["QF_DEBUG_STATE"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            switch value {
            case "peek":
                if let page = model.currentPage, let item = page.items.first {
                    showPeek(.download(item, pageID: page.id, label: "Downloaded"), duration: 3600)
                }
                pinnedState = .peek
            default:
                expand()
                pinnedState = .expanded
                if let page = ProcessInfo.processInfo.environment["QF_DEBUG_PAGE"].flatMap(Int.init) {
                    selectPage(page)
                }
                if ProcessInfo.processInfo.environment["QF_DEBUG_EXTRACT"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.model.items.filter(Archive.canExtract).forEach(self.extract)
                    }
                }
                if ProcessInfo.processInfo.environment["QF_DEBUG_MENU"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.showSettingsMenu() }
                }
            }
        }
    }
    #endif
}

/// Fills in an "Open With" submenu the first time it opens.
private final class OpenWithMenu: NSObject, NSMenuDelegate {
    private let file: URL
    private weak var target: AnyObject?
    private let action: Selector
    private var isFilled = false

    init(file: URL, target: AnyObject, action: Selector) {
        self.file = file
        self.target = target
        self.action = action
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !isFilled else { return }
        isFilled = true
        menu.removeAllItems()

        let apps = FileActions.applications(toOpen: file)
        if apps.isEmpty {
            menu.addItem(NSMenuItem(title: "No Apps", action: nil, keyEquivalent: ""))
        }
        for (index, app) in apps.prefix(12).enumerated() {
            let name = FileManager.default.displayName(atPath: app.path)
            let entry = NSMenuItem(title: index == 0 ? "\(name) (default)" : name, action: action, keyEquivalent: "")
            entry.target = target
            entry.representedObject = [file, app]
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            entry.image = icon
            menu.addItem(entry)
            if index == 0 && apps.count > 1 { menu.addItem(.separator()) }
        }
    }
}
